import Foundation
import LuxtableFFI
@testable import LuxtableCore
import Testing

/// Long work says what it is doing and can be stopped: imports from other apps, merges,
/// AI Cull, the archive and thumbnails.
@MainActor
struct PolishProgressTests {
    // MARK: Imports from other apps

    @Test func anImportStepHasALineAndAFraction() {
        let half = OtherAppImportStep.comparing(done: 999, total: 2000)
        #expect(half.fraction == 0.4995)
        #expect(half.line == "Comparing photo 1,000 of 2,000 with the session…")
        #expect(OtherAppImportStep.comparing(done: 2000, total: 2000).line == "Comparing photo 2,000 of 2,000 with the session…")
        #expect(OtherAppImportStep.comparing(done: 5, total: 2).fraction == 1)
        let unknown = OtherAppImportStep.comparing(done: 0, total: 0)
        #expect(unknown.fraction == nil && unknown.line == "Comparing the photos with the session…")
        #expect(OtherAppImportStep.writing.fraction == nil && OtherAppImportStep.writing.line == "Writing the changes…")
    }

    @Test func theRelayTurnsRustEventsIntoSteps() {
        let seen = Seen()
        let relay = OtherAppImportRelay { seen.add($0) }
        func send(_ kind: String, _ done: UInt64 = 0, _ total: UInt64 = 0) {
            relay.onProgress(event: ProgressEvent(taskId: 1, kind: kind, phase: .running, completed: done, total: total, detail: nil))
        }
        send("import.compare", 3, 10)
        send("hash", 1, 2) // someone else's event
        send("import.write")
        #expect(seen.steps == [.comparing(done: 3, total: 10), .writing])
    }

    @Test func runningWorkShowsItsStepAndStopsBeingCancellableOnceItWrites() async throws {
        let work = OtherAppImportWork()
        let gate = Gate()
        #expect(!work.isRunning && !work.canCancel)
        work.cancel() // nothing running: nothing happens
        let run = Task {
            try await work.run { report in
                report(.comparing(done: 1, total: 4))
                await gate.wait()
                report(.writing)
                await gate.wait()
                return 7
            }
        }
        #expect(await waitUntil { work.step == .comparing(done: 1, total: 4) })
        #expect(work.isRunning && work.canCancel)
        await gate.open()
        #expect(await waitUntil { work.step == .writing })
        #expect(work.isRunning && !work.canCancel, "writing runs to the end")
        await gate.open()
        #expect(try await run.value == 7)
        #expect(!work.isRunning && work.step == nil)
    }

    @Test func cancellingTheWorkOrItsCallerCancelsWhatItRuns() async {
        let work = OtherAppImportWork()
        let first = Task { try await work.run { _ in try await Task.sleep(for: .seconds(3600)) } }
        #expect(await waitUntil { work.isRunning })
        work.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!work.isRunning)
        // A dry run replaced by a newer one: its caller is cancelled, and the newer run's state is kept.
        let old = Task { try await work.run { _ in try await Task.sleep(for: .seconds(3600)) } }
        #expect(await waitUntil { work.isRunning })
        let newer = Task { try await work.run { report in
            report(.comparing(done: 0, total: 1))
            try await Task.sleep(for: .seconds(3600))
        } }
        #expect(await waitUntil { work.step == .comparing(done: 0, total: 1) })
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(work.isRunning && work.step == .comparing(done: 0, total: 1), "the older run ending changes nothing")
        work.cancel()
        await #expect(throws: CancellationError.self) { try await newer.value }
        #expect(!work.isRunning && work.step == nil)
    }

    // MARK: Merges

    @Test func aMergeNamesItsStage() {
        #expect(MergeModel.Stage(fraction: 0) == .reading && MergeModel.Stage(fraction: 0.29) == .reading)
        #expect(MergeModel.Stage(fraction: 0.3) == .merging && MergeModel.Stage(fraction: 0.89) == .merging)
        #expect(MergeModel.Stage(fraction: 0.9) == .writing && MergeModel.Stage(fraction: 1) == .writing)
        #expect(MergeModel.stageLine(.reading, kind: .hdr, photos: 3) == "Reading the 3 photos…")
        #expect(MergeModel.stageLine(.merging, kind: .hdr, photos: 3) == "Aligning and merging the exposures…")
        #expect(MergeModel.stageLine(.merging, kind: .panorama, photos: 3) == "Aligning and stitching the panorama…")
        #expect(MergeModel.stageLine(.merging, kind: .burst, photos: 3) == "Aligning the frames and taking the best of each…")
        #expect(MergeModel.stageLine(.writing, kind: .burst, photos: 3) == "Writing the new photo and adding it to the session…")
    }

    // MARK: AI Cull

    @Test func stoppingAICullChangesNothing() async {
        let settings = makeSettings()
        settings.onboardingComplete = true
        let m = AppModel(sessions: MockSessionStore(counts: [12]), images: MockImageProvider(latency: .zero),
                         renderer: FakeRenderer(), importer: MockImportService(bytesPerSecond: 1e12),
                         archive: MockArchiveService(target: "/nonexistent/archive", interval: .seconds(3600), step: .milliseconds(1),
                                                     isReachable: { _ in true }),
                         ai: EndlessCull(), settings: settings)
        m.watchCards = false
        await m.start()
        m.cancelAICull() // nothing running: no toast
        #expect(m.toast == nil)
        let run = Task { await m.runAICull() }
        #expect(await waitUntil { m.cullProgress?.done == 3 })
        m.cancelAICull()
        #expect(m.cullProgress == nil, "the toolbar goes back to the button at once")
        #expect(m.toast?.message == "AI Cull stopped: nothing was changed")
        await run.value
        #expect(m.cullSuggestions.isEmpty && m.photos.allSatisfy { $0.pick == PickState.none })
        #expect(m.history.undoLabel == nil)
    }

    // MARK: Archive

    @Test func stoppingTheDemoArchiveEndsItsRun() async {
        let archive = MockArchiveService(target: "/nonexistent/archive", interval: .seconds(3600), step: .milliseconds(20),
                                         isReachable: { _ in true })
        let run = Task { await archive.syncNow() }
        #expect(await waitUntil {
            if case .syncing = archive.status.state { true } else { false }
        })
        await archive.stopSync()
        await run.value
        #expect(archive.status.state == .behind(files: 1) && archive.status.lastSuccess == nil)
        await archive.syncNow() // Sync Now starts again and finishes
        #expect(archive.status.state == .idle && archive.status.lastSuccess != nil)
        await UnavailableArchiveService(target: "x").stopSync() // nothing to stop
    }

    // MARK: Thumbnails

    @Test func thumbnailsBeingMadeAreCountedAndOnlyShownWhenSlow() async {
        let activity = ThumbnailActivity()
        activity.delay = .milliseconds(30)
        #expect(activity.pending == 0 && !activity.isBusy)
        activity.began()
        activity.ended()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!activity.isBusy, "a quick load never shows")
        activity.began()
        activity.began()
        #expect(activity.pending == 2 && activity.label == "Loading 2 thumbnails…")
        #expect(await waitUntil { activity.isBusy })
        activity.ended()
        #expect(activity.isBusy && activity.label == "Loading 1 thumbnail…")
        activity.ended()
        activity.ended() // one too many changes nothing
        #expect(activity.pending == 0 && !activity.isBusy)
    }

    @Test func theCacheCountsItsLoads() async {
        let cache = ThumbnailCache(provider: MockImageProvider(latency: .milliseconds(40)))
        let photo = samplePhoto(1)
        let load = Task { await cache.image(for: photo, bucket: 256) }
        #expect(await waitUntil { cache.activity.pending == 1 })
        #expect(await load.value != nil)
        #expect(cache.activity.pending == 0)
        _ = await cache.image(for: photo, bucket: 256) // cached: nothing to make
        #expect(cache.activity.pending == 0 && cache.hits == 1)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [OtherAppImportStep] = []
    var steps: [OtherAppImportStep] { lock.withLock { all } }
    func add(_ s: OtherAppImportStep) { lock.withLock { all.append(s) } }
}

/// Lets a test step a piece of work forward.
private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opens = 0
    func wait() async {
        if opens > 0 {
            opens -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        if waiting.isEmpty { opens += 1 } else { waiting.removeFirst().resume() }
    }
}

/// Scores three photos, then never finishes (until cancelled).
private struct EndlessCull: AIService {
    func cull(_ photos: [Photo], images: any ImageProvider,
              progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [CullSuggestion] {
        progress(3, photos.count)
        try await Task.sleep(for: .seconds(3600))
        return []
    }

    func autoAdjust(_ photo: Photo, current: EditState, images: any ImageProvider) async throws -> EditState { current }
    func applyInstruction(_ text: String, to current: EditState) async throws -> EditState { current }
}
