import LuxtableFFI
import Foundation

/// Live archiving through lt-archive (`ArchiveManager` in the FFI): rsync to a
/// folder, or uploads to S3-compatible object storage (through `URLSessionArchiveHTTP`,
/// with the keys from the Keychain), in the background.
///
/// Nothing here blocks: the Rust driver thread decides what runs, each run
/// has its own worker thread with a watchdog (a stale NFS mount can't hang
/// the app, the driver, or the other sessions), and `ArchiveManager.status()`
/// only reads what was recorded. This service polls that status once per
/// `tick` while someone listens, applies settings changes it sees there, and
/// tells the manager when volumes mount or unmount (so an offline target is
/// re-checked at once instead of on its backoff).
public final class RustArchiveService: ArchiveService, @unchecked Sendable {
    public typealias SettingsProvider = @Sendable () async -> ArchiveSettingsSnapshot
    public typealias HandleLookup = @Sendable (SessionInfo) async -> SessionHandle?

    let manager: ArchiveManager?
    private let startError: String?
    private let settings: SettingsProvider
    private let handles: HandleLookup
    private let lockDir: String?
    private let tick: Duration
    private let debounceSeconds: UInt64
    private let lock = NSLock()
    private var applied: ArchiveSettingsSnapshot
    private let rsyncPath: String?
    private var continuations: [UUID: AsyncStream<ArchiveStatus>.Continuation] = [:]
    private var loop: Task<Void, Never>?
    private var current: ArchiveStatus
    private var observers: [NSObjectProtocol] = []
    /// Why the last settings change was not (fully) applied; shown as a failed status until a retry works.
    private var configError: String?
    /// Object storage: the app's HTTP and the Keychain keys (the last ones handed to the manager).
    private let http: any ArchiveHttp
    private let objectKeys: ArchiveObjectKeys
    private var appliedKeys: ObjectCredentials??

    /// `initial` configures the manager right away (the app passes its settings).
    public init(initial: ArchiveSettingsSnapshot, settings: @escaping SettingsProvider, handles: @escaping HandleLookup,
                lockDir: String? = nil,
                tick: Duration = .seconds(1), debounceSeconds: UInt64 = 60, rsyncPath: String? = nil,
                watchVolumes: Bool = true, plugins: PluginHost? = nil,
                http: any ArchiveHttp = URLSessionArchiveHTTP(), objectKeys: ArchiveObjectKeys = .shared) {
        self.http = http
        self.objectKeys = objectKeys
        self.settings = settings
        self.handles = handles
        self.lockDir = lockDir
        self.tick = tick
        self.debounceSeconds = debounceSeconds
        self.rsyncPath = rsyncPath
        applied = initial
        do {
            manager = try ArchiveManager(config: Self.config(initial, lockDir: lockDir, debounce: debounceSeconds,
                                                             rsyncPath: rsyncPath))
            startError = nil
        } catch {
            manager = nil
            startError = "\(error)"
        }
        current = ArchiveStatus(state: .unavailable(initial.isActive ? String(localized: "Checking the archive…") : ArchiveDisplay.offText(initial)),
                                target: initial.target, lastSuccess: nil)
        // Settings ▸ Plugins: no run or Immich step while its feature is off.
        // (Set before any session is registered, so nothing is due before it.)
        if let plugins, let manager { Self.attempt("plug-in gate") { try manager.setPluginHost(host: plugins) } }
        applyKeys(objectStorage: initial.objectStore != nil)
        if watchVolumes, let manager {
            let center = PlatformWorkspace.notificationCenter
            observers = [PlatformWorkspace.didMount, PlatformWorkspace.didUnmount].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    // Off the main thread: the notification is delivered where the workspace posts it.
                    DispatchQueue.global(qos: .utility).async { Self.attempt("volume change") { _ = try manager.volumesChanged() } }
                }
            }
        }
    }

    deinit {
        loop?.cancel()
        for o in observers { PlatformWorkspace.notificationCenter.removeObserver(o) }
    }

    /// Single-flight lock files per target (`<AppPaths.support>/locks`).
    public static var defaultLockDir: String { AppPaths.support.appendingPathComponent("locks").path }

    /// `rsyncPath`: a specific rsync binary (tests run both); `nil` detects one.
    static func config(_ s: ArchiveSettingsSnapshot, lockDir: String?, debounce: UInt64, rsyncPath: String? = nil) -> ArchiveConfig {
        ArchiveConfig(enabled: s.isActive, target: s.target, intervalSecs: UInt64(max(1, s.intervalMinutes)) * 60,
                      debounceSecs: debounce, lockDir: lockDir, checkTimeoutMs: 2000, rsyncPath: rsyncPath,
                      archiveRejected: s.archiveRejected, targetVolume: s.targetVolume,
                      objectStore: s.objectStore)
    }

    /// Hand the Keychain keys to the manager when they changed (the read is cached:
    /// `ArchiveObjectKeys` touches the Keychain only after a save). A folder archive
    /// never reads them, so it never asks for Keychain access.
    private func applyKeys(objectStorage: Bool) {
        guard let manager, objectStorage else { return }
        let keys = objectKeys.credentials
        let due = lock.withLock { () -> Bool in
            if case .some(let applied) = appliedKeys, applied == keys { return false }
            return true
        }
        guard due else { return }
        if Self.attempt("object storage keys", { try manager.setObjectStore(http: http, credentials: keys) }) {
            lock.withLock { appliedKeys = .some(keys) }
        }
    }

    /// Runs `body`, logging (not hiding) a failure of a fire-and-forget manager call.
    @discardableResult
    static func attempt(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            AppLog.archive.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .private(mask: .hash))")
            return false
        }
    }

    static let settingsErrorPrefix = String(localized: "Archive settings not applied")

    /// Applies the parts of `new` that differ from `old`. A part that throws is not recorded as
    /// applied (so the next tick retries it) and is reported in `error`.
    static func applyAll(from old: ArchiveSettingsSnapshot, to new: ArchiveSettingsSnapshot,
                         setConfig: (ArchiveSettingsSnapshot) throws -> Void) -> (applied: ArchiveSettingsSnapshot, error: String?) {
        var applied = old
        var failures: [String] = []
        let archiveChanged = old.enabled != new.enabled || old.target != new.target || old.intervalMinutes != new.intervalMinutes
            || old.archiveRejected != new.archiveRejected
            || old.targetVolume != new.targetVolume || old.objectStore != new.objectStore
        if archiveChanged {
            do {
                try setConfig(new)
                applied.enabled = new.enabled
                applied.target = new.target
                applied.intervalMinutes = new.intervalMinutes
                applied.archiveRejected = new.archiveRejected
                applied.targetVolume = new.targetVolume
                applied.objectStore = new.objectStore
            } catch {
                failures.append(String(localized: "archive target (\(String(describing: error)))"))
            }
        }
        let error = failures.isEmpty ? nil : settingsErrorPrefix + ": " + failures.joined(separator: "; ")
        return (applied, error)
    }

    public var status: ArchiveStatus { lock.withLock { current } }

    public func statusUpdates() -> AsyncStream<ArchiveStatus> {
        let id = UUID()
        let (stream, cont) = AsyncStream<ArchiveStatus>.makeStream()
        lock.withLock {
            continuations[id] = cont
            cont.yield(current)
            if loop == nil {
                let tick = tick
                loop = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refresh()
                        try? await Task.sleep(for: tick)
                    }
                }
            }
        }
        cont.onTermination = { [weak self] _ in
            self?.lock.withLock {
                _ = self?.continuations.removeValue(forKey: id)
                if self?.continuations.isEmpty == true {
                    self?.loop?.cancel()
                    self?.loop = nil
                }
            }
        }
        return stream
    }

    /// Apply changed settings, then publish the manager's status. Only a
    /// real change reaches the manager (which keeps failure state across it).
    public func refresh() async {
        let s = await settings()
        applyKeys(objectStorage: s.objectStore != nil)
        let old = lock.withLock { applied }
        if old != s {
            let result = Self.applyAll(from: old, to: s, setConfig: { new in
                try manager?.setConfig(config: Self.config(new, lockDir: lockDir, debounce: debounceSeconds, rsyncPath: rsyncPath))
            })
            let changed = lock.withLock { () -> Bool in
                let changed = configError != result.error
                applied = result.applied
                configError = result.error
                return changed
            }
            // Once per distinct failure, not on every retry tick.
            if changed, let e = result.error { AppLog.archive.error("\(e, privacy: .private(mask: .hash))") }
        }
        publish(snapshot())
    }

    /// The current status from the manager (never touches the file system).
    public func snapshot() -> ArchiveStatus {
        let s = lock.withLock { applied }
        guard let manager else {
            return ArchiveStatus(state: .failed(String(localized: "Archiving could not start: \(startError ?? String(localized: "unknown error"))")),
                                 target: s.target, lastSuccess: nil)
        }
        guard let o = try? manager.status() else { return lock.withLock { current } }
        let status = Self.status(o, settings: s)
        guard let error = lock.withLock({ configError }) else { return status }
        return ArchiveStatus(state: .failed(error), target: status.target, lastSuccess: status.lastSuccess, detail: status.detail)
    }

    public func syncNow() async {
        Self.attempt("sync now") { _ = try manager?.syncNow() }
        publish(snapshot())
    }

    public func volumesChanged() async {
        Self.attempt("volume change") { _ = try manager?.volumesChanged() }
    }

    public func sessionOpened(_ session: SessionInfo) async {
        guard let manager, let h = await handles(session) else { return }
        Self.attempt("register session") { _ = try manager.registerSession(session: h) }
    }

    public func sessionClosed(_ session: SessionInfo) async {
        guard let manager, let h = await handles(session) else { return }
        Self.attempt("session close") { _ = try manager.sessionClosed(session: h) }
    }

    public func noteChanges(_ n: Int, in session: SessionInfo) async {
        guard n > 0, let manager, let h = await handles(session) else { return }
        Self.attempt("note changes") { _ = try manager.noteChanges(session: h, n: UInt64(n)) }
    }

    /// Import hook: archive the session now.
    public func afterImport(session: SessionInfo, files: Int) async {
        guard let manager, let h = await handles(session) else { return }
        Self.attempt("archive after import") { _ = try manager.afterImport(session: h, files: UInt64(max(0, files))) }
        publish(snapshot())
    }

    public func shutdown() async { await stop() }

    /// Stop the loop and the manager (up to 2 s); whether everything stopped in time.
    @discardableResult
    func stop() async -> Bool {
        let t = lock.withLock { () -> Task<Void, Never>? in
            defer { loop = nil }
            return loop
        }
        t?.cancel()
        guard let manager else { return true }
        return await Task.detached { (try? manager.shutdown(timeoutMs: 2000)) ?? false }.value
    }

    private func publish(_ value: ArchiveStatus) {
        let (conts, previous) = lock.withLock { () -> ([AsyncStream<ArchiveStatus>.Continuation], ArchiveStatus.State) in
            let previous = current.state
            current = value
            return (Array(continuations.values), previous)
        }
        Self.log(value.state, previous: previous, target: value.target)
        for c in conts { c.yield(value) }
    }

    /// One unified-log line per archive state change (`AppLog.archive`): a run starting,
    /// its result, and failures. Progress ticks of a running sync aren't changes.
    static func log(_ state: ArchiveStatus.State, previous: ArchiveStatus.State, target: String) {
        if case .syncing = state, case .syncing = previous { return }
        guard state != previous else { return }
        switch state {
        case .syncing: AppLog.archive.notice("archive run to \(target, privacy: .private(mask: .hash)) started")
        case .idle: AppLog.archive.notice("archive to \(target, privacy: .private(mask: .hash)) up to date")
        case .failed(let why): AppLog.archive.error("archive to \(target, privacy: .private(mask: .hash)) failed: \(why, privacy: .private(mask: .hash))")
        case .problems(let n): AppLog.archive.error("archive to \(target, privacy: .private(mask: .hash)) left \(n) items out")
        case .offline: AppLog.archive.notice("archive target \(target, privacy: .private(mask: .hash)) offline")
        case .behind, .notArchived, .unavailable: break
        }
    }

    // MARK: - Mapping (pure)

    static func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// Badge state and popover detail from the manager's overview.
    public static func status(_ o: ArchiveOverview, settings s: ArchiveSettingsSnapshot) -> ArchiveStatus {
        let sessions = o.sessions.map { x in
            ArchiveDetail.Session(name: x.name, source: x.source, notArchivable: x.notArchivable,
                                  lastSuccess: date(x.lastSuccessMs), lastError: x.lastError, pending: Int(x.pendingChanges),
                                  behindSince: date(x.behindSinceMs), running: x.running,
                                  fraction: x.percent.map { Double($0) / 100 }, bytesPerSecond: x.bytesPerSec,
                                  retryIn: x.retryInMs.map { .milliseconds(Int64($0)) },
                                  problems: x.problems, notResponding: x.notResponding, archiveFolder: x.archiveFolder,
                                  errorDetail: x.lastErrorDetail,
                                  originals: Int(x.originals), rejectsExcluded: Int(x.rejectsExcluded))
        }
        let runs = o.runs.map { r in
            ArchiveDetail.Run(session: r.session, trigger: r.trigger, outcome: r.outcome, message: r.message,
                              started: date(r.startedMs) ?? .distantPast, duration: .milliseconds(Int64(r.durationMs)),
                              warnings: r.warnings, problems: r.problems, detail: r.detail)
        }
        let detail = ArchiveDetail(targetReason: o.target.available ? nil : o.target.reason,
                                   rsync: o.rsync ?? o.rsyncError.map { "rsync: \($0)" },
                                   sessions: sessions, runs: runs)
        let archivable = sessions.filter { $0.notArchivable == nil }
        let pending = archivable.reduce(0) { $0 + $1.pending }
        let problems = archivable.reduce(0) { $0 + $1.problems.count }
        let state: ArchiveStatus.State
        if !o.enabled {
            state = .unavailable(ArchiveDisplay.offText(s))
        } else if !o.target.available, o.target.reason == "checking…" {
            // Before the first target check answers, never claim "up to date".
            state = .unavailable(String(localized: "Checking the archive…"))
        } else if let running = archivable.first(where: { $0.running && !$0.notResponding }) {
            state = .syncing(fraction: running.fraction ?? -1)
        } else if !o.target.available {
            state = .offline
        } else if archivable.contains(where: \.notResponding) {
            state = .failed(String(localized: "the archive volume is not responding"))
        } else if problems > 0 {
            state = .problems(count: problems)
        } else if let failing = archivable.first(where: { $0.lastError != nil }), let e = failing.lastError {
            state = .failed(e)
        } else if pending > 0 {
            state = .behind(files: pending)
        } else if archivable.contains(where: { $0.lastSuccess == nil }) {
            // "up to date" only when every session's last run succeeded
            // (this launch or, as saved, an earlier one) with nothing left since.
            state = .notArchived
        } else {
            state = .idle
        }
        return ArchiveStatus(state: state, target: o.target.path, lastSuccess: archivable.compactMap(\.lastSuccess).max(),
                             detail: detail)
    }
}
