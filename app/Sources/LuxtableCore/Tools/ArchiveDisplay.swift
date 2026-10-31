import Foundation

/// Human text and SF Symbol for an archive state (shared by panel and toolbar badge).
public enum ArchiveDisplay {
    public static func title(_ s: ArchiveStatus.State) -> String {
        switch s {
        case .idle: String(localized: "Archive up to date")
        case .syncing(let f): f < 0 ? String(localized: "Syncing…") : String(localized: "Syncing… \(Safe.clampedInt((f * 100))) %")
        case .behind(let n): n == 1 ? String(localized: "Behind by \(n) file") : String(localized: "Behind by \(n) files")
        case .problems: String(localized: "Archived with problems")
        case .offline: String(localized: "Archive offline")
        case .failed(let why): why.hasPrefix(RustArchiveService.settingsErrorPrefix) ? String(localized: "Archive settings not applied") : String(localized: "Last sync failed")
        case .notArchived: String(localized: "Not archived yet")
        case .unavailable(let m): m
        }
    }

    public static func symbol(_ s: ArchiveStatus.State) -> String {
        switch s {
        case .idle: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .behind: "icloud.and.arrow.up"
        case .problems: "exclamationmark.icloud"
        case .offline: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        case .notArchived: "icloud.and.arrow.up"
        case .unavailable: "icloud.slash"
        }
    }

    /// Toolbar badge text.
    public static func short(_ s: ArchiveStatus.State) -> String {
        switch s {
        case .idle: String(localized: "Archived")
        case .syncing(let f): f < 0 ? String(localized: "Syncing") : "\(Int(f * 100))%"
        case .behind(let n): String(localized: "\(n) behind")
        case .problems: String(localized: "Problems")
        case .offline: String(localized: "Offline")
        case .failed: String(localized: "Error")
        case .notArchived: String(localized: "Not archived")
        case .unavailable: String(localized: "Archive off")
        }
    }

    /// Popover status line.
    public static func long(_ s: ArchiveStatus.State) -> String {
        switch s {
        case .idle: String(localized: "Up to date")
        case .syncing(let f): f < 0 ? String(localized: "Syncing") : String(localized: "Syncing, \(Int(f * 100))%")
        case .behind(let n): n == 1 ? String(localized: "\(n) file waiting") : String(localized: "\(n) files waiting")
        case .problems(let n): n == 1
            ? String(localized: "\(n) item is not in the archive. Retrying.")
            : String(localized: "\(n) items are not in the archive. Retrying.")
        case .offline: ArchiveDisplay.offlineText
        case .failed(let m): m
        case .notArchived: String(localized: "A session hasn't been archived yet. It is archived with its next change or Sync Now.")
        case .unavailable(let m): m
        }
    }

    /// Offline covers a share that isn't mounted and a different disk at its path (N3).
    public static let offlineText = String(localized: "Target not available (not mounted, or a different disk is at that path). Changes are queued.")

    /// N2: said with the badge (tooltip) and the popover title when the archive
    /// leaves rejected photos out, e.g. "3 rejects excluded".
    public static func exclusionNote(_ status: ArchiveStatus, settings: ArchiveSettingsSnapshot) -> String? {
        guard settings.isActive, !settings.archiveRejected else { return nil }
        let n = status.detail?.sessions.reduce(0) { $0 + $1.rejectsExcluded } ?? 0
        if n == 1 { return String(localized: "\(n) reject excluded") }
        return n > 0 ? String(localized: "\(n) rejects excluded") : String(localized: "Rejected photos excluded")
    }

    /// The badge tooltip: the explanation, plus what is left out.
    public static func badgeHelp(_ status: ArchiveStatus, settings: ArchiveSettingsSnapshot) -> String {
        [explanation(status.state), exclusionNote(status, settings: settings)].compactMap { $0 }.joined(separator: "\n")
    }

    /// Popover explanation.
    public static func explanation(_ s: ArchiveStatus.State) -> String {
        if case .unavailable = s {
            return String(localized: "Set an archive target and switch archiving on in Settings › Archive. Nothing is copied until then.")
        }
        return String(localized: "rsync copies sessions to the archive in the background. It never deletes from the archive; replaced files are kept in .lt-archive-trash.")
    }

    /// Why archiving is off (badge popover and state).
    public static func offText(_ s: ArchiveSettingsSnapshot) -> String {
        if !s.hasTarget { return s.objectStore == nil ? String(localized: "Archive off: no target set") : String(localized: "Archive off: no bucket set") }
        return s.enabled ? String(localized: "Archive off") : String(localized: "Archive switched off")
    }

    // MARK: Popover detail

    /// One session line, e.g. "3 files waiting · last sync 2 min ago".
    public static func sessionLine(_ x: ArchiveDetail.Session, now: Date = Date()) -> String {
        if let why = x.notArchivable { return String(localized: "Not archived: \(why)") }
        if x.notResponding { return String(localized: "Not responding: the archive volume stopped answering. Retried when it's back.") }
        if !x.problems.isEmpty {
            let n = x.problems.count
            var s = n == 1 ? String(localized: "\(n) item not archived") : String(localized: "\(n) items not archived")
            if let r = x.retryIn { s += " · " + String(localized: "retry in \(Formatters.duration(Double(r.components.seconds)))") }
            if let d = x.lastSuccess { s += " · " + String(localized: "last full sync \(Formatters.relative(d, now: now))") }
            return s
        }
        if x.running {
            let pct = x.fraction.map { " \(Safe.clampedInt(($0 * 100))) %" } ?? ""
            let rate = x.bytesPerSecond.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/s" } ?? ""
            return String(localized: "Syncing") + pct + rate
        }
        var parts: [String] = []
        if let e = x.lastError {
            parts.append(String(localized: "Last sync failed: \(e)"))
            if let r = x.retryIn { parts.append(String(localized: "retry in \(Formatters.duration(Double(r.components.seconds)))")) }
            if x.lastSuccess == nil { parts.append(String(localized: "never archived")) }
        } else if x.pending > 0 {
            parts.append(x.pending == 1 ? String(localized: "\(x.pending) change waiting") : String(localized: "\(x.pending) changes waiting"))
        } else if x.lastSuccess != nil {
            parts.append(String(localized: "Up to date"))
            if let counts = archivedCounts(x) { parts.append(counts) }
        } else {
            parts.append(String(localized: "Not archived yet"))
        }
        if let d = x.lastSuccess { parts.append(String(localized: "last sync \(Formatters.relative(d, now: now))")) }
        return parts.joined(separator: " · ")
    }

    /// N2: what the last run put in the archive, e.g. "8 of 8 archived" or
    /// "5 archived, 3 rejects excluded" (`nil` before the first counted run).
    public static func archivedCounts(_ x: ArchiveDetail.Session) -> String? {
        guard x.originals > 0 else { return nil }
        let archived = x.originals - x.rejectsExcluded
        if x.rejectsExcluded == 0 { return String(localized: "\(archived) of \(x.originals) archived") }
        return x.rejectsExcluded == 1
            ? String(localized: "\(archived) archived, \(x.rejectsExcluded) reject excluded")
            : String(localized: "\(archived) archived, \(x.rejectsExcluded) rejects excluded")
    }

    /// One run line, e.g. "Trip · on demand · succeeded in 1.2 s".
    public static func runLine(_ r: ArchiveDetail.Run) -> String {
        let secs = Double(r.duration.components.seconds) + Double(r.duration.components.attoseconds) / 1e18
        let took = secs < 10 ? String(format: "%.1f s", secs) : "\(Safe.clampedInt(secs)) s"
        var s = "\(r.session) · \(r.trigger) · \(r.outcome)"
        if ["succeeded", "failed", "incomplete"].contains(r.outcome) { s += " " + String(localized: "in \(took)") }
        if !r.problems.isEmpty { s += ": " + String(localized: "\(r.problems.count) not archived") }
        if let m = r.message { s += ": \(m)" }
        if !r.warnings.isEmpty { s += r.warnings.count == 1
            ? " (" + String(localized: "\(r.warnings.count) warning") + ")"
            : " (" + String(localized: "\(r.warnings.count) warnings") + ")" }
        return s
    }

    /// Whether a run line shows as a problem (red) in the popover.
    public static func isProblem(_ r: ArchiveDetail.Run) -> Bool {
        r.outcome != "succeeded" && r.outcome != "cancelled" && r.outcome != "busy"
    }

    public static func canSyncNow(_ s: ArchiveStatus.State) -> Bool {
        // Offline: "Sync Now" still queues it for when the target is back.
        switch s {
        case .syncing, .unavailable: false
        default: true
        }
    }

    public static func accessibilityLabel(_ status: ArchiveStatus) -> String {
        String(localized: "Archive: \(long(status.state))")
    }
}
