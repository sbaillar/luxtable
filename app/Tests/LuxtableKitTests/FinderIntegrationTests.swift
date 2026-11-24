import CoreTransferable
import Foundation
@testable import LuxtableCore
import Testing
import UniformTypeIdentifiers

/// Photos dragged out to the Finder, and folders the Finder asks Luxtable to open.
@MainActor
struct FinderIntegrationTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lt-finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aDraggedPhotoArrivesAsACopyAndTheOriginalStays() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("DSC00001.ARW")
        try Data("raw bytes".utf8).write(to: original)
        let drop = dir.appendingPathComponent("dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)

        let file = PhotoFile(id: PhotoID(1), url: original)
        #expect(PhotoFile.exportedContentTypes() == [.data])
        let received = try await file.export(to: drop, contentType: UTType.data)
        #expect(received.lastPathComponent == "DSC00001.ARW", "under the photo's own name")
        #expect(received.standardizedFileURL != original.standardizedFileURL, "a copy, never the original")
        #expect(try Data(contentsOf: received) == Data("raw bytes".utf8))
        try FileManager.default.removeItem(at: received) // whatever the receiver does with its copy…
        #expect(try Data(contentsOf: original) == Data("raw bytes".utf8), "…the session's file is untouched")
    }

    @Test func aDragCarriesTheSelectionInBrowserOrderAndOnlyRealFiles() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = makeModel()
        await m.start()
        let ids = Array(m.visibleIDs.prefix(4))
        // The demo photos have no file: give three of them one (the third's is missing).
        for (n, id) in ids.prefix(3).enumerated() {
            let url = dir.appendingPathComponent("P\(n).ARW")
            if n != 2 { try Data([UInt8(n)]).write(to: url) }
            m.updatePhotos([id], label: "file") { $0.url = url }
        }
        m.focus(ids[2], extend: false)
        m.focus(ids[0], extend: true)
        #expect(m.dragSelection == Array(ids.prefix(3)), "the browser's order, not the order of selection")
        let files = m.dragFiles(for: [ids[3], ids[2], ids[1], ids[0]])
        #expect(files.map(\.id) == [ids[0], ids[1]], "a missing original and a photo without a file are left out")
        #expect(files.map(\.url.lastPathComponent) == ["P0.ARW", "P1.ARW"])
        #expect(m.dragFiles(for: []).isEmpty)
    }

    @Test func aFolderFromTheFinderAtLaunchOpensInsteadOfTheLastSession() async throws {
        let store = RecordingFolderStore()
        let m = makeModel(store: store)
        let folder = URL(fileURLWithPath: "/tmp/lt-finder-shoot", isDirectory: true)
        m.openFromFinder(folder) // the launch itself: nothing is opened before start()
        #expect(m.pendingFolder == folder)
        #expect(await store.opened.isEmpty)
        await m.start()
        #expect(m.currentSession == nil, "the last session is not reopened first")
        await m.openPendingFolder()
        await m.openTask?.value
        #expect(await store.opened == [folder])
        #expect(m.pendingFolder == nil)
        #expect(m.currentSession?.url == folder)
    }

    @Test func aFolderFromTheFinderWhileRunningOpensAtOnceAndAFileMeansItsFolder() async throws {
        let store = RecordingFolderStore()
        let m = makeModel(store: store)
        await m.start()
        await m.openPendingFolder() // nothing pending
        #expect(await store.opened.isEmpty)
        m.openFromFinder(URL(fileURLWithPath: "/tmp/lt-finder-shoot/DSC00001.ARW"))
        try await eventually { await store.opened.count == 1 }
        #expect(await store.opened.first?.path == "/tmp/lt-finder-shoot")
        m.openFromFinder(URL(string: "https://example.com/folder")!)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await store.opened.count == 1, "only files and folders")
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }
}

/// Opens any folder as an empty session and remembers which ones it was asked for.
private actor RecordingFolderStore: FolderSessionOpening {
    private(set) var opened: [URL] = []
    private var sessions: [SessionInfo] = []
    func listSessions() async throws -> [SessionInfo] { sessions }
    func photos(in session: SessionInfo) async throws -> [Photo] { [] }
    func albums(in session: SessionInfo) async throws -> [Album] { [] }
    func createSession(named name: String) async throws -> SessionInfo { throw MockError.invalid("no") }
    func save(photos: [Photo]) async throws {}
    func edit(for id: PhotoID) async throws -> EditState { EditState() }
    func save(edits: [PhotoID: EditState]) async throws {}
    var lastFailures: [URL] { [] }
    func removeMissing(_ ids: [PhotoID]) async throws {}
    func locate(_ id: PhotoID, at url: URL) async throws {}
    func restorePrevious(_ id: PhotoID) async throws {}
    func dismissFileChanged(_ id: PhotoID) async throws {}
    func restoreToFolder(_ id: PhotoID) async throws {}
    func relocate(_ session: SessionInfo, to folder: URL) async throws -> SessionInfo { throw MockError.invalid("no") }

    func add(folder: URL, progress: @escaping @Sendable (OpenProgress) -> Void) async throws -> SessionInfo {
        opened.append(folder)
        let s = SessionInfo(name: folder.lastPathComponent, url: folder, photoCount: 0, createdAt: Date())
        sessions.append(s)
        return s
    }
}
