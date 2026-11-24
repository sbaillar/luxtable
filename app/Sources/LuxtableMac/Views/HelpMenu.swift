import AppKit
import LuxtableCore
import UniformTypeIdentifiers

/// The Help menu's own items: the user guide (the PDF in the app, so it opens offline
/// and matches this version), the page for reporting a problem, and the diagnostic report.
@MainActor
enum HelpMenu {
    /// Where the guide is when the app has none inside (a development run).
    static let onlineGuide = URL(string: "https://github.com/sbaillar/luxtable/blob/main/docs/user-guide/README.md")!
    static let newIssue = URL(string: "https://github.com/sbaillar/luxtable/issues/new?template=bug.yml")!

    static func guide(in bundle: Bundle = .main) -> URL {
        bundle.url(forResource: "Luxtable-User-Guide", withExtension: "pdf") ?? onlineGuide
    }

    static func openGuide() {
        NSWorkspace.shared.open(guide())
    }

    static func reportProblem() {
        NSWorkspace.shared.open(newIssue)
    }

    /// Ask where, write the report, and show it in Finder (to read, then attach).
    static func saveReport(model: AppModel) {
        let report = model.diagnosticReport()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.fileName
        panel.allowedContentTypes = [.plainText]
        panel.message = String(localized: "The report lists your Mac, the Luxtable version, what is open (counts only) and this run’s log. It has no photos, file names or folders.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.show(error)
        }
    }
}
