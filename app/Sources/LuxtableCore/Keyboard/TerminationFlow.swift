import Foundation

/// Quit handling: what to ask, and what each answer means. Pure; the app
/// delegate only shows the alert and replies to AppKit.
public enum TerminationFlow {
    public enum Choice: String, Sendable, CaseIterable {
        case retry, quitAnyway, cancel, stopImportAndQuit, stopExportAndQuit

        public var title: String {
            switch self {
            case .retry: String(localized: "Try Again")
            case .quitAnyway: String(localized: "Quit Anyway")
            case .cancel: String(localized: "Cancel")
            case .stopImportAndQuit: String(localized: "Stop Import and Quit")
            case .stopExportAndQuit: String(localized: "Stop Export and Quit")
            }
        }
    }

    public struct Alert: Equatable, Sendable {
        public var title: String
        public var message: String
        /// In button order; the first is the default (⏎).
        public var choices: [Choice]
        public var isCritical: Bool
    }

    /// What AppKit gets told.
    public enum Reply: Equatable, Sendable {
        case terminate
        case cancel
        /// Flush again, then decide again.
        case retry
    }

    /// `nil` = quit without asking.
    public static func alert(for decision: AppModel.TerminationDecision) -> Alert? {
        switch decision {
        case .ok:
            return nil
        case .failed(let message, let pending):
            return Alert(title: pending == 1 ? String(localized: "1 change couldn’t be saved") : String(localized: "\(pending) changes couldn’t be saved"),
                         message: pending == 1 ? String(localized: "\(message)\n\nIf you quit now, it is lost.")
                             : String(localized: "\(message)\n\nIf you quit now, they are lost."),
                         choices: [.retry, .cancel, .quitAnyway], isCritical: true)
        case .unsavedInMemory(let count):
            return Alert(title: count == 1 ? String(localized: "1 rating and edit will be lost") : String(localized: "\(count) ratings and edits will be lost"),
                         message: String(localized: "This folder is open without a session store: ratings and edits are kept in memory only. Quitting discards them."),
                         choices: [.cancel, .quitAnyway], isCritical: true)
        case .importRunning:
            // The copy stops at its next chunk; its journal resumes it next time.
            return Alert(title: ImportWording.quitImportTitle, message: ImportWording.quitImportMessage,
                         choices: [.cancel, .stopImportAndQuit], isCritical: false)
        case .exportRunning:
            // The batch stops at its next photo; files already written stay.
            return Alert(title: String(localized: "An export is running"),
                         message: String(localized: "Stop it and quit? Photos already exported stay; the rest aren't exported."),
                         choices: [.cancel, .stopExportAndQuit], isCritical: false)
        case .archiveFailed(let message):
            return Alert(title: String(localized: "The last archive run failed"),
                         message: String(localized: "\(message)\n\nYour photos are safe on this Mac, but the archive doesn't have all of them. Luxtable tries again the next time it opens."),
                         choices: [.cancel, .quitAnyway], isCritical: false)
        }
    }

    public static func reply(for choice: Choice) -> Reply {
        switch choice {
        case .retry: .retry
        case .quitAnyway, .stopImportAndQuit, .stopExportAndQuit: .terminate
        case .cancel: .cancel
        }
    }

    /// Run the quit flow: decide, ask if needed, repeat on Retry. `ask` shows the alert.
    @MainActor
    public static func run(decide: () async -> AppModel.TerminationDecision,
                           ask: (Alert) -> Choice) async -> Bool {
        while true {
            let decision = await decide()
            guard let alert = alert(for: decision) else { return true }
            switch reply(for: ask(alert)) {
            case .terminate: return true
            case .cancel: return false
            case .retry: continue
            }
        }
    }
}
