import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LuxtableCore
@testable import LuxtableMac
@testable import LuxtableUI

/// A scripted Photos library or device: fixed listings and bytes, optional failures.
private final class FakeSource: ExternalPhotoSource, @unchecked Sendable {
    let name: String
    let isPhotosLibrary: Bool
    var prepareError: Error?
    var listError: Error?
    var albumList: [ExternalAlbum] = []
    var listings: [ExternalScope: ExternalListing] = [:]
    var bytes: [String: Data] = [:]
    /// Items whose read fails after the first chunk.
    var failing: Set<String> = []
    /// Items whose reads wait until the task is cancelled.
    var hanging: Set<String> = []
    var chunk = 3
    private let lock = NSLock()
    private var _scopes: [ExternalScope] = []
    private var _thumbs = 0
    var scopes: [ExternalScope] { lock.withLock { _scopes } }
    var thumbs: Int { lock.withLock { _thumbs } }

    init(name: String = "Photos Library", photos: Bool = true) {
        self.name = name
        isPhotosLibrary = photos
    }

    func prepare() async throws { if let prepareError { throw prepareError } }
    func albums() async -> [ExternalAlbum] { albumList }

    func list(_ scope: ExternalScope) async throws -> ExternalListing {
        lock.withLock { _scopes.append(scope) }
        if let listError { throw listError }
        return listings[scope] ?? ExternalListing(items: [])
    }

    func thumbnail(for item: ExternalItem, maxPixelSize: Int) async -> CGImage? {
        lock.withLock { _thumbs += 1 }
        return tinyImage()
    }

    func read(_ item: ExternalItem, into sink: @escaping @Sendable (Data) throws -> Void) async throws {
        if hanging.contains(item.id) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        guard let data = bytes[item.id] else { throw ExternalSourceError.readFailed("gone") }
        var i = 0
        while i < data.count {
            try sink(data.subdata(in: i..<min(i + chunk, data.count)))
            i += chunk
            if failing.contains(item.id) { throw ExternalSourceError.readFailed("The cable came loose.") }
        }
    }
}

private func tinyImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return ctx.makeImage()!
}

/// A real (tiny) JPEG, so lt-import has a genuine photo to copy.
private func jpegData() -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, tinyImage(), nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func tmp(_ tag: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func item(_ id: String, _ name: String, at: Date = t0, size: Int64? = nil) -> ExternalItem {
    ExternalItem(id: id, filename: name, date: at, size: size)
}

@Suite struct ExternalSourceLogicTests {
    @Test func classifiesByExtensionAndRawType() {
        #expect(ExternalItemKind.classify(filename: "IMG_0001.HEIC") == .heif)
        #expect(ExternalItemKind.classify(filename: "IMG_0002.jpeg") == .jpeg)
        #expect(ExternalItemKind.classify(filename: "IMG_0003.DNG") == .raw, "ProRAW")
        #expect(ExternalItemKind.classify(filename: "DSC1.ARW") == .raw)
        #expect(ExternalItemKind.classify(filename: "IMG_0004.MOV") == .video)
        #expect(ExternalItemKind.classify(filename: "Screen.png") == .other)
        #expect(ExternalItemKind.classify(filename: "odd", uti: "com.adobe.raw-image") == .raw)
        #expect(ExternalItemKind.classify(filename: "odd", uti: "com.sony.arw-raw-image") == .raw)
        #expect(ExternalItemKind.classify(filename: "odd", uti: "public.png") == .other)
        #expect(ExternalItemKind.heif.isImportable && !ExternalItemKind.video.isImportable && !ExternalItemKind.other.isImportable)
        #expect(ExternalItem(id: "a", filename: "x.mov", date: t0, kind: .other).kind == .other, "an explicit kind wins")
    }

    @Test func listingKeepsPhotosAndCountsTheRest() {
        let l = ExternalListing.sorting([
            item("b", "B.HEIC", at: t0 + 10), item("a", "A.JPG", at: t0), item("v", "V.MOV"),
            item("p", "Shot.PNG"), item("e", "IMG_0001.AAE"), item("c", "C.DNG", at: t0),
        ])
        #expect(l.items.map(\.id) == ["a", "c", "b"], "by date, then name")
        #expect(l.videos == 1 && l.unsupported == ["Shot.PNG"], "edit notes (AAE) aren't listed as unsupported")
    }

    @Test func dateScopesIncludeBothDays() {
        let cal = Calendar(identifier: .gregorian)
        let from = cal.date(from: DateComponents(year: 2024, month: 5, day: 1, hour: 15))!
        let to = cal.date(from: DateComponents(year: 2024, month: 5, day: 3, hour: 9))!
        let s = ExternalScope.dates(from: to, to: from) // reversed ends are fine
        let i = try! #require(s.interval(calendar: cal))
        #expect(i.start == cal.date(from: DateComponents(year: 2024, month: 5, day: 1)))
        #expect(i.end == cal.date(from: DateComponents(year: 2024, month: 5, day: 4)))
        #expect(s.contains(cal.date(from: DateComponents(year: 2024, month: 5, day: 3, hour: 23))!, calendar: cal))
        #expect(!s.contains(cal.date(from: DateComponents(year: 2024, month: 5, day: 4))!, calendar: cal))
        #expect(!s.contains(cal.date(from: DateComponents(year: 2024, month: 4, day: 30, hour: 23))!, calendar: cal))
        #expect(ExternalScope.all.interval() == nil && ExternalScope.album("x").contains(t0))
    }

    @Test func photosTakesTheRawOfAPairThenTheUneditedOriginal() {
        typealias R = PhotoResourceChoice.Resource
        let jpeg = R(role: .original, filename: "IMG_1.JPG")
        let raw = R(role: .alternate, filename: "IMG_1.CR3")
        let edited = R(role: .other, filename: "FullSizeRender.jpeg")
        #expect(PhotoResourceChoice.pick([jpeg, raw, edited]) == raw)
        #expect(PhotoResourceChoice.pick([edited, jpeg]) == jpeg, "never the edited render")
        let proraw = R(role: .original, filename: "IMG_2.DNG", uti: "com.adobe.raw-image")
        #expect(PhotoResourceChoice.pick([proraw, edited])?.kind == .raw)
        let altJPEG = R(role: .alternate, filename: "IMG_3.JPG")
        let heic = R(role: .original, filename: "IMG_3.HEIC")
        #expect(PhotoResourceChoice.pick([altJPEG, heic]) == heic, "only a RAW alternate wins")
        #expect(PhotoResourceChoice.pick([edited]) == nil)
    }

    @Test func devicePairsOfferTheRawOnce() {
        let files = [
            DeviceFile(key: "j1", name: "IMG_1.JPG", pairedRawKey: "r1"),
            DeviceFile(key: "r1", name: "IMG_1.DNG"),
            DeviceFile(key: "h2", name: "IMG_2.HEIC"),
        ]
        #expect(DeviceFilePairing.originals(files) == ["r1", "h2"])
    }

    @Test func chunkedReadsStopAtTheEnd() async throws {
        let data = Data((0..<10).map { UInt8($0) })
        var got = Data()
        var asks: [(Int64, Int64)] = []
        try await ChunkedRead.read(size: 10, chunk: 4, fetch: { o, l in
            asks.append((o, l))
            return data.subdata(in: Int(o)..<Int(o + l))
        }, into: { got.append($0) })
        #expect(got == data && asks.map(\.0) == [0, 4, 8] && asks.map(\.1) == [4, 4, 2])
        await #expect(throws: ExternalSourceError.self) {
            try await ChunkedRead.read(size: 10, chunk: 4, fetch: { _, _ in Data() }, into: { _ in })
        }
        #expect(ExternalSourceError.readFailed("x").localizedDescription == "x")
    }
}

@MainActor @Suite struct ExternalStagerTests {
    @Test func stagesVerifiedFilesWithUniqueNamesAndCaptureDates() async throws {
        let dir = try tmp("stage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        let a = item("a", "IMG_0001.HEIC", at: t0, size: 7)
        let b = item("b", "img_0001.heic", at: t0 + day)
        let c = item("c", ".hidden", at: t0)
        src.bytes = ["a": Data("aaaaaaa".utf8), "b": Data("bbbb".utf8), "c": Data("c".utf8)]
        let folder = dir.appendingPathComponent("Photos Library")
        var seen: [Int] = []
        let r = try await ExternalStager().stage([a, b, c], from: src, into: folder) { d, _ in seen.append(d) }
        #expect(r.failed.isEmpty && r.bytes == 12 && seen == [1, 2, 3])
        #expect(r.staged["a"]?.lastPathComponent == "IMG_0001.HEIC")
        #expect(r.staged["b"]?.lastPathComponent == "img_0001-2.heic", "same name, case-insensitively")
        #expect(r.staged["c"]?.lastPathComponent == "hidden", "never a dot file lt-import would skip")
        #expect(try Data(contentsOf: r.staged["a"]!) == Data("aaaaaaa".utf8))
        let mtime = try FileManager.default.attributesOfItem(atPath: r.staged["b"]!.path)[.modificationDate] as? Date
        #expect(mtime == t0 + day)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["IMG_0001.HEIC", "hidden", "img_0001-2.heic"], "no partial files left")
    }

    @Test func aFailedOrShortReadLeavesNothingBehind() async throws {
        let dir = try tmp("fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        src.bytes = ["ok": Data("good".utf8), "cut": Data("partial bytes".utf8), "short": Data("abc".utf8),
                     "empty": Data()]
        src.failing = ["cut"]
        let items = [item("ok", "A.JPG"), item("cut", "B.JPG"), item("short", "C.JPG", size: 99), item("gone", "D.JPG"),
                     item("empty", "E.JPG")]
        let r = try await ExternalStager().stage(items, from: src, into: dir)
        #expect(r.staged.keys.sorted() == ["ok"])
        #expect(r.failed.map(\.filename) == ["B.JPG", "C.JPG", "D.JPG", "E.JPG"])
        #expect(r.failed[0].reason.contains("cable") && r.failed[1].reason.contains("3 of 99"))
        #expect(r.failed[3].reason.contains("empty"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["A.JPG"])
    }

    @Test func cancellingStopsAndRemovesThePartialFile() async throws {
        let dir = try tmp("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FakeSource()
        src.hanging = ["h"]
        let t = Task { try await ExternalStager().stage([item("h", "H.JPG")], from: src, into: dir) }
        try await Task.sleep(for: .milliseconds(30))
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func stagingFoldersAreNamedAndCleanedUp() throws {
        let root = try tmp("root")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ExternalStaging.makeFolder(for: "Kai's iPhone: 15/Pro", root: root)
        let b = ExternalStaging.makeFolder(for: "..", root: root)
        #expect(a.lastPathComponent == "Kai's iPhone- 15-Pro" && b.lastPathComponent == "Import")
        #expect(ExternalStaging.isStaged(a, root: root) && !ExternalStaging.isStaged(root, root: root))
        #expect(!ExternalStaging.isStaged(nil, root: root) && !ExternalStaging.isStaged(URL(fileURLWithPath: "/Volumes/CARD"), root: root))
        for f in [a, b] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        ExternalStaging.cleanUp(keeping: [a, URL(fileURLWithPath: "/Volumes/CARD")], root: root)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))
        ExternalStaging.cleanUp(keeping: [], root: root.appendingPathComponent("missing")) // no root: nothing to do
        #expect(ExternalStaging.root.lastPathComponent == "Import Staging")
    }
}

@MainActor @Suite struct ExternalImportModelTests {
    private func model(_ src: FakeSource, root: URL) -> (ExternalImportModel, () -> [URL]) {
        var staged: [URL] = []
        let m = ExternalImportModel(source: src, stagingRoot: root) { staged.append($0) }
        return (m, { staged })
    }

    private func source() -> FakeSource {
        let src = FakeSource()
        src.albumList = [ExternalAlbum(id: "al", title: "Trip", count: 1)]
        src.listings[.all] = ExternalListing(items: [item("a", "A.HEIC"), item("b", "B.DNG", at: t0 + 1)], videos: 2,
                                             unsupported: ["S.PNG"])
        src.listings[.album("al")] = ExternalListing(items: [item("b", "B.DNG")])
        src.bytes = ["a": Data("heic".utf8), "b": Data("dng!".utf8)]
        return src
    }

    @Test func listsChoosesAndHandsTheStagedFolderToTheCardImport() async throws {
        let root = try tmp("model")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = source()
        let (m, staged) = model(src, root: root)
        #expect(m.title == "Import from Photos Library" && m.origin == "your Photos library")
        await m.load()
        #expect(m.phase == .ready && m.albums.count == 1 && m.items.count == 2)
        #expect(m.summaryLine == "2 photos · 2 videos not imported · 1 file in other formats not imported")
        m.toggle(m.items[0])
        #expect(m.selected.map(\.id) == ["b"] && !m.isSelected(m.items[0]))
        m.toggle(m.items[0])
        m.selectNone()
        #expect(!m.canStart)
        m.selectAll()
        #expect(m.canStart)
        m.start()
        #expect(m.phase == .staging && m.isBusy && m.total == 2)
        m.toggle(m.items[0])
        #expect(m.selected.count == 2, "no changes while copying")
        await m.wait()
        let folder = try #require(staged().first)
        #expect(m.phase == .ready && m.done == 2 && m.doneBytes == 8)
        #expect(folder.lastPathComponent == "Photos Library" && ExternalStaging.isStaged(folder, root: root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["A.HEIC", "B.DNG"])
    }

    @Test func scopesReloadTheList() async throws {
        let root = try tmp("scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = source()
        let (m, _) = model(src, root: root)
        await m.load()
        m.selectNone()
        await m.setScope(.album("al"))
        #expect(m.items.map(\.id) == ["b"] && m.selected.count == 1, "a new list starts all ticked")
        await m.setScope(.album("al"))
        #expect(src.scopes == [.all, .album("al")], "the same scope isn't listed twice")
        await m.setScope(.dates(from: t0, to: t0))
        #expect(m.phase == .ready && m.items.isEmpty)
        src.listError = ExternalSourceError.unavailable("That album is no longer in your Photos library.")
        await m.setScope(.all)
        #expect(m.phase == .failed("That album is no longer in your Photos library.") && m.items.isEmpty)
    }

    @Test func refusedAccessSaysWhy() async throws {
        let root = try tmp("denied")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = FakeSource(name: "Kai’s iPhone", photos: false)
        src.prepareError = ExternalSourceError.unavailable(ImageCaptureDevice.lockedMessage)
        let (m, _) = model(src, root: root)
        #expect(m.title == "Import from Kai’s iPhone" && m.origin == "the Kai’s iPhone")
        await m.load()
        #expect(m.phase == .unavailable(ImageCaptureDevice.lockedMessage) && !m.canStart)
        m.start()
        #expect(m.phase != .staging)
        #expect(PhotoKitLibrary.deniedMessage.contains("Privacy & Security"))
    }

    @Test func someFailuresAskBeforeGoingOn() async throws {
        let root = try tmp("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = source()
        src.failing = ["a"]
        let (m, staged) = model(src, root: root)
        await m.load()
        m.continueWithStaged() // nothing staged yet: no-op
        m.start()
        await m.wait()
        guard case .stagedWithProblems(let r) = m.phase else { Issue.record("\(m.phase)"); return }
        #expect(r.failed.map(\.filename) == ["A.HEIC"] && r.staged.count == 1 && staged().isEmpty)
        m.continueWithStaged()
        #expect(staged().count == 1 && m.phase == .ready)
    }

    @Test func nothingCopiedFailsAndCleansUp() async throws {
        let root = try tmp("none")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = source()
        src.bytes = [:]
        let (m, staged) = model(src, root: root)
        await m.load()
        m.start()
        await m.wait()
        guard case .failed(let why) = m.phase else { Issue.record("\(m.phase)"); return }
        #expect(why.contains("None of the photos could be copied from your Photos library") && staged().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func stoppingDropsTheStagedCopies() async throws {
        let root = try tmp("stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = source()
        src.hanging = ["b"]
        let (m, staged) = model(src, root: root)
        await m.load()
        m.start()
        try await Task.sleep(for: .milliseconds(30))
        m.cancel()
        await m.wait()
        #expect(m.phase == .ready && staged().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func thumbnailsAreCached() async throws {
        let (m, _) = model(source(), root: try tmp("thumbs"))
        let src = m.source as! FakeSource
        await m.load()
        let i = m.items[0]
        #expect(m.cachedThumbnail(i) == nil)
        #expect(await m.thumbnail(i) != nil)
        #expect(await m.thumbnail(i) != nil && src.thumbs == 1 && m.cachedThumbnail(i) != nil)
        #expect(m == m)
    }

    /// The staged folder is a plain folder lt-import scans and copies like a card.
    @Test func stagedPhotosImportThroughLtImport() async throws {
        let root = try tmp("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = FakeSource()
        let jpeg = jpegData()
        src.bytes = ["x": jpeg, "y": jpeg + Data([0])]
        src.listings[.all] = ExternalListing(items: [item("x", "IMG_0001.JPG"), item("y", "IMG_0001.jpg", at: t0 + 60)])
        let (m, staged) = model(src, root: root.appendingPathComponent("staging"))
        await m.load()
        m.start()
        await m.wait()
        let folder = try #require(staged().first)
        let service = RustImportService(libraryRoot: root.appendingPathComponent("Library"), globalIndex: nil)
        let scan = try await service.scanCard(volume: folder)
        #expect(scan.candidates.map(\.filename).sorted() == ["IMG_0001-2.jpg", "IMG_0001.JPG"], "\(scan.candidates)")
        #expect(scan.skippedUnknown.isEmpty && scan.scanErrors.isEmpty)
        #expect(scan.candidates.map(\.captureDate).sorted() == [t0, t0 + 60])
    }
}

@MainActor @Suite struct ConnectedDevicesTests {
    final class FakeBrowser: DeviceBrowsing {
        var add: (@MainActor (String, any ExternalPhotoSource) -> Void)?
        var remove: (@MainActor (String) -> Void)?
        var stops = 0
        func start(onAdd: @escaping @MainActor (String, any ExternalPhotoSource) -> Void,
                   onRemove: @escaping @MainActor (String) -> Void) {
            add = onAdd
            remove = onRemove
        }
        func stop() { stops += 1 }
    }

    @Test func tracksDevicesComingAndGoing() {
        let b = FakeBrowser()
        let d = ConnectedDevices(browser: b)
        d.start()
        d.start()
        #expect(d.isRunning)
        let phone = FakeSource(name: "iPhone", photos: false)
        b.add?("1", phone)
        b.add?("1", phone)
        b.add?("2", FakeSource(name: "iPad", photos: false))
        #expect(d.devices.map(\.name) == ["iPhone", "iPad"] && d.devices[0].id == "1")
        b.remove?("1")
        #expect(d.devices.map(\.name) == ["iPad"])
        d.stop()
        d.stop()
        #expect(d.devices.isEmpty && b.stops == 1 && !d.isRunning)
    }
}

@MainActor @Suite struct ExternalImportAppTests {
    private func app(mode: AppMode, verifying: Bool) -> AppModel {
        let importer: any ImportService = verifying
            ? ReportingImportService(scan: ImportScan(candidates: []), make: { _ in ImportReport(filesTotal: 0, filesCopied: 0, filesVerified: 0, bytesCopied: 0) })
            : MockImportService()
        return AppModel(sessions: MockSessionStore(counts: [1]), images: MockImageProvider(latency: .zero),
                        renderer: FakeRenderer(), importer: importer,
                        archive: MockArchiveService(target: "/nonexistent/x", isReachable: { _ in false }),
                        ai: MockAIService(), settings: makeSettings(), mode: mode)
    }

    @Test func onlyLiveVerifiedImportsOfferPhotosAndDevices() async throws {
        let demo = app(mode: .demo, verifying: false)
        #expect(!demo.canImportExternal)
        demo.sheet = nil // first-launch onboarding
        demo.showExternalImport(FakeSource())
        #expect(demo.sheet == nil)

        let live = app(mode: .live, verifying: true)
        #expect(live.canImportExternal)
        live.showPhotosLibraryImport(source: FakeSource())
        guard case .externalImport(let m) = live.sheet else { Issue.record("\(String(describing: live.sheet))"); return }
        #expect(live.sheet?.id == "external-import" && m.source.isPhotosLibrary)
    }

    @Test func closingASheetRemovesUnusedStagingFolders() throws {
        let root = try tmp("appclean")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ExternalStaging.makeFolder(for: "Photos Library", root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app(mode: .live, verifying: true).cleanUpStaging(root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(ImportWording.stagedLine.contains("nothing there was changed"))
    }
}
