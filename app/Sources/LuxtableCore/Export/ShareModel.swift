import Foundation
import Observation

/// How Share… sizes its JPEGs (Settings ▸ Sharing), saved in the app's defaults.
///
/// The files are what a "Web" export writes: JPEG, sRGB, light output sharpening, the
/// photo's metadata (credits, caption, keywords) without the GPS position, place names,
/// or the colour-label and pick keywords. The location goes in only when the user turns
/// it on here.
public struct ShareSettings: Equatable, Sendable {
    /// The long-edge sizes offered: small enough for Messages and Mail, large enough for a 4K screen.
    public static let longEdges = [2048, 3072, 4096]
    public static let qualities = 60...100

    public var longEdge = 2048
    public var quality = 85
    public var includeLocation = false

    public init(longEdge: Int = 2048, quality: Int = 85, includeLocation: Bool = false) {
        self.longEdge = Self.longEdges.contains(longEdge) ? longEdge : 2048
        self.quality = min(max(quality, Self.qualities.lowerBound), Self.qualities.upperBound)
        self.includeLocation = includeLocation
    }

    enum Keys {
        static let longEdge = "shareLongEdge"
        static let quality = "shareQuality"
        static let includeLocation = "shareIncludeLocation"
    }

    /// The saved settings (the defaults for what was never saved or is out of range).
    public init(defaults: UserDefaults) {
        self.init(longEdge: defaults.object(forKey: Keys.longEdge) as? Int ?? 2048,
                  quality: defaults.object(forKey: Keys.quality) as? Int ?? 85,
                  includeLocation: defaults.bool(forKey: Keys.includeLocation))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(longEdge, forKey: Keys.longEdge)
        defaults.set(quality, forKey: Keys.quality)
        defaults.set(includeLocation, forKey: Keys.includeLocation)
    }

    /// The export recipe Share… renders through (the folder is the share's temporary one).
    public var recipe: ExportRecipe {
        ExportRecipe(name: "Share", format: .jpeg, quality: quality, sizeMode: .longEdge, sizeValue: Double(longEdge),
                     space: .sRGB, sharpen: 0.4, fileNameTemplate: "{name}", includeMetadata: true,
                     stripGPS: !includeLocation, labelTags: false)
    }

    /// "JPEG 85 · 2048 px · no location", for Settings.
    public var summary: String {
        includeLocation ? String(localized: "JPEG \(quality) · \(String(longEdge)) px · with location")
            : String(localized: "JPEG \(quality) · \(String(longEdge)) px · no location")
    }
}

/// The temporary folders Share… renders into: one per share under `root`. A folder is
/// kept while the service the user chose may still be reading it, then removed after
/// `ShareModel.cleanupDelay`; whatever is left (a quit in between) is swept at the next
/// launch or share once it is an hour old.
public struct ShareFolders: Sendable {
    public let root: URL
    /// Folders younger than this are never swept (another share may be handing them out).
    public static let sweepAge: TimeInterval = 3600

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Luxtable Share", isDirectory: true)) {
        self.root = root
    }

    /// A new, empty folder for one share.
    func make() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Remove one share's folder (only ever a folder inside `root`).
    func remove(_ folder: URL) {
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Remove the share folders created more than `age` seconds before `now`. Blocking.
    public func sweep(olderThan age: TimeInterval = sweepAge, now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for f in folders {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > age { try? fm.removeItem(at: f) }
        }
    }
}

/// What became of the share picker.
public enum ShareChoice: Equatable, Sendable {
    /// The user picked a service (its title, e.g. "Messages").
    case chosen(String)
    /// Closed without picking one.
    case dismissed
    /// There was nowhere to show it (no window).
    case unavailable
}

/// Shows the system share picker for files (`PlatformSharePicker` in the app; a double in tests).
@MainActor
public protocol SharePresenting: AnyObject {
    func present(_ files: [URL], completion: @escaping @MainActor (ShareChoice) -> Void)
}

/// One Share…: the selected photos rendered through `ShareSettings.recipe` into a
/// temporary folder (with progress, cancelable), then handed to the share picker.
@MainActor @Observable
public final class ShareModel {
    public enum Phase: Equatable {
        case idle
        case rendering(done: Int, total: Int)
        /// The share picker is open.
        case picking
        case shared(String)
        case dismissed
        case cancelled
        case failed(String)
    }

    public let items: [ExportJobItem]
    public let settings: ShareSettings
    public private(set) var phase: Phase = .idle
    /// This share's temporary folder (nil before it starts and once removed).
    public private(set) var folder: URL?
    /// The JPEGs handed to the picker, in selection order.
    public private(set) var files: [URL] = []
    /// Photos that couldn't be rendered ("DSC0001 · Share: …").
    public private(set) var failures: [String] = []

    @ObservationIgnored let service: any ExportService
    @ObservationIgnored let folders: ShareFolders
    @ObservationIgnored let presenter: any SharePresenting
    @ObservationIgnored let credit: (artist: String?, copyright: String?)
    /// How long a shared folder is kept for the service reading it.
    @ObservationIgnored var cleanupDelay: Duration = .seconds(600)
    /// Messages for the user (a toast in the app): text, and whether it is an error.
    @ObservationIgnored public var report: @MainActor (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    public init(items: [ExportJobItem], settings: ShareSettings, service: any ExportService,
                credit: (artist: String?, copyright: String?) = (nil, nil), folders: ShareFolders = ShareFolders(),
                presenter: any SharePresenting) {
        self.items = items
        self.settings = settings
        self.service = service
        self.credit = credit
        self.folders = folders
        self.presenter = presenter
    }

    /// Rendering or waiting for the picker: a second Share… waits for this one.
    public var isBusy: Bool {
        switch phase {
        case .rendering, .picking: true
        default: false
        }
    }

    public var isRendering: Bool {
        if case .rendering = phase { return true }
        return false
    }

    /// "Preparing 2 of 5 photos to share…" while rendering.
    public var progressText: String? {
        guard case .rendering(let done, let total) = phase else { return nil }
        return total == 1 ? String(localized: "Preparing the photo to share…")
            : String(localized: "Preparing \(min(done + 1, total)) of \(total) photos to share…")
    }

    /// 0...1 while rendering.
    public var fraction: Double {
        guard case .rendering(let done, let total) = phase, total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    public func start() {
        guard phase == .idle else { return }
        guard !items.isEmpty else { return fail(String(localized: "Select photos to share.")) }
        let recipe = settings.recipe
        if let problem = service.validate([recipe], defaultFolder: folders.root) { return fail(problem) }
        let folder: URL
        do {
            folder = try folders.make()
        } catch {
            return fail(String(localized: "Couldn't make a temporary folder to share from: \(error.localizedDescription)"))
        }
        self.folder = folder
        phase = .rendering(done: 0, total: items.count)
        let job = ExportJob(items: items, recipes: [recipe], defaultFolder: folder,
                            artist: credit.artist, copyright: credit.copyright)
        let service = service, folders = folders
        let (updates, sink) = AsyncStream.makeStream(of: ExportProgressUpdate.self, bufferingPolicy: .bufferingNewest(1))
        task = Task { [weak self] in
            let pump = Task { [weak self] in
                for await u in updates { self?.progressed(u) }
            }
            defer {
                sink.finish()
                pump.cancel()
            }
            // Earlier shares' folders that are old enough to be done with.
            await Task.detached(priority: .utility) { folders.sweep() }.value
            do {
                let outcome = try await service.export(job) { (u: ExportProgressUpdate) in sink.yield(u) }
                if outcome.cancelled || Task.isCancelled { throw CancellationError() }
                self?.rendered(outcome)
            } catch is CancellationError {
                self?.removeFolder()
                self?.phase = .cancelled
            } catch {
                self?.removeFolder()
                self?.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// Stop rendering (nothing is shared; the folder is removed).
    public func cancel() {
        guard isRendering else { return }
        task?.cancel()
    }

    /// Wait for the render to end (tests).
    func waitUntilRendered() async { await task?.value }

    /// Wait for the delayed removal of a shared folder (tests).
    func waitUntilCleanedUp() async { await cleanup?.value }

    private func progressed(_ u: ExportProgressUpdate) {
        guard isRendering, !u.readingMetadata else { return }
        phase = .rendering(done: min(u.done, u.total), total: u.total)
    }

    private func rendered(_ outcome: ExportOutcome) {
        failures = outcome.failures
        let order = Dictionary(items.map { ($0.photoID, $0.seq) }, uniquingKeysWith: { a, _ in a })
        files = outcome.written.sorted { (order[$0.photoID] ?? 0) < (order[$1.photoID] ?? 0) }.map(\.url)
        guard !files.isEmpty else {
            removeFolder()
            return fail(failures.first.map { String(localized: "Couldn't prepare the photos to share. \($0)") }
                        ?? String(localized: "Couldn't prepare the photos to share."))
        }
        if !failures.isEmpty {
            let n = failures.count
            report(n == 1 ? String(localized: "1 photo couldn't be prepared and isn't shared.")
                   : String(localized: "\(n) photos couldn't be prepared and aren't shared."), true)
        }
        phase = .picking
        presenter.present(files) { [weak self] choice in self?.picked(choice) }
    }

    private func picked(_ choice: ShareChoice) {
        guard phase == .picking else { return }
        switch choice {
        case .chosen(let service):
            phase = .shared(service)
            // The service may still be reading the files: they go after a while (the
            // task keeps this model alive past the next Share… to do it).
            let delay = cleanupDelay
            cleanup = Task {
                try? await Task.sleep(for: delay)
                self.removeFolder()
            }
        case .dismissed:
            removeFolder()
            phase = .dismissed
        case .unavailable:
            removeFolder()
            fail(String(localized: "The share menu couldn't open. Show the Luxtable window and try again."))
        }
    }

    private func removeFolder() {
        guard let folder else { return }
        folders.remove(folder)
        self.folder = nil
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        report(message, true)
    }
}
