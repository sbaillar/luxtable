import Foundation
import Metal
import OSLog

/// Help ▸ Save Diagnostic Report…: what a bug report needs (the app and the Mac, what is
/// open, what is switched on, and this run's log) as text the user can read before sharing.
///
/// Nothing in it names the user's work: a session is described by counts, a photo by its
/// camera and file type, and the log masks paths, file names and hosts (`AppLog`). The text
/// is English whatever the app's language: it is read by whoever fixes the problem.
public struct DiagnosticReport: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Section: Sendable, Equatable {
        public var title: String
        public var rows: [Row]

        public init(_ title: String, _ rows: [Row]) {
            self.title = title
            self.rows = rows
        }
    }

    public var date: Date
    public var sections: [Section]
    /// This run's log lines, oldest first (`AppLog.recentLines`).
    public var log: [String]

    public init(date: Date, sections: [Section], log: [String]) {
        self.date = date
        self.sections = sections
        self.log = log
    }

    /// The file's suggested name: "Luxtable Diagnostic Report 2026-11-23 2141.txt".
    public var fileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Luxtable Diagnostic Report \(f.string(from: date)).txt"
    }

    public var text: String {
        var out = ["Luxtable diagnostic report", ISO8601DateFormatter().string(from: date), ""]
        for s in sections where !s.rows.isEmpty {
            out.append(s.title)
            let width = s.rows.map(\.label.count).max() ?? 0
            for r in s.rows {
                out.append("  " + r.label.padding(toLength: width + 2, withPad: " ", startingAt: 0) + r.value)
            }
            out.append("")
        }
        out.append("Log since Luxtable was opened (paths, file names and hosts are masked)")
        out.append(contentsOf: log.isEmpty ? ["  (nothing logged)"] : log.map { "  " + $0 })
        return out.joined(separator: "\n") + "\n"
    }
}

/// The app and the Mac it runs on.
public struct SystemFacts: Sendable, Equatable {
    public var version: String
    public var build: String
    public var core: String
    public var os: String
    public var model: String
    public var chip: String
    public var memoryGB: Int
    public var gpu: String
    public var language: String

    public init(version: String, build: String, core: String, os: String, model: String, chip: String,
                memoryGB: Int, gpu: String, language: String) {
        self.version = version
        self.build = build
        self.core = core
        self.os = os
        self.model = model
        self.chip = chip
        self.memoryGB = memoryGB
        self.gpu = gpu
        self.language = language
    }

    public static func current(bundle: Bundle = .main) -> SystemFacts {
        let info = bundle.infoDictionary ?? [:]
        return SystemFacts(version: info["CFBundleShortVersionString"] as? String ?? "development build",
                           build: info["CFBundleVersion"] as? String ?? "",
                           core: RustCore.version,
                           os: ProcessInfo.processInfo.operatingSystemVersionString,
                           model: sysctl("hw.model"),
                           chip: sysctl("machdep.cpu.brand_string"),
                           memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded()),
                           gpu: MTLCreateSystemDefaultDevice()?.name ?? "none",
                           language: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    var section: DiagnosticReport.Section {
        .init("App and Mac", [
            .init("Luxtable", build.isEmpty ? version : "\(version) (\(build))"),
            .init("Core", core),
            .init("macOS", os),
            .init("Mac", [model, chip].filter { !$0.isEmpty }.joined(separator: ", ")),
            .init("Memory", "\(memoryGB) GB"),
            .init("Graphics", gpu),
            .init("Language", language),
        ])
    }
}

extension AppModel {
    /// The report for what is open now. `log` is this run's log (injected by tests).
    public func diagnosticReport(system: SystemFacts = .current(), now: Date = Date(),
                                 log: [String] = AppLog.recentLines()) -> DiagnosticReport {
        var session: [DiagnosticReport.Row] = [.init("Mode", mode == .demo ? "demo (sample data)" : "live")]
        if currentSession == nil {
            session.append(.init("Session", "none open"))
        } else {
            let videos = photos.count(where: \.isVideo)
            session.append(.init("Session", "open, \(photos.count - videos) photos, \(videos) videos, \(visibleIDs.count) shown"))
            session.append(.init("Selected", "\(selection.count)"))
            if let p = focusedPhoto {
                let type = (p.filename as NSString).pathExtension.uppercased()
                session.append(.init("Current photo", [p.meta.camera, type, "\(p.meta.pixelWidth)×\(p.meta.pixelHeight)"]
                        .filter { !$0.isEmpty }.joined(separator: ", ")))
            }
        }
        session.append(.init("Changes", Self.words(saver.state)))
        let features = NativeFeature.allCases.map { "\($0.rawValue) \(self.features.isOn($0) ? "on" : "off")" }
        let setup: [DiagnosticReport.Row] = [
            .init("Integrations", features.joined(separator: ", ")),
            .init("Archive", Self.words(archiveStatus.state)),
            .init("RAW helper", Self.words(RawlerHelper.shared.state)),
            .init("Layout and keys", "\(settings.layoutPreset.rawValue), \(settings.keyPreset.rawValue)"),
            .init("Simple mode", settings.simpleMode ? "on" : "off"),
        ]
        return DiagnosticReport(date: now, sections: [system.section, .init("What is open", session), .init("Setup", setup)],
                                log: log)
    }

    // States in words of their own: the app's titles are localized, and a failure's
    // message may name a folder or a server.
    static func words(_ s: ArchiveStatus.State) -> String {
        switch s {
        case .idle: "up to date"
        case .syncing: "syncing"
        case .behind(let n): "behind by \(n)"
        case .problems(let n): "archived with \(n) problems"
        case .offline: "offline"
        case .failed: "last run failed"
        case .notArchived: "not archived yet"
        case .unavailable: "not available"
        }
    }

    static func words(_ s: RawlerHelper.State) -> String {
        switch s {
        case .notInstalled: "not installed"
        case .downloading: "downloading"
        case .installed(let v): v.isEmpty ? "installed" : "installed (rawler \(v))"
        case .failed: "failed"
        }
    }

    static func words(_ s: SaveCoordinator.State) -> String {
        switch s {
        case .saved: "saved"
        case .pending, .saving: "saving"
        case .failed(_, let pending): "\(pending) not saved (failed)"
        case .dropped(_, let count): "\(count) not saved (dropped)"
        }
    }
}

extension AppLog {
    /// This process's log lines for Luxtable's subsystem, oldest first, at most the last
    /// `limit`: "21:41:07 import notice  import finished: 63 files". Private values come
    /// back masked, as they were logged. Empty when the log can't be read.
    public static func recentLines(limit: Int = 800) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", subsystem)) else { return [] }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\(time.string(from: $0.date)) \($0.category) \(level($0.level))  \($0.composedMessage)"
        }
        return Array(lines.suffix(limit))
    }

    static func level(_ l: OSLogEntryLog.Level) -> String {
        switch l {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "other"
        }
    }
}
