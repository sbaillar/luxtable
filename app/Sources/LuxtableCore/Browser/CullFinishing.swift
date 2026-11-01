import Foundation
import Observation

/// Finishing a cull (final-journeys H7), for sessions created by import:
///
/// - **Move Rejected to Trash**: a file whose every variant is rejected goes to the
///   session's `Trash/` folder: hidden from the browser, recoverable (⌘Z, or
///   "Restore from Session Trash"), never emptied on their own. A file with a kept
///   variant stays: only its rejected variants are hidden (⌘Z brings them back).
/// - **Move Picked and Rated to Selects**: after a confirmation naming the count
///   and the rule, photos picked or rated at least `selectsMinRating` stars go to
///   `Selects/`: of the selection when more than one photo is selected, else of
///   the current view (smart folder and filter).
/// - **Delete Rejected…**: after a confirmation, rejected files (and everything
///   already in the session Trash) go to the macOS Trash. A volume without a Trash
///   refuses, and nothing is deleted.
/// - **New Variant**: a second rendition of the focused photo (its edits copied).
///
/// A folder opened in place holds the user's own files: these are disabled there,
/// with the reason. There (and in the demo) **Move to Trash…** sends the photos the user
/// chose, after a confirmation, straight to the macOS Trash instead (dragged back out in
/// Finder, not ⌘Z); never from a memory card or the archive.
@MainActor @Observable
public final class CullFinisher {
    /// One file move, undoable while it is the last thing done.
    struct FileMove: Equatable {
        /// Each original and the folder (and name) it came from.
        var moves: [FolderMove]
        /// Rejected variants hidden by "Move Rejected to Trash".
        var hidden: [PhotoID] = []
        /// `history.undoStack.count` right after the move: undo reverses the move
        /// only when nothing was undoable-edited since.
        var historyDepth: Int
    }

    /// The open session can move originals (created by import).
    public private(set) var canMove = false
    /// The open session can't move originals, but its photos can go to the macOS Trash
    /// (a folder opened in place, the demo): Move to Trash… asks, then sends them.
    public private(set) var canTrashOriginals = false
    /// Why they can't (the folder is on a memory card or in the archive).
    public private(set) var trashOriginalsRefusal: OriginalsTrashRefusal?
    /// Move to Trash… is waiting for the user to confirm.
    public var pendingTrashOriginals: OriginalsTrashPlan?
    /// Delete Rejected… is waiting for the user to confirm (how many files).
    public var pendingDelete: Int?
    /// Move to Selects is waiting for the user to confirm (review N5).
    public var pendingSelects: SelectsPlan?
    public private(set) var busy = false
    private(set) var lastMove: FileMove?

    /// Why the file commands are off here.
    public static let inPlaceReason =
        String(localized: "This folder was opened in place: Luxtable never moves your own files. Import it to organize it.")

    init() {}

    weak var app: AppModel?

    /// Look at the open session (after it opened).
    func refresh() async {
        guard let app, let s = app.currentSession else {
            canMove = false
            canTrashOriginals = false
            trashOriginalsRefusal = nil
            return
        }
        let moves = await (app.sessions as? any SessionFileOrganizing)?.canMoveOriginals(in: s) ?? false
        var trashes = false
        var refusal: OriginalsTrashRefusal?
        if !moves, let trasher = app.sessions as? any OriginalsTrashing {
            refusal = await trasher.originalsTrashRefusal(in: s, archiveTarget: archiveTarget)
            trashes = refusal == nil
        }
        canMove = moves
        canTrashOriginals = trashes
        trashOriginalsRefusal = refusal
    }

    /// The archive folder (never deleted from), when archiving to a folder is set up.
    private var archiveTarget: String? {
        guard let a = app?.settings.archiveSnapshot, a.objectStore == nil else { return nil }
        let t = a.target.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (t as NSString).expandingTildeInPath
    }

    /// [session close] Nothing to confirm or undo any more (⌘Z never moves the closed
    /// session's files back).
    func sessionClosed() {
        canMove = false
        canTrashOriginals = false
        trashOriginalsRefusal = nil
        pendingTrashOriginals = nil
        pendingDelete = nil
        pendingSelects = nil
        lastMove = nil
    }

    var store: (any SessionFileOrganizing)? { app?.sessions as? any SessionFileOrganizing }

    /// Rejected photos (variants) still in Capture or Selects.
    public var rejectedIDs: [PhotoID] {
        (app?.photos ?? []).filter { $0.pick == .rejected && !$0.inTrash }.map(\.id)
    }

    /// The photos of each original file (its variants share it).
    private var files: [[Photo]] {
        Array(Dictionary(grouping: app?.photos ?? []) { $0.url?.standardizedFileURL.path ?? "name:" + $0.filename }.values)
    }

    /// Files "Delete Rejected…" sends to the macOS Trash: already in the session
    /// Trash, or every variant rejected (Rust's `Session::is_rejected`).
    public var rejectedFileCount: Int {
        files.filter { vs in vs.contains(where: \.inTrash) || vs.allSatisfy { $0.pick == .rejected } }.count
    }

    /// What "Move Picked and Rated to Selects" takes (review N5).
    public struct SelectsPlan: Equatable, Sendable {
        public enum Scope: Equatable, Sendable { case selection, view }
        public var ids: [PhotoID]
        public var scope: Scope
        public var minRating: Int

        /// "Move 10 photos to Selects (Picked, or rated ★★★ and up, in the current view)".
        public var message: String {
            let n = ids.count
            let stars = String(repeating: "★", count: minRating)
            let rated = minRating == 5 ? String(localized: "rated \(stars)") : String(localized: "rated \(stars) and up")
            let place = scope == .selection ? String(localized: "in the selection") : String(localized: "in the current view")
            return n == 1 ? String(localized: "Move 1 photo to Selects (Picked, or \(rated), \(place))")
                : String(localized: "Move \(n) photos to Selects (Picked, or \(rated), \(place))")
        }
    }

    /// Picked, or rated `selectsMinRating`+ stars, not in Selects yet (never
    /// rejects): of the selection when more than one photo is selected, else of
    /// what the browser shows.
    public var selectsPlan: SelectsPlan {
        guard let app else { return SelectsPlan(ids: [], scope: .view, minRating: 3) }
        let min = app.settings.selectsMinRating
        let selected = app.selection.count > 1 ? app.visibleIDs.filter(app.selection.contains) : []
        let scope: SelectsPlan.Scope = selected.count > 1 ? .selection : .view
        let ids = (scope == .selection ? selected : app.visibleIDs).filter { id in
            guard let p = app.photo(id) else { return false }
            return (p.pick == .picked || p.rating >= min) && p.pick != .rejected && !p.inSelects && !p.inTrash
        }
        return SelectsPlan(ids: ids, scope: scope, minRating: min)
    }

    public var selectIDs: [PhotoID] { selectsPlan.ids }

    public var trashedIDs: [PhotoID] { (app?.photos ?? []).filter(\.inTrash).map(\.id) }

    /// Files whose every variant is rejected go to the session Trash; a file with a
    /// kept variant stays and only its rejected variants are hidden (review H1).
    public func moveRejectedToTrash() async {
        guard let app, let store, let session = app.currentSession, canMove else {
            app?.show(Toast(Self.inPlaceReason, symbol: "folder", isError: true))
            return
        }
        guard !rejectedIDs.isEmpty else { return }
        busy = true
        defer { busy = false }
        await app.saver.flush()
        do {
            let done = try await store.trashRejected(in: session)
            await app.refreshCurrentSession(keepingHistory: true)
            let did = !done.moves.isEmpty || !done.hidden.isEmpty
            lastMove = did ? FileMove(moves: done.moves, hidden: done.hidden, historyDepth: app.history.undoStack.count) : nil
            if let e = done.error {
                app.show(Toast(String(localized: "Stopped part-way (⌘Z undoes what was done): \(String(describing: e))"), symbol: "exclamationmark.triangle", isError: true))
            } else if did {
                app.show(Toast(Self.trashedMessage(files: done.moves.count, variants: done.hidden.count), symbol: "trash"))
            }
        } catch {
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }

    static func trashedMessage(files: Int, variants: Int) -> String {
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? String(localized: "Moved 1 rejected photo to the session Trash")
                                       : String(localized: "Moved \(files) rejected photos to the session Trash")) }
        if variants > 0 {
            let hid = variants == 1 ? String(localized: "1 rejected variant of photos you kept")
                : String(localized: "\(variants) rejected variants of photos you kept")
            parts.append(parts.isEmpty ? String(localized: "Hid \(hid)") : String(localized: "hid \(hid)"))
        }
        return String(localized: "\(parts.joined(separator: String(localized: " and "))) (⌘Z to undo)")
    }

    /// Ask before moving to Selects (the view shows the count and the rule).
    public func requestMoveToSelects() {
        let plan = selectsPlan
        guard canMove, !plan.ids.isEmpty else { return }
        pendingSelects = plan
    }

    /// The user confirmed: exactly the photos the confirmation counted.
    public func confirmMoveToSelects() async {
        guard let plan = pendingSelects else { return }
        pendingSelects = nil
        await moveToSelects(plan.ids)
    }

    /// Move the current plan's photos without asking.
    public func movePickedToSelects() async {
        await moveToSelects(selectIDs)
    }

    /// These photos' files to the session Trash (⌘Z, or Restore from Session Trash, brings
    /// them back); `focusing`: the photo to show afterwards.
    public func moveToTrash(_ ids: [PhotoID], focusing: PhotoID? = nil) async {
        await move(ids, to: .trash, focusing: focusing,
                   done: { n in n == 1 ? String(localized: "Moved 1 photo to the session Trash (⌘Z to undo)")
                       : String(localized: "Moved \(n) photos to the session Trash (⌘Z to undo)") })
    }

    private func moveToSelects(_ ids: [PhotoID]) async {
        await move(ids, to: .selects,
                   done: { n in n == 1 ? String(localized: "Moved 1 photo to Selects (⌘Z to undo)")
                       : String(localized: "Moved \(n) photos to Selects (⌘Z to undo)") })
    }

    /// Everything in the session Trash back into Capture, and every variant set
    /// aside by "Move Rejected to Trash" or Delete Variant back next to its photo
    /// (found on disk, so it works after a relaunch: review N10).
    public func restoreFromTrash() async {
        guard let app, let store, let session = app.currentSession, canMove else {
            app?.show(Toast(Self.inPlaceReason, symbol: "folder", isError: true))
            return
        }
        busy = true
        defer { busy = false }
        await app.saver.flush()
        do {
            let ids = trashedIDs
            let moves = ids.isEmpty ? [] : try await store.move(ids, to: .capture)
            let variants = try await store.restoreSetAsideVariants(in: session)
            await app.refreshCurrentSession(keepingHistory: true)
            lastMove = nil
            app.show(Toast(Self.restoredMessage(files: moves.count, variants: variants), symbol: "arrow.uturn.backward"))
        } catch {
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }

    static func restoredMessage(files: Int, variants: Int) -> String {
        if files == 0 && variants == 0 { return String(localized: "The session Trash is empty") }
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? String(localized: "1 photo") : String(localized: "\(files) photos")) }
        if variants > 0 { parts.append(variants == 1 ? String(localized: "1 variant") : String(localized: "\(variants) variants")) }
        return String(localized: "Restored \(parts.joined(separator: String(localized: " and "))) from the session Trash")
    }

    /// Ask before "Delete Rejected…" (the view shows the confirmation).
    public func requestDeleteRejected() {
        let n = rejectedFileCount
        guard canMove, n > 0 else { return }
        pendingDelete = n
    }

    public static func deleteMessage(_ n: Int, archiveNote: String? = nil) -> String {
        (n == 1 ? String(localized: "1 rejected file goes to the macOS Trash and leaves this session. You can drag it back out of the Trash in Finder until you empty it.")
            : String(localized: "\(n) rejected files go to the macOS Trash and leave this session. You can drag them back out of the Trash in Finder until you empty it."))
            + (archiveNote.map { "\n\n" + $0 } ?? "")
    }

    /// N2: said in the Delete Rejected… confirmation when the files may not be
    /// on the archive (then the Trash holds the only copy).
    public var deleteArchiveNote: String? {
        guard let app else { return nil }
        guard app.features.isOn(.archive) else { return Self.archiveOffNote }
        return Self.archiveNote(settings: app.settings.archiveSnapshot, state: app.archiveStatus.state)
    }

    static let archiveOffNote = String(localized: "Archiving is off: the Trash holds the only copy.")

    public static func archiveNote(settings: ArchiveSettingsSnapshot, state: ArchiveStatus.State) -> String? {
        if !settings.isActive { return archiveOffNote }
        if !settings.archiveRejected {
            return String(localized: "Rejected photos aren't archived (Settings › Archive): the Trash holds the only copy.")
        }
        if state != .idle { return String(localized: "The archive isn't up to date: some of them may exist only here.") }
        return nil
    }

    /// The user confirmed: rejects to the session Trash, then the session Trash to the macOS Trash.
    public func confirmDeleteRejected() async {
        pendingDelete = nil
        guard let app, let store, let session = app.currentSession, canMove else { return }
        busy = true
        defer { busy = false }
        await app.saver.flush()
        do {
            if !rejectedIDs.isEmpty {
                let done = try await store.trashRejected(in: session)
                if let e = done.error { throw MockError.invalid(e) }
            }
            let n = try await store.emptyTrash(in: session)
            lastMove = nil
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(Toast(n == 1 ? String(localized: "Moved 1 rejected file to the Trash") : String(localized: "Moved \(n) rejected files to the Trash"), symbol: "trash"))
        } catch {
            lastMove = nil
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }

    /// How a photo of this session leaves it: the session Trash (imported, ⌘Z), the macOS
    /// Trash after a confirmation (opened in place, the demo), or not at all (why).
    public enum TrashRoute: Equatable, Sendable {
        case sessionTrash
        case macOSTrash
        case unavailable(String)
    }

    public var trashRoute: TrashRoute {
        if canMove { return .sessionTrash }
        if canTrashOriginals { return .macOSTrash }
        return .unavailable(trashOriginalsRefusal?.reason ?? Self.inPlaceReason)
    }

    /// What Move to Trash… sends to the macOS Trash, for the confirmation.
    public struct OriginalsTrashPlan: Equatable, Sendable {
        public var ids: [PhotoID]
        /// The photo to show afterwards (a neighbour).
        public var focusing: PhotoID?
        /// How many files they are (variants share one).
        public var files: Int
        /// The file's name, when there is one file.
        public var name: String?

        /// "“DSC01234.ARW” goes to the macOS Trash and leaves this session…"
        public var message: String {
            let what = files == 1
                ? String(localized: "“\(name ?? String(localized: "The photo"))” goes to the macOS Trash and leaves this session, with its edits.")
                : String(localized: "\(files) files go to the macOS Trash and leave this session, with their edits.")
            let back = files == 1
                ? String(localized: "⌘Z can’t bring it back: you can drag it back out of the Trash in Finder until you empty it.")
                : String(localized: "⌘Z can’t bring them back: you can drag them back out of the Trash in Finder until you empty it.")
            return what + " " + back
        }

        public var confirmTitle: String {
            files == 1 ? String(localized: "Move 1 File to Trash") : String(localized: "Move \(files) Files to Trash")
        }
    }

    /// Ask before sending `ids` to the macOS Trash (the view shows the confirmation);
    /// `focusing`: the photo to show afterwards. Says why when it can't.
    public func requestTrashOriginals(_ ids: [PhotoID], focusing: PhotoID? = nil) {
        guard let app, !ids.isEmpty else { return }
        guard canTrashOriginals else {
            if case .unavailable(let why) = trashRoute { app.show(Toast(why, symbol: "folder", isError: true)) }
            return
        }
        let photos = ids.compactMap { app.photo($0) }
        let files = Set(photos.map { $0.url?.standardizedFileURL.path ?? "name:" + $0.filename })
        pendingTrashOriginals = OriginalsTrashPlan(ids: ids, focusing: focusing, files: max(files.count, 1),
                                                   name: files.count == 1 ? photos.first?.filename : nil)
    }

    /// The user confirmed: the files go to the macOS Trash and leave the session; their
    /// cover marks (a Best Shot's) go too, and the neighbour is shown.
    public func confirmTrashOriginals() async {
        guard let plan = pendingTrashOriginals else { return }
        pendingTrashOriginals = nil
        guard let app, let store = app.sessions as? any OriginalsTrashing, canTrashOriginals else { return }
        busy = true
        defer { busy = false }
        await app.saver.flush()
        do {
            let n = try await store.trashOriginals(plan.ids, archiveTarget: archiveTarget)
            app.photosLeftSession(plan.ids, focusing: plan.focusing)
            await app.refreshCurrentSession(keepingHistory: true, focusing: plan.focusing)
            app.show(Toast(n == 1 ? String(localized: "Moved 1 file to the Trash") : String(localized: "Moved \(n) files to the Trash"),
                           symbol: "trash"))
        } catch {
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }

    public func newVariant() async {
        guard let app, let store, let id = app.focusedID, app.focusedPhoto?.isVideo == false else { return }
        await app.saver.flush()
        await app.reportSaves?.value // the variant copies the sidecar's optimize report too
        do {
            let v = try await store.newVariant(of: id)
            await app.refreshCurrentSession()
            app.focus(v, extend: false)
            app.show(Toast(String(localized: "New variant of \(app.photo(v)?.filename ?? String(localized: "the photo"))"), symbol: "square.on.square"))
        } catch {
            app.show(error)
        }
    }

    private func move(_ ids: [PhotoID], to folder: SessionFolderKind, focusing: PhotoID? = nil,
                      done: (Int) -> String) async {
        guard let app, let store, canMove else {
            app?.show(Toast(Self.inPlaceReason, symbol: "folder", isError: true))
            return
        }
        guard !ids.isEmpty else { return }
        busy = true
        defer { busy = false }
        await app.saver.flush()
        do {
            let moves = try await store.move(ids, to: folder)
            await app.refreshCurrentSession(keepingHistory: true, focusing: focusing) // review M8: edits stay undoable
            lastMove = folder == .capture || moves.isEmpty ? nil : FileMove(moves: moves, historyDepth: app.history.undoStack.count)
            app.show(Toast(done(moves.count), symbol: folder == .trash ? "trash" : "folder"))
        } catch {
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }

    /// ⌘Z right after a move: true when it undoes the move (nothing edited since).
    func undoesMove(historyDepth: Int) -> Bool {
        lastMove.map { $0.historyDepth == historyDepth } ?? false
    }

    /// A move being undone: later ⌘Zs wait for it (the refresh it ends with would
    /// otherwise overwrite what they undo).
    private(set) var pendingUndo: Task<Void, Never>?

    /// Start undoing the last move (the caller checked `undoesMove`); taken at once,
    /// so a second ⌘Z can't undo it again.
    func startUndoLastMove() {
        guard let m = lastMove else { return }
        lastMove = nil
        pendingUndo = Task { [weak self] in
            await self?.undo(m)
            self?.pendingUndo = nil
        }
    }

    /// Each original back to the folder and name it came from (review M7), and
    /// hidden variants back.
    private func undo(_ m: FileMove) async {
        guard let app, let store, let session = app.currentSession else { return }
        await app.saver.flush()
        do {
            try await store.moveBack(m.moves, hidden: m.hidden, in: session)
            await app.refreshCurrentSession(keepingHistory: true)
            let n = m.moves.count + m.hidden.count
            app.show(Toast(n == 1 ? String(localized: "Undo move of 1 photo") : String(localized: "Undo move of \(n) photos"), symbol: "arrow.uturn.backward"))
        } catch {
            await app.refreshCurrentSession(keepingHistory: true)
            app.show(error)
        }
    }
}

/// Per-model survey and cull state (lives as long as the model).
@MainActor
final class CullState {
    let survey = SurveyModel()
    let finisher = CullFinisher()
}

extension AppModel {
    /// `ids` left the session (sent to the macOS Trash): focus (and the burst strip) moves
    /// on to `focusing` before the list changes, and their cover marks go (saved with the
    /// session).
    func photosLeftSession(_ ids: [PhotoID], focusing: PhotoID?) {
        let b = browserState
        if let focusing, let f = focusedID, ids.contains(f) { focus(focusing, extend: false) }
        if let c = b.picker.current, ids.contains(c), let focusing { b.picker.select(focusing) }
        guard let covers = b.dropCovers(of: ids), let session = currentSession else { return }
        let previous = b.coverSave
        let store = sessions
        b.coverSave = Task { [weak self] in
            await previous?.value // saves land in the order they were made
            do {
                try await store.saveStackCovers(covers, in: session)
            } catch {
                self?.show(error)
            }
        }
    }

    /// What Photo ▸ Move to Trash… takes: the selection when several photos are
    /// selected, else the focused photo.
    public var trashTargets: [PhotoID] {
        let ids = selection.count > 1 ? visibleIDs.filter(selection.contains) : focusedID.map { [$0] } ?? []
        return ids.filter { photo($0).map { !$0.inTrash } ?? false }
    }

    /// The photo to show once `ids` are gone: the focused one if it stays, else the next
    /// one shown after it, else the one before.
    func neighbour(leaving ids: [PhotoID]) -> PhotoID? {
        let gone = Set(ids)
        if let f = focusedID, !gone.contains(f) { return f }
        let order = visibleIDs
        guard let at = (focusedID ?? ids.first).flatMap({ order.firstIndex(of: $0) }) else { return nil }
        return order[at...].first { !gone.contains($0) } ?? order[..<at].last { !gone.contains($0) }
    }

    /// Photo ▸ Move to Trash… (and the browser's context menu): in a session that moves
    /// files the targets go to the session Trash (⌘Z); over the user's own folder they go
    /// to the macOS Trash after a confirmation.
    public func moveTargetsToTrash() async {
        let ids = trashTargets
        guard !ids.isEmpty else { return }
        let next = neighbour(leaving: ids)
        switch cull.trashRoute {
        case .sessionTrash: await cull.moveToTrash(ids, focusing: next)
        case .macOSTrash: cull.requestTrashOriginals(ids, focusing: next)
        case .unavailable(let why): show(Toast(why, symbol: "folder", isError: true))
        }
    }

    /// N-up survey mode (select the best of a burst).
    public var survey: SurveyModel { CullRegistry.state(for: self).survey }
    /// Finishing a cull: rejects to Trash, picks to Selects, delete rejected, variants.
    public var cull: CullFinisher { CullRegistry.state(for: self).finisher }
}

@MainActor
enum CullRegistry {
    private static let table = NSMapTable<AppModel, CullState>.weakToStrongObjects()

    static func state(for model: AppModel) -> CullState {
        if let s = table.object(forKey: model) { return s }
        let s = CullState()
        s.finisher.app = model
        table.setObject(s, forKey: model)
        return s
    }
}
