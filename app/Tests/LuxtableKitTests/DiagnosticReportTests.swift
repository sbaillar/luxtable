import Foundation
import OSLog
@testable import LuxtableCore
@testable import LuxtableMac
import Testing

/// Help ▸ Save Diagnostic Report…: enough to diagnose a problem, nothing that names the user's work.
@MainActor
struct DiagnosticReportTests {
    static let mac = SystemFacts(version: "0.5.9", build: "106", core: "0.5.9", os: "Version 26.1", model: "Mac16,10",
                                 chip: "Apple M4", memoryGB: 32, gpu: "Apple M4", language: "en-US")

    @Test func theReportSaysWhatIsOpenWithoutNamingIt() async throws {
        let m = makeModel()
        await m.start()
        let session = try #require(m.currentSession)
        AppLog.session.notice("diagnostic report test line")
        let r = m.diagnosticReport(system: Self.mac, now: Date(timeIntervalSince1970: 1_795_000_000), log: ["21:41:07 import notice  done"])
        let text = r.text
        #expect(text.contains("Luxtable  0.5.9 (106)"))
        #expect(text.contains("Mac16,10, Apple M4") && text.contains("32 GB"))
        #expect(text.contains("open, \(m.photos.count) photos, 0 videos"))
        #expect(text.contains("archive ") && text.contains("google-photos "))
        #expect(text.contains("  21:41:07 import notice  done"))
        #expect(!text.contains(session.name) && !text.contains(session.url.path), "the session is counted, never named")
        let photo = try #require(m.focusedPhoto)
        #expect(!text.contains(photo.filename), "nor is a photo")
        #expect(r.fileName.hasPrefix("Luxtable Diagnostic Report 20") && r.fileName.hasSuffix(".txt"))
    }

    @Test func nothingOpenAndNothingLoggedStillMakeAReport() {
        let r = DiagnosticReport(date: Date(), sections: [Self.mac.section, .init("Empty", [])], log: [])
        #expect(r.text.contains("(nothing logged)"))
        #expect(!r.text.contains("Empty"), "a section with nothing in it is left out")
        var bare = Self.mac
        bare.build = ""
        #expect(bare.section.rows[0].value == "0.5.9")
    }

    @Test func statesAreInPlainWords() {
        #expect(AppModel.words(ArchiveStatus.State.failed("rsync: /Volumes/Photos: no route")) == "last run failed")
        #expect(AppModel.words(ArchiveStatus.State.behind(files: 3)) == "behind by 3")
        #expect(AppModel.words(ArchiveStatus.State.syncing(fraction: 0.5)) == "syncing")
        #expect(AppModel.words(ArchiveStatus.State.problems(count: 2)) == "archived with 2 problems")
        #expect([ArchiveStatus.State.idle, .offline, .notArchived, .unavailable("x")].map(AppModel.words)
            == ["up to date", "offline", "not archived yet", "not available"])
        #expect(AppModel.words(RawlerHelper.State.installed("0.7.1")) == "installed (rawler 0.7.1)")
        #expect([RawlerHelper.State.notInstalled, .downloading(0.3), .installed(""), .failed("x")].map(AppModel.words)
            == ["not installed", "downloading", "installed", "failed"])
        #expect(AppModel.words(SaveCoordinator.State.failed("disk full", pending: 2)) == "2 not saved (failed)")
        #expect(AppModel.words(SaveCoordinator.State.dropped("closed", count: 1)) == "1 not saved (dropped)")
        #expect([SaveCoordinator.State.saved, .pending(1), .saving].map(AppModel.words) == ["saved", "saving", "saving"])
    }

    @Test func thisMacAndThisRunsLogAreRead() {
        let mac = SystemFacts.current()
        #expect(!mac.os.isEmpty && !mac.model.isEmpty && mac.memoryGB > 0)
        #expect(SystemFacts.sysctl("no.such.name").isEmpty)
        AppLog.session.notice("diagnostic report marker \(4242, privacy: .public)")
        let lines = AppLog.recentLines()
        #expect(lines.contains { $0.contains("session notice") && $0.contains("diagnostic report marker 4242") })
        #expect(AppLog.recentLines(limit: 1).count <= 1)
        #expect([OSLogEntryLog.Level.debug, .info, .notice, .error, .fault, .undefined].map(AppLog.level) == ["debug", "info", "notice", "error", "fault", "other"])
    }

    @Test func theGuideIsTheOneInTheAppElseOnline() {
        #expect(HelpMenu.guide(in: Bundle(for: BundleProbe.self)) == HelpMenu.onlineGuide, "a bundle without the PDF")
        #expect(HelpMenu.newIssue.absoluteString.hasSuffix("issues/new?template=bug.yml"))
    }
}

private final class BundleProbe {}
