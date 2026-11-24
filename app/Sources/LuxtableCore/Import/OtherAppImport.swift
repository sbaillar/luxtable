import Foundation
import LuxtableFFI
import Observation

/// What an import from another app (Capture One, Lightroom, Aperture or iPhoto) is doing,
/// for its sheet. The import first compares every photo the other app knows with the
/// session and only then writes, so it can be cancelled until the writing starts.
public enum OtherAppImportStep: Equatable, Sendable {
    /// `done` of `total` of the other app's photos compared (nothing is written yet).
    case comparing(done: Int, total: Int)
    /// Writing what the comparison found: runs to the end.
    case writing

    /// 0…1 while comparing; `nil` while writing (no count to show).
    public var fraction: Double? {
        guard case .comparing(let done, let total) = self else { return nil }
        return total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    public var line: String {
        switch self {
        case .comparing(let done, let total):
            total > 0 ? String(localized: "Comparing photo \(min(done + 1, total).formatted()) of \(total.formatted()) with the session…")
                : String(localized: "Comparing the photos with the session…")
        case .writing: String(localized: "Writing the changes…")
        }
    }

    /// The Rust import's progress events (lt-ffi `ImportSteps`).
    init?(_ e: ProgressEvent) {
        switch e.kind {
        case "import.compare": self = .comparing(done: Int(clamping: e.completed), total: Int(clamping: e.total))
        case "import.write": self = .writing
        default: return nil
        }
    }
}

/// Forwards an import's progress events from Rust as steps.
final class OtherAppImportRelay: ProgressListener, @unchecked Sendable {
    private let report: @Sendable (OtherAppImportStep) -> Void

    init(_ report: @escaping @Sendable (OtherAppImportStep) -> Void) { self.report = report }

    func onProgress(event: ProgressEvent) {
        if let step = OtherAppImportStep(event) { report(step) }
    }
}

/// The running part of an import sheet (the dry run or the import): its step for the
/// progress bar, and Cancel. One at a time.
@MainActor @Observable
public final class OtherAppImportWork {
    public private(set) var step: OtherAppImportStep?
    public private(set) var isRunning = false
    @ObservationIgnored private var cancelRunning: (() -> Void)?
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Cancel stops the work only before it writes.
    public var canCancel: Bool { isRunning && step != .writing }

    public func cancel() {
        cancelRunning?()
    }

    /// Run `work`, showing the steps it reports. Throws `CancellationError` when cancelled
    /// in time (nothing was written).
    func run<T: Sendable>(_ work: @escaping @Sendable (@escaping @Sendable (OtherAppImportStep) -> Void) async throws -> T) async throws -> T {
        generation += 1
        let current = generation
        step = nil
        isRunning = true
        let task = Task {
            try await work { [weak self] step in
                Task { @MainActor in self?.note(step, of: current) }
            }
        }
        cancelRunning = { task.cancel() }
        defer {
            if generation == current { // unless a newer run took over (a dry run redone)
                generation += 1 // a step still on its way belongs to nothing
                cancelRunning = nil
                isRunning = false
                step = nil
            }
        }
        // Cancelling the caller (a dry run replaced by a newer one) cancels the work too.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func note(_ step: OtherAppImportStep, of generation: Int) {
        guard generation == self.generation else { return }
        self.step = step
    }
}
