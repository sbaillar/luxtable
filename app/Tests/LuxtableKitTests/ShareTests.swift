import AppKit
import Foundation
import ImageIO
import Testing
@testable import LuxtableCore

// MARK: - Doubles

/// Writes one small file per photo into the job's folder (in reverse order, as a
/// parallel export may finish them), reporting progress after each.
private final class ShareFakeExport: ExportService, @unchecked Sendable {
    var problem: String?
    var fail: Error?
    /// Photos (by seq) that fail instead of being written.
    var failing: Set<Int> = []
    /// While set, the run pauses after the first photo (a deterministic "rendering").
    var hold = false
    var reportsCancelled = false
    private(set) var jobs: [ExportJob] = []

    func validate(_ recipes: [ExportRecipe], defaultFolder: URL) -> String? { problem }
    func previewFileName(template: String, sample: ExportFileNameSample, seq: Int, ext: String) -> String? { nil }

    func export(_ job: ExportJob, progress: @escaping @Sendable (ExportProgressUpdate) -> Void) async throws -> ExportOutcome {
        jobs.append(job)
        progress(ExportProgressUpdate(done: 0, total: job.items.count, readingMetadata: true))
        var written: [ExportedOutput] = [], failures: [String] = []
        for (i, item) in job.items.reversed().enumerated() {
            if failing.contains(item.seq) {
                failures.append("\(item.url.deletingPathExtension().lastPathComponent) · Share: unreadable")
            } else {
                let url = job.defaultFolder.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".jpg")
                try Data("jpeg".utf8).write(to: url)
                written.append(ExportedOutput(photoID: item.photoID, recipeName: "Share", url: url, width: 2048,
                                              height: 1365, bytes: 4))
            }
            progress(ExportProgressUpdate(done: i + 1, total: job.items.count))
            while hold { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let fail { throw fail }
        return ExportOutcome(written: written, failures: failures, cancelled: reportsCancelled, jpegEncoder: "imageio")
    }
}

/// Records what it was asked to share; the test answers for the user.
@MainActor
private final class FakeSharePicker: SharePresenting {
    private(set) var shown: [[URL]] = []
    private var completion: (@MainActor (ShareChoice) -> Void)?
    /// Answer at once instead of waiting for `answer(_:)`.
    var immediate: ShareChoice?

    func present(_ files: [URL], completion: @escaping @MainActor (ShareChoice) -> Void) {
        shown.append(files)
        if let immediate { completion(immediate) } else { self.completion = completion }
    }

    func answer(_ choice: ShareChoice) { completion?(choice); completion = nil }
}

private struct ShareTestError: LocalizedError {
    var errorDescription: String? { "disk gone" }
}

private func shareRoot() -> ShareFolders {
    ShareFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("lt-share-\(UUID())", isDirectory: true))
}

private func shareItems(_ n: Int) -> [ExportJobItem] {
    (1...max(n, 1)).prefix(n).map {
        ExportJobItem(photoID: PhotoID(Int64($0)), url: URL(fileURLWithPath: "/photos/DSC0\($0).ARW"), seq: $0)
    }
}

private func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

// MARK: - Settings and folders

@MainActor
@Suite struct ShareSettingsTests {
    @Test func defaultsAreAWebJPEGWithoutLocation() {
        let s = ShareSettings()
        #expect(s.longEdge == 2048 && s.quality == 85 && !s.includeLocation)
        let r = s.recipe
        #expect(r.format == .jpeg && r.quality == 85 && r.sizeMode == .longEdge && r.sizeValue == 2048)
        #expect(r.space == .sRGB && !r.allowUpscale && r.sharpen == 0.4 && r.fileNameTemplate == "{name}")
        #expect(r.includeMetadata && r.stripGPS && !r.labelTags, "credits and caption go, location and Luxtable tags don't")
        #expect(r.destination == nil && r.subfolder.isEmpty && r.watermark == nil && r.googlePhotos == nil)
        #expect(s.summary == "JPEG 85 · 2048 px · no location")
        var withGPS = s
        withGPS.includeLocation = true
        #expect(!withGPS.recipe.stripGPS && withGPS.summary.hasSuffix("with location"))
    }

    @Test func outOfRangeValuesFallBackOrClamp() {
        #expect(ShareSettings(longEdge: 999).longEdge == 2048)
        #expect(ShareSettings(longEdge: 4096).longEdge == 4096)
        #expect(ShareSettings(quality: 5).quality == 60 && ShareSettings(quality: 150).quality == 100)
    }

    @Test func savedSettingsRoundTrip() {
        let d = testDefaults()
        #expect(ShareSettings(defaults: d) == ShareSettings(), "nothing saved: the defaults")
        let s = ShareSettings(longEdge: 3072, quality: 92, includeLocation: true)
        s.save(to: d)
        #expect(ShareSettings(defaults: d) == s)
        d.set(12, forKey: "shareLongEdge")
        #expect(ShareSettings(defaults: d).longEdge == 2048)
    }
}

@Suite struct ShareFoldersTests {
    @Test func makeRemoveAndSweep() throws {
        let folders = shareRoot()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let old = try folders.make(), recent = try folders.make()
        #expect(old != recent && old.deletingLastPathComponent().standardizedFileURL == folders.root.standardizedFileURL)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-2 * ShareFolders.sweepAge)],
                                              ofItemAtPath: old.path)
        folders.sweep()
        #expect(!exists(old) && exists(recent), "only folders an hour old go")
        folders.sweep(olderThan: 0, now: Date().addingTimeInterval(1))
        #expect(!exists(recent))
        // Never anything outside the root.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("lt-share-outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        folders.remove(outside)
        #expect(exists(outside))
        // A root that doesn't exist yet: nothing to sweep.
        shareRoot().sweep()
    }
}

// MARK: - The share model

@MainActor
@Suite struct ShareModelTests {
    private func model(_ n: Int, _ service: ShareFakeExport = ShareFakeExport(), picker: FakeSharePicker = FakeSharePicker(),
                       folders: ShareFolders = shareRoot()) -> ShareModel {
        ShareModel(items: shareItems(n), settings: ShareSettings(longEdge: 3072), service: service,
                   credit: ("A. Photographer", "© 2026"), folders: folders, presenter: picker)
    }

    @Test func rendersThenSharesInSelectionOrderAndCleansUpLater() async throws {
        let export = ShareFakeExport(), picker = FakeSharePicker()
        let m = model(3, export, picker: picker)
        m.cleanupDelay = .milliseconds(20)
        defer { try? FileManager.default.removeItem(at: m.folders.root) }
        #expect(m.phase == .idle && !m.isBusy && m.progressText == nil && m.fraction == 0)
        m.start()
        #expect(m.isRendering && m.isBusy && m.progressText == "Preparing 1 of 3 photos to share…")
        await m.waitUntilRendered()
        #expect(m.phase == .picking && m.isBusy && !m.isRendering)
        let job = try #require(export.jobs.first)
        var expected = ShareSettings(longEdge: 3072).recipe
        expected.id = try #require(job.recipes.first).id
        #expect(job.recipes == [expected] && job.items.map(\.seq) == [1, 2, 3])
        #expect(job.artist == "A. Photographer" && job.copyright == "© 2026")
        let folder = try #require(m.folder)
        #expect(job.defaultFolder == folder && folder.deletingLastPathComponent() == m.folders.root)
        #expect(picker.shown == [m.files] && m.files.map(\.lastPathComponent) == ["DSC01.jpg", "DSC02.jpg", "DSC03.jpg"])
        picker.answer(.chosen("Messages"))
        #expect(m.phase == .shared("Messages") && !m.isBusy)
        #expect(exists(folder), "kept while Messages reads the files")
        await m.waitUntilCleanedUp()
        #expect(!exists(folder) && m.folder == nil)
        picker.answer(.dismissed) // a late answer changes nothing
        #expect(m.phase == .shared("Messages"))
    }

    @Test func progressCountsRenderedPhotos() async {
        let export = ShareFakeExport()
        export.hold = true
        let m = model(4, export)
        defer { try? FileManager.default.removeItem(at: m.folders.root) }
        m.start()
        #expect(await waitUntil { m.phase == .rendering(done: 1, total: 4) })
        #expect(m.fraction == 0.25 && m.progressText == "Preparing 2 of 4 photos to share…")
        export.hold = false
        await m.waitUntilRendered()
        #expect(m.phase == .picking)
        let one = model(1)
        defer { try? FileManager.default.removeItem(at: one.folders.root) }
        one.start()
        #expect(one.progressText == "Preparing the photo to share…")
        await one.waitUntilRendered()
    }

    @Test func closingThePickerRemovesTheFilesAtOnce() async throws {
        let picker = FakeSharePicker()
        picker.immediate = .dismissed
        let m = model(2, picker: picker)
        defer { try? FileManager.default.removeItem(at: m.folders.root) }
        m.start()
        await m.waitUntilRendered()
        #expect(m.phase == .dismissed && m.folder == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: m.folders.root.path).isEmpty)
    }

    @Test func noWindowForThePickerFails() async {
        let picker = FakeSharePicker()
        picker.immediate = .unavailable
        let m = model(1, picker: picker)
        var reports: [String] = []
        m.report = { message, isError in if isError { reports.append(message) } }
        defer { try? FileManager.default.removeItem(at: m.folders.root) }
        m.start()
        await m.waitUntilRendered()
        #expect(m.phase == .failed("The share menu couldn't open. Show the Luxtable window and try again."))
        #expect(reports.count == 1 && m.folder == nil)
    }

    @Test func cancelStopsTheRenderAndSharesNothing() async throws {
        let export = ShareFakeExport(), picker = FakeSharePicker()
        export.hold = true
        let m = model(3, export, picker: picker)
        defer { try? FileManager.default.removeItem(at: m.folders.root) }
        m.start()
        #expect(await waitUntil { m.phase == .rendering(done: 1, total: 3) })
        let folder = try #require(m.folder)
        m.cancel()
        await m.waitUntilRendered()
        #expect(m.phase == .cancelled && !exists(folder) && picker.shown.isEmpty)
        m.cancel() // not rendering: nothing to do
        #expect(m.phase == .cancelled)
        // An export that reports itself cancelled ends the same way.
        let reported = ShareFakeExport()
        reported.reportsCancelled = true
        let n = model(1, reported, picker: picker)
        defer { try? FileManager.default.removeItem(at: n.folders.root) }
        n.start()
        await n.waitUntilRendered()
        #expect(n.phase == .cancelled && n.folder == nil && picker.shown.isEmpty)
    }

    @Test func failuresAreReported() async {
        // The export throws.
        let broken = ShareFakeExport()
        broken.fail = ShareTestError()
        let a = model(2, broken)
        defer { try? FileManager.default.removeItem(at: a.folders.root) }
        a.start()
        await a.waitUntilRendered()
        #expect(a.phase == .failed("disk gone") && a.folder == nil)

        // Every photo failed: nothing to share.
        let none = ShareFakeExport()
        none.failing = [1, 2]
        let picker = FakeSharePicker()
        let b = model(2, none, picker: picker)
        defer { try? FileManager.default.removeItem(at: b.folders.root) }
        b.start()
        await b.waitUntilRendered()
        #expect(b.phase == .failed("Couldn't prepare the photos to share. DSC02 · Share: unreadable"))
        #expect(b.folder == nil && picker.shown.isEmpty)

        // Some failed: the rest are shared, and the user is told.
        let some = ShareFakeExport()
        some.failing = [2]
        let c = model(3, some, picker: picker)
        var reports: [String] = []
        c.report = { message, _ in reports.append(message) }
        defer { try? FileManager.default.removeItem(at: c.folders.root) }
        c.start()
        await c.waitUntilRendered()
        #expect(c.phase == .picking && c.files.map(\.lastPathComponent) == ["DSC01.jpg", "DSC03.jpg"])
        #expect(reports == ["1 photo couldn't be prepared and isn't shared."] && c.failures.count == 1)
        let two = ShareFakeExport()
        two.failing = [1, 3]
        let d = model(4, two, picker: picker)
        var more: [String] = []
        d.report = { message, _ in more.append(message) }
        defer { try? FileManager.default.removeItem(at: d.folders.root) }
        d.start()
        await d.waitUntilRendered()
        #expect(more == ["2 photos couldn't be prepared and aren't shared."])
    }

    @Test func nothingStartsWithoutPhotosOrWithABadRecipe() throws {
        let empty = model(0)
        empty.start()
        #expect(empty.phase == .failed("Select photos to share.") && empty.folder == nil)
        let invalid = ShareFakeExport()
        invalid.problem = "Quality must be 1–100"
        let m = model(1, invalid)
        m.start()
        #expect(m.phase == .failed("Quality must be 1–100") && invalid.jobs.isEmpty && m.folder == nil)
        m.start() // only once
        #expect(invalid.jobs.isEmpty)
        // The temporary folder can't be made (its root is a file).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lt-share-file-\(UUID())")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let blocked = model(1, folders: ShareFolders(root: file))
        blocked.start()
        guard case .failed(let message) = blocked.phase else { Issue.record("\(blocked.phase)"); return }
        #expect(message.hasPrefix("Couldn't make a temporary folder to share from"))
    }
}

// MARK: - App wiring

@MainActor
@Suite(.serialized) struct ShareAppTests {
    private func appModel(store: (any SessionStore)? = nil) async -> (AppModel, ShareFakeExport, FakeSharePicker) {
        let m = makeModel(store: store)
        let export = ShareFakeExport(), picker = FakeSharePicker()
        m.exporter = export
        m.sharePresenter = picker
        m.shareFolders = shareRoot()
        await m.start()
        return (m, export, picker)
    }

    @Test func shareCommandNeedsPhotoFiles() async {
        let (m, _, _) = await appModel()
        defer { try? FileManager.default.removeItem(at: m.shareFolders.root) }
        #expect(MenuCommand.share.shortcut == .init(key: "e", modifiers: [.command, .option]))
        #expect(KeyPreset.lightroomClassic.shortcut(.share) != KeyPreset.lightroomClassic.shortcut(.exportSelected))
        #expect(CommandCatalog.title(.share, model: m) == "Share…")
        #expect(CommandCatalog.help(.share, model: m)?.contains("Settings ▸ Sharing") == true)
        // Demo photos have no files.
        #expect(!CommandCatalog.isEnabled(.share, model: m) && !m.canShare)
        CommandCatalog.perform(.share, model: m)
        #expect(m.share == nil && m.toast?.message == "Select photos to share")
        m.selection = Set(m.visibleIDs.prefix(2))
        #expect(CommandCatalog.title(.share, model: m) == "Share 2 Photos…")
        #expect(ToolbarControl.share.control(m).label == "Share 2 Photos")
    }

    @Test func shareRendersTheSelectionAndOpensThePicker() async throws {
        let (m, export, picker) = await appModel(store: DerivingStore(counts: [6]))
        defer { try? FileManager.default.removeItem(at: m.shareFolders.root) }
        #expect(await waitUntil { m.visibleIDs.count == 6 })
        m.settings.userDefaults.set(4096, forKey: "shareLongEdge")
        m.selection = Set(m.visibleIDs.prefix(2))
        #expect(CommandCatalog.isEnabled(.share, model: m))
        export.hold = true
        CommandCatalog.perform(.share, model: m)
        let share = try #require(m.share)
        #expect(share.settings.longEdge == 4096 && share.items.count == 2 && share.isBusy)
        #expect(!m.canShare && !CommandCatalog.isEnabled(.share, model: m), "one share at a time")
        m.beginShare()
        #expect(m.share === share)
        export.hold = false
        await share.waitUntilRendered()
        #expect(share.phase == .picking && picker.shown.count == 1 && export.jobs.count == 1)
        picker.answer(.dismissed)
        #expect(m.canShare)
        // A failure shows as a toast.
        export.fail = ShareTestError()
        m.beginShare()
        let failed = try #require(m.share)
        #expect(failed !== share)
        await failed.waitUntilRendered()
        #expect(m.toast?.message == "disk gone" && m.toast?.isError == true)
    }
}

// MARK: - The AppKit picker

@MainActor
@Suite struct PlatformSharePickerTests {
    @Test func withoutAWindowThePickerIsUnavailable() {
        let picker = PlatformSharePicker()
        var choice: ShareChoice?
        // A view in no window is no anchor; the test process has no key window.
        picker.anchor = NSView()
        picker.present([URL(fileURLWithPath: "/tmp/x.jpg")]) { choice = $0 }
        #expect(choice == .unavailable)
        // A delegate answer with no picker open is ignored.
        picker.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil)
        #expect(choice == .unavailable)
    }
}

// MARK: - Live (sample RAWs)

@MainActor
@Suite struct ShareLiveTests {
    /// A real render: a 2048 px sRGB JPEG without the GPS position.
    @Test func sharedJPEGIsSmallAndHasNoLocation() async throws {
        guard let raw = sampleARWs().first else { return }
        let picker = FakeSharePicker()
        let folders = shareRoot()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let item = ExportJobItem(photoID: PhotoID(1), url: raw, seq: 1,
                                 location: GeoPoint(latitude: 48.85, longitude: 2.35))
        let m = ShareModel(items: [item], settings: ShareSettings(), service: RustExportService(), folders: folders,
                           presenter: picker)
        m.start()
        await m.waitUntilRendered()
        #expect(m.phase == .picking, "\(m.phase)")
        let file = try #require(m.files.first)
        #expect(file.pathExtension == "jpg")
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(w, h) == 2048)
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "no location unless Settings ▸ Sharing says so")
        picker.answer(.dismissed)
        #expect(!exists(file))
    }
}
