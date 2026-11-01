import Foundation
import Testing
@testable import LuxtableCore

/// A folder opened in place, in memory: nothing moves to a session Trash, but photos can
/// go to the (fake) macOS Trash, unless the folder is on a card or in the archive.
actor InPlaceTrashStore: SessionStore, SessionFileOrganizing, OriginalsTrashing, StackCoverStoring {
    var photosByID: [PhotoID: Photo]
    var order: [PhotoID]
    let session: SessionInfo
    /// What went to the macOS Trash, and the archive folder each call was told about.
    var trashed: [PhotoID] = []
    var archiveTargets: [String?] = []
    var refusal: OriginalsTrashRefusal?
    /// The Trash refuses (a volume without one): nothing is deleted.
    var refuses = false
    var covers: [StackCover] = []

    init(count: Int, spacing: Double = 10) {
        let photos = (1...count).map { i -> Photo in
            var p = samplePhoto(Int64(i))
            p.meta.captureDate = Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * spacing)
            return p
        }
        photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        order = photos.map(\.id)
        session = SessionInfo(name: "Folder", url: URL(fileURLWithPath: "/tmp/Folder"), photoCount: count, createdAt: Date())
    }

    func listSessions() async throws -> [SessionInfo] { [session] }
    func photos(in session: SessionInfo) async throws -> [Photo] { order.compactMap { photosByID[$0] } }
    func albums(in session: SessionInfo) async throws -> [Album] { [] }
    func createSession(named name: String) async throws -> SessionInfo { session }
    func save(photos updated: [Photo]) async throws { for p in updated { photosByID[p.id] = p } }
    func edit(for id: PhotoID) async throws -> EditState { EditState() }
    func save(edits: [PhotoID: EditState]) async throws {}

    // A folder opened in place never moves files.
    func canMoveOriginals(in session: SessionInfo) async -> Bool { false }
    func move(_ ids: [PhotoID], to folder: SessionFolderKind) async throws -> [FolderMove] { throw MockError.invalid("in place") }
    func trashRejected(in session: SessionInfo) async throws -> RejectsTrashed { throw MockError.invalid("in place") }
    func moveBack(_ moves: [FolderMove], hidden: [PhotoID], in session: SessionInfo) async throws {}
    func restoreSetAsideVariants(in session: SessionInfo) async throws -> Int { 0 }
    func emptyTrash(in session: SessionInfo) async throws -> Int { throw MockError.invalid("in place") }
    func newVariant(of id: PhotoID) async throws -> PhotoID { throw MockError.invalid("in place") }

    func originalsTrashRefusal(in session: SessionInfo, archiveTarget: String?) async -> OriginalsTrashRefusal? { refusal }
    func trashOriginals(_ ids: [PhotoID], archiveTarget: String?) async throws -> Int {
        archiveTargets.append(archiveTarget)
        if refuses { throw MockError.invalid("The macOS Trash refused the files, so nothing was deleted") }
        for id in ids { photosByID[id] = nil }
        order.removeAll { photosByID[$0] == nil }
        trashed += ids
        return ids.count
    }

    func storedStackCovers(in session: SessionInfo) async throws -> [StackCover] { covers }
    func storeStackCovers(_ covers: [StackCover], in session: SessionInfo) async throws { self.covers = covers }

    func set(refusal: OriginalsTrashRefusal?) { self.refusal = refusal }
    func set(refuses: Bool) { self.refuses = refuses }
}

@MainActor @Suite struct TrashInPlaceTests {
    func model(_ store: InPlaceTrashStore) async -> AppModel {
        let m = makeModel(store: store)
        await m.start()
        return m
    }

    /// The user's question: a Best Shot made in a folder opened in place can be deleted
    /// from the burst strip. It asks first (macOS Trash, not ⌘Z), then the file goes, the
    /// strip stays on a neighbour and the Best Shot mark is dropped.
    @Test func aBestShotInAFolderOpenedInPlaceGoesToTheMacOSTrash() async throws {
        let store = InPlaceTrashStore(count: 4, spacing: 0.1)
        let m = await model(store)
        #expect(!m.cull.canMove && m.cull.canTrashOriginals && m.cull.trashRoute == .macOSTrash)
        m.setStackBursts(true)
        let stack = try #require(m.browserState.stacks.stacks.first { $0.count == 4 })
        let frames = stack.memberIDs
        // The last frame stands in for a Best Shot: it is the burst's cover.
        m.browserState.addBestShot(frames[3], sources: Array(frames[0..<3]))
        m.browserState.refresh(photos: m.visiblePhotos)
        #expect(m.coverDecision(of: frames[3])?.source == .bestShot)
        m.openBurstStrip(for: frames[0])
        m.showInBurstStrip(frames[3])
        await m.trashBurstFrame(frames[3])
        let plan = try #require(m.cull.pendingTrashOriginals, "it asks first")
        #expect(plan.ids == [frames[3]] && plan.files == 1)
        #expect(plan.message.contains("macOS Trash") && plan.message.contains("Finder") && plan.message.contains("⌘Z"))
        #expect(plan.message.contains(m.photo(frames[3])!.filename) && plan.confirmTitle == "Move 1 File to Trash")
        #expect(await store.trashed.isEmpty, "nothing goes before the confirmation")
        await m.cull.confirmTrashOriginals()
        #expect(await store.trashed == [frames[3]] && m.cull.pendingTrashOriginals == nil)
        #expect(!m.visibleIDs.contains(frames[3]) && m.photos.count == 3)
        #expect(m.toast?.message == "Moved 1 file to the Trash")
        let shown = try #require(m.focusedID)
        #expect(frames.contains(shown) && shown != frames[3], "a frame of the burst, not the first photo")
        #expect(!m.browserState.covers.contains { $0.cover == frames[3] }, "the Best Shot mark is dropped")
        await m.browserState.coverSave?.value
        #expect(await store.covers.allSatisfy { $0.cover != frames[3] }, "saved with the session")
        m.browserState.refresh(photos: m.visiblePhotos)
        #expect(m.burstStripShown && m.browserState.picker.frames.count == 3, "the strip stays open on the rest")
        #expect(m.browserState.picker.current == shown)
        #expect(m.coverDecision(of: frames[0])?.source != .bestShot)
    }

    /// Photo ▸ Move to Trash… works for any photo of the folder, with a neighbour shown
    /// after; Cancel sends nothing; the archive folder is passed on (never deleted from).
    @Test func photoMenuMoveToTrashAsksThenSendsTheFocusedPhoto() async throws {
        let store = InPlaceTrashStore(count: 5)
        let m = await model(store)
        m.settings.archiveTarget = "/Volumes/Archive/Luxtable"
        let ids = m.visibleIDs
        m.focus(ids[2], extend: false)
        #expect(CommandCatalog.isEnabled(.moveToTrash, model: m))
        #expect(CommandCatalog.title(.moveToTrash, model: m) == "Move to Trash…")
        #expect(CommandCatalog.help(.moveToTrash, model: m)?.contains("macOS Trash") == true)
        #expect(CommandCatalog.cullMenu.contains(.moveToTrash) && CommandCatalog.cullContextMenu.contains(.moveToTrash))
        #expect(MenuCommand.moveToTrash.shortcut == nil)
        await m.moveTargetsToTrash()
        #expect(m.cull.pendingTrashOriginals?.ids == [ids[2]] && m.cull.pendingTrashOriginals?.focusing == ids[3])
        m.cull.pendingTrashOriginals = nil // Cancel
        await m.cull.confirmTrashOriginals()
        #expect(await store.trashed.isEmpty && m.visibleIDs.contains(ids[2]))
        // Several selected: one confirmation for all, then the next photo after them.
        m.focus(ids[2], extend: false)
        m.focus(ids[3], extend: true)
        CommandCatalog.perform(.moveToTrash, model: m)
        #expect(await waitUntil { m.cull.pendingTrashOriginals != nil })
        let plan = try #require(m.cull.pendingTrashOriginals)
        #expect(plan.ids == [ids[2], ids[3]] && plan.files == 2 && plan.confirmTitle == "Move 2 Files to Trash")
        #expect(plan.message.contains("2 files go to the macOS Trash"))
        await m.cull.confirmTrashOriginals()
        #expect(await store.trashed == [ids[2], ids[3]])
        #expect(m.visibleIDs == [ids[0], ids[1], ids[4]] && m.focusedID == ids[4])
        #expect(await store.archiveTargets == ["/Volumes/Archive/Luxtable"])
        #expect(m.toast?.message == "Moved 2 files to the Trash")
        // The last photo: its neighbour is the one before.
        m.focus(ids[4], extend: false)
        await m.moveTargetsToTrash()
        #expect(m.cull.pendingTrashOriginals?.focusing == ids[1])
    }

    /// A Trash that refuses (a volume without one) leaves the photo in the session.
    @Test func aRefusingTrashLeavesThePhoto() async {
        let store = InPlaceTrashStore(count: 3)
        await store.set(refuses: true)
        let m = await model(store)
        let ids = m.visibleIDs
        m.focus(ids[0], extend: false)
        await m.moveTargetsToTrash()
        await m.cull.confirmTrashOriginals()
        #expect(m.visibleIDs == ids && m.toast?.isError == true)
        #expect(m.toast?.message.contains("nothing was deleted") == true)
    }

    /// Never from a memory card or the archive: the commands are off with the reason,
    /// and the burst strip's menu says why instead of being empty.
    @Test func neverFromACardOrTheArchive() async throws {
        for refusal in [OriginalsTrashRefusal.memoryCard, .archive, .photoLibrary] {
            let store = InPlaceTrashStore(count: 3, spacing: 0.1)
            await store.set(refusal: refusal)
            let m = await model(store)
            #expect(!m.cull.canTrashOriginals && m.cull.trashRoute == .unavailable(refusal.reason))
            m.focus(m.visibleIDs[0], extend: false)
            #expect(!CommandCatalog.isEnabled(.moveToTrash, model: m))
            #expect(CommandCatalog.help(.moveToTrash, model: m) == refusal.reason)
            await m.trashBurstFrame(m.visibleIDs[0])
            #expect(m.cull.pendingTrashOriginals == nil && m.toast?.message == refusal.reason)
            m.cull.requestTrashOriginals([m.visibleIDs[0]])
            #expect(m.cull.pendingTrashOriginals == nil)
            #expect(await store.trashed.isEmpty)
        }
        #expect(OriginalsTrashRefusal.memoryCard.reason.contains("memory card"))
        #expect(OriginalsTrashRefusal.archive.reason.contains("archive"))
        #expect(OriginalsTrashRefusal.photoLibrary.reason.contains("photo library"))
    }

    /// The demo (sample photos) supports it too: the photo leaves the mock session.
    @Test func theDemoWindowDeletesToo() async throws {
        let m = makeModel(counts: [3])
        await m.start()
        #expect(!m.cull.canMove && m.cull.trashRoute == .macOSTrash)
        let ids = m.visibleIDs
        m.focus(ids[0], extend: false)
        await m.moveTargetsToTrash()
        #expect(m.cull.pendingTrashOriginals?.ids == [ids[0]])
        await m.cull.confirmTrashOriginals()
        #expect(m.visibleIDs == [ids[1], ids[2]] && m.focusedID == ids[1])
        #expect(m.toast?.message == "Moved 1 file to the Trash")
        m.cull.sessionClosed()
        #expect(!m.cull.canTrashOriginals && m.cull.trashRoute == .unavailable(CullFinisher.inPlaceReason))
    }

    /// Imported sessions keep the undoable session Trash, for every frame and Move to
    /// Session Trash in the Photo menu; nothing asks.
    @Test func importedSessionsStillUseTheSessionTrash() async {
        let store = Cul9Store(count: 3)
        let m = makeModel(store: store)
        await m.start()
        #expect(m.cull.trashRoute == .sessionTrash && !m.cull.canTrashOriginals)
        let ids = m.visibleIDs
        m.focus(ids[1], extend: false)
        #expect(CommandCatalog.title(.moveToTrash, model: m) == "Move to Session Trash")
        #expect(CommandCatalog.help(.moveToTrash, model: m)?.contains("⌘Z") == true)
        #expect(CommandCatalog.isEnabled(.moveToTrash, model: m))
        await m.moveTargetsToTrash()
        #expect(m.cull.pendingTrashOriginals == nil && m.cull.trashedIDs == [ids[1]])
        #expect(m.focusedID == ids[2] && m.toast?.message == "Moved 1 photo to the session Trash (⌘Z to undo)")
        // A session that can't move files and can't trash them (an older store): why.
        await store.setCanMove(false)
        await m.cull.refresh()
        #expect(m.cull.trashRoute == .unavailable(CullFinisher.inPlaceReason))
        #expect(CommandCatalog.help(.moveToTrash, model: m) == CullFinisher.inPlaceReason)
        await m.moveTargetsToTrash()
        #expect(m.toast?.message == CullFinisher.inPlaceReason)
    }

    /// Live: Rust refuses a folder inside the archive, and nothing is touched (the real
    /// macOS Trash is never used by the tests).
    @Test func liveInPlaceFolderInTheArchiveIsRefused() async throws {
        guard let dir = try sampleFolderCopy(limit: 1) else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RustSessionStore(recents: RecentFolders(defaults: testDefaults()),
                                     storeBase: dir.appendingPathComponent("stores"))
        let info = try await store.add(folder: dir)
        #expect(await store.originalsTrashRefusal(in: info, archiveTarget: nil) == nil)
        #expect(await store.originalsTrashRefusal(in: info, archiveTarget: dir.path) == .archive)
        let photo = try #require(try await store.photos(in: info).first)
        await #expect(throws: (any Error).self) { _ = try await store.trashOriginals([photo.id], archiveTarget: dir.path) }
        #expect(FileManager.default.fileExists(atPath: try #require(photo.url).path))
        #expect(try await store.photos(in: info).count == 1)
    }

    @Test func coverMarksOfPhotosThatLeftAreDropped() {
        let (a, b, c) = (PhotoID(1), PhotoID(2), PhotoID(3))
        let covers = [StackCover(members: [a, b], cover: a), StackCover(members: [a, b, c], cover: c, bestShot: true)]
        #expect(StackCovers.removing([c], from: covers) == [covers[0]])
        #expect(StackCovers.removing([], from: covers) == covers)
        let state = BrowserState()
        state.load(covers: covers)
        #expect(state.dropCovers(of: [b]) == nil, "not a cover: nothing to save")
        #expect(state.dropCovers(of: [c]) == [covers[0]] && state.covers == [covers[0]])
    }
}
