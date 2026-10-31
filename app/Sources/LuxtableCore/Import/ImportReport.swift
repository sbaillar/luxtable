import Foundation

/// Outcome of one import as the *service* reports it. Only a report with
/// `safeToRemove` may ever produce "safe to remove"; only `allVerified` may
/// say the copies were verified. The card is the only other copy until then.
public struct ImportReport: Equatable, Sendable {
    public var filesTotal: Int
    /// Items copied (or already in place from an interrupted run), verified and registered.
    public var filesCopied: Int
    /// Files whose destination hash was re-read and matched the source (BLAKE3 in lt-import).
    public var filesVerified: Int
    public var bytesCopied: Int64
    /// lt-import's `is_complete` for this run's plan.
    public var isComplete: Bool
    /// Something stays only on the card (`cardOnly`, unreadable parts, files
    /// that aren't imported): "Eject Anyway…" needs a confirmation.
    public var ejectNeedsConfirmation: Bool
    public var scanErrors: [ImportIssue]
    public var skippedUnknown: [ImportIssue]
    public var failed: [ImportIssue]
    /// Copied and verified, but the session couldn't add them: not imported
    /// (opening the session or importing again adds them).
    public var registerErrors: [ImportIssue]
    /// Files the library already held (verified by full hash), not copied again.
    public var skippedDuplicates: Int
    public var cancelled: Bool
    /// The card went away mid-import.
    public var sourceLost: String?
    /// The session the files went into.
    public var sessionURL: URL?
    public var sessionName: String?
    /// Media files on the card with no verified copy in the library (from a
    /// fresh scan of the whole card after the run).
    public var cardOnly: [ImportIssue]
    /// Every media file on the card has a verified library copy and nothing
    /// else stays only on the card.
    public var safeToRemove: Bool
    /// Card files whose library copy was damaged and that were imported again.
    public var damagedLibraryCopies: [ImportIssue]
    /// The card the run read.
    public var volumeID: String?

    public init(filesTotal: Int, filesCopied: Int, filesVerified: Int, bytesCopied: Int64, isComplete: Bool? = nil,
                ejectNeedsConfirmation: Bool = false, scanErrors: [ImportIssue] = [], skippedUnknown: [ImportIssue] = [],
                failed: [ImportIssue] = [], registerErrors: [ImportIssue] = [], skippedDuplicates: Int = 0,
                cancelled: Bool = false, sourceLost: String? = nil, sessionURL: URL? = nil, sessionName: String? = nil,
                cardOnly: [ImportIssue] = [], safeToRemove: Bool? = nil, damagedLibraryCopies: [ImportIssue] = [],
                volumeID: String? = nil) {
        self.filesTotal = filesTotal
        self.filesCopied = filesCopied
        self.filesVerified = filesVerified
        self.bytesCopied = bytesCopied
        self.isComplete = isComplete ?? (filesTotal > 0 && filesVerified == filesTotal && filesCopied == filesTotal)
        self.ejectNeedsConfirmation = ejectNeedsConfirmation
        self.scanErrors = scanErrors
        self.skippedUnknown = skippedUnknown
        self.failed = failed
        self.registerErrors = registerErrors
        self.skippedDuplicates = skippedDuplicates
        self.cancelled = cancelled
        self.sourceLost = sourceLost
        self.sessionURL = sessionURL
        self.sessionName = sessionName
        self.cardOnly = cardOnly
        self.safeToRemove = safeToRemove ?? (self.isComplete && !ejectNeedsConfirmation && !cancelled
            && scanErrors.isEmpty && skippedUnknown.isEmpty && failed.isEmpty && registerErrors.isEmpty
            && cardOnly.isEmpty && sourceLost == nil)
        self.damagedLibraryCopies = damagedLibraryCopies
        self.volumeID = volumeID
    }

    public var allVerified: Bool {
        isComplete && !cancelled && filesTotal > 0 && filesVerified == filesTotal && filesCopied == filesTotal
    }

    /// Every file of *this plan* was copied, verified and registered (a stale or
    /// partial report for a different file count never counts).
    public func allVerified(for plan: ImportPlan) -> Bool {
        allVerified && filesTotal == plan.candidates.count && registerErrors.isEmpty
    }
}

/// The card's eject button (H1). Eject is never automatic.
///
/// - `safe`: every media file on the card has a verified library copy and
///   nothing else stays only on it: "Eject Card", no questions.
/// - otherwise "Eject Anyway…": the sheet lists what stays only on the card
///   and asks for a confirmation first.
public struct ImportEjectGate: Equatable, Sendable {
    public var verified: Bool
    /// Something stays only on the card (or nothing was verified).
    public var needsAcknowledgement: Bool
    /// The user confirmed "Eject Anyway".
    public var acknowledged: Bool
    public var canEject: Bool
    public var ejected: Bool

    public init(verified: Bool, needsAcknowledgement: Bool, acknowledged: Bool = false, canEject: Bool,
                ejected: Bool = false) {
        self.verified = verified
        self.needsAcknowledgement = needsAcknowledgement
        self.acknowledged = acknowledged
        self.canEject = canEject
        self.ejected = ejected
    }

    /// The card may be called safe to remove.
    public var safe: Bool { verified && !needsAcknowledgement }
    /// Show the eject button (always, for a local removable volume).
    public var offersEject: Bool { canEject && !ejected }
    /// Pressing it asks first.
    public var requiresConfirmation: Bool { !safe && !acknowledged }
    public var buttonTitle: String { safe ? String(localized: "Eject Card") : String(localized: "Eject Anyway…") }
}

/// Import services that verify copies (lt-import) conform and hand back the
/// report of the last `run`. Services that don't conform (the demo mock) are
/// treated as unverified, always.
public protocol ImportVerifying: ImportService {
    /// The report of `plan`'s run, waiting for it to finish (a stopped run too).
    func report(for plan: ImportPlan) async -> ImportReport?
}

/// Errors a verifying import service reports before copying anything.
public enum ImportRunError: Error, Equatable, LocalizedError {
    /// The card in the reader is not the one that was scanned (C1): scan again.
    case cardChanged
    /// The destination can't hold the import; nothing was created.
    case notEnoughSpace(String)

    public var errorDescription: String? {
        switch self {
        case .cardChanged:
            String(localized: "A different card is in the reader. It was scanned again; check the selection and import.")
        case .notEnoughSpace(let why): why
        }
    }
}

/// What the import UI may say. Pure, so "never claim verified or safe without
/// a report that says so" is enforced by tests rather than by view code.
public enum ImportWording {
    public static let liveUnavailableTitle = String(localized: "Import isn’t available yet")
    public static let liveUnavailableMessage =
        String(localized: "Verified import isn't available in this build. Luxtable never copies from cards without verifying, so it can't lose files. You can browse the card read-only.")

    /// "1 photo", "3 photos", "2 videos", "3 photos and 1 video".
    public static func items(photos: Int, videos: Int) -> String {
        let p = photos == 1 ? String(localized: "1 photo") : String(localized: "\(photos) photos")
        let v = videos == 1 ? String(localized: "1 video") : String(localized: "\(videos) videos")
        switch (photos, videos) {
        case (_, 0): return p
        case (0, _): return v
        default: return String(localized: "\(p) and \(v)")
        }
    }

    /// "1 file", "3 files".
    public static func files(_ k: Int) -> String { k == 1 ? String(localized: "1 file") : String(localized: "\(k) files") }

    public static func doneTitle(_ s: ImportModel.ImportSummary) -> String {
        let what = items(photos: s.files - s.videos, videos: s.videos)
        if !s.verified, s.files > 0, !s.checkedByService { return String(localized: "Copied \(what) (not verified)") }
        if s.files == 0 { return s.skippedDuplicates > 0 ? String(localized: "Everything was already in the library") : String(localized: "Nothing was imported") }
        return String(localized: "Imported \(what)")
    }

    /// Per-file facts: what was verified, what went wrong, never "nothing was
    /// verified" when something was.
    public static func doneDetail(_ s: ImportModel.ImportSummary) -> String {
        let bytes = Formatters.bytes(s.bytes)
        let time = Formatters.duration(s.seconds)
        guard s.checkedByService else {
            return String(localized: "\(bytes) copied into “\(s.sessionName)” in \(time). The copies were not verified, so keep the card.")
        }
        var line = s.files > 0
            ? String(localized: "\(files(s.files)) copied and verified into “\(s.sessionName)” (\(bytes) in \(time)).")
            : String(localized: "Nothing new was copied into “\(s.sessionName)”.")
        var problems: [String] = []
        if !s.registerErrors.isEmpty { problems.append(String(localized: "\(files(s.registerErrors.count)) copied but not added to the session")) }
        if !s.failed.isEmpty { problems.append(String(localized: "\(files(s.failed.count)) failed")) }
        if !s.scanErrors.isEmpty {
            problems.append(s.scanErrors.count == 1 ? String(localized: "1 part of the card unreadable")
                : String(localized: "\(s.scanErrors.count) parts of the card unreadable"))
        }
        if !problems.isEmpty { line += " " + problems.joined(separator: "; ") + "." }
        return line
    }

    /// Line about the card; `nil` when there is nothing to say.
    public static func cardLine(_ s: ImportModel.ImportSummary) -> String? {
        if s.ejected {
            return s.safeToRemove
                ? String(localized: "Card ejected. Every file on it has a verified copy in your library, so it is safe to remove.")
                : String(localized: "Card ejected. Keep it: the files listed above are only on the card.")
        }
        if let err = s.ejectError { return String(localized: "Couldn’t eject the card: \(err)") }
        if !s.checkedByService { return String(localized: "Keep this card: these copies were not verified.") }
        if s.safeToRemove { return String(localized: "Every file on the card has a verified copy in your library. It is safe to remove.") }
        if !s.stayOnCard.isEmpty {
            return s.stayOnCard.count == 1 ? String(localized: "Keep this card: 1 file is only on it.")
                : String(localized: "Keep this card: \(files(s.stayOnCard.count)) are only on it.")
        }
        return String(localized: "Keep this card: not every file on it has a verified copy in your library yet.")
    }

    public static func readyLine(bytes: Int64, destination: String, verifies: Bool, free: Int64? = nil) -> String {
        let space = free.map { String(localized: " · \(Formatters.bytes($0)) free") } ?? ""
        return verifies
            ? String(localized: "\(Formatters.bytes(bytes)) to copy and verify into “\(destination)”\(space)")
            : String(localized: "\(Formatters.bytes(bytes)) to copy into “\(destination)” (demo: not verified)")
    }

    /// Shown instead of the ready line when the selection can't fit.
    public static func notEnoughSpace(needed: Int64, free: Int64) -> String {
        String(localized: "Not enough space: \(Formatters.bytes(needed)) to copy, \(Formatters.bytes(free)) free. Choose fewer files or another sessions folder.")
    }

    /// VoiceOver label for a candidate tile.
    public static func tileLabel(_ c: ImportCandidate, selected: Bool, locked: Bool) -> String {
        let state = locked ? String(localized: "already imported") : (selected ? String(localized: "selected") : String(localized: "not selected"))
        return "\(c.filename), \(Formatters.bytes(c.size)), \(state)"
    }

    /// The Import button.
    public static func importButton(photos: Int, videos: Int) -> String {
        let p = photos == 1 ? String(localized: "Import 1 Photo") : String(localized: "Import \(photos) Photos")
        let v = videos == 1 ? String(localized: "1 Video") : String(localized: "\(videos) Videos")
        let vOnly = videos == 1 ? String(localized: "Import 1 Video") : String(localized: "Import \(videos) Videos")
        switch (photos > 0, videos > 0) {
        case (false, false): return String(localized: "Import")
        case (true, false): return p
        case (false, true): return vOnly
        case (true, true): return String(localized: "\(p) and \(v)")
        }
    }

    /// Card panel note in the Import & Archive tab.
    public static func cardPanelNote(verifies: Bool, live: Bool) -> String {
        if verifies {
            return String(localized: "Insert a memory card and Luxtable opens the import automatically. Files are copied, verified, and never deleted from the card.")
        }
        return live
            ? String(localized: "Import is coming soon. Insert a card to browse it read-only; Luxtable never copies from or deletes on a card until copies can be verified.")
            : String(localized: "Demo: imports are simulated and not verified. Nothing is ever deleted from a card.")
    }

    /// Onboarding line about importing.
    public static func onboardingImport(verifies: Bool) -> (title: String, text: String) {
        verifies
            ? (String(localized: "Insert a card, press Import"),
               String(localized: "Copies are verified before you're told they're safe. Nothing is ever deleted from a card."))
            : (String(localized: "Insert a card to browse it"),
               String(localized: "Verified import is coming soon. Until then Luxtable never copies from or deletes on a card."))
    }

    /// Note under the backup destination.
    public static func backupNote(verifies: Bool) -> String {
        verifies ? String(localized: "A second verified copy, written during import.")
            : String(localized: "A second copy, written during import (not verified in this build).")
    }

    public static func stoppedWhileFinishing(sessionName: String, ejected: Bool) -> String {
        String(localized: "Import stopped while finishing. The copied files are in “\(sessionName)”.")
            + (ejected ? String(localized: " The card was ejected.") : String(localized: " The card was not ejected."))
    }

    /// Heading over the list of card files that were not imported.
    public static func issuesTitle(scanErrors: Int, skipped: Int) -> String {
        switch (scanErrors, skipped) {
        case (0, 0): ""
        case (0, let k):
            k == 1 ? String(localized: "1 file on the card was not imported") : String(localized: "\(k) files on the card were not imported")
        case (let e, 0):
            e == 1 ? String(localized: "1 part of the card couldn’t be read") : String(localized: "\(e) parts of the card couldn’t be read")
        case (let e, let k): String(localized: "\(e) unreadable, \(k) not imported")
        }
    }

    /// Heading over the files that stay only on the card after an import.
    public static func stayOnCardTitle(_ n: Int) -> String {
        n == 1 ? String(localized: "1 file is only on the card") : String(localized: "\(files(n)) are only on the card")
    }

    /// Why the card stays: shown whenever something on it was not imported.
    public static func keepCardNote(scanErrors: Int) -> String {
        scanErrors > 0
            ? String(localized: "Parts of the card couldn’t be read, so the import isn’t complete. Keep the card and check it on another reader.")
            : String(localized: "These files stay only on the card. Copy them yourself if you need them before formatting it.")
    }

    /// The "Eject Anyway" confirmation.
    public static func ejectAnywayTitle(_ n: Int) -> String {
        n == 0 ? String(localized: "Eject the card?") : String(localized: "Eject with \(files(n)) only on the card?")
    }

    public static func ejectAnywayMessage(_ s: ImportModel.ImportSummary) -> String {
        guard s.checkedByService else { return String(localized: "These copies were not verified. Keep the card until they are.") }
        let names = s.stayOnCard.prefix(5).map { $0.url.lastPathComponent }.joined(separator: ", ")
        let more = s.stayOnCard.count > 5 ? String(localized: " and \(s.stayOnCard.count - 5) more") : ""
        return names.isEmpty
            ? String(localized: "Keep the card until the import is complete.")
            : s.stayOnCard.count == 1
            ? String(localized: "\(names)\(more) has no copy in your library. Don’t format the card until they do.")
            : String(localized: "\(names)\(more) have no copy in your library. Don’t format the card until they do.")
    }

    public static let acknowledgeLabel = String(localized: "I understand these files are only on the card")

    /// Line for an import that stopped part-way (journal kept for resume).
    public static func stopped(done: Int, total: Int) -> String {
        String(localized: "Import stopped after \(done) of \(files(total)). The verified copies are kept; import again to continue.")
    }

    /// The card went away mid-import (no raw path or errno).
    public static func cardRemoved(_ name: String) -> String {
        String(localized: "\(name) was removed. Nothing was deleted from it; insert it again to continue the import.")
    }

    /// Continuing an earlier, unfinished import of this card.
    public static func resumeNote(sessionName: String, left: Int) -> String {
        String(localized: "Continuing the unfinished import into “\(sessionName)”: \(files(left)) left.")
    }

    /// The launch prompt for an unfinished import.
    public static func resumePrompt(sessionName: String, done: Int, pending: Int) -> String {
        (done == 1 ? String(localized: "The import into “\(sessionName)” didn’t finish: 1 file verified, \(pending) left. ")
            : String(localized: "The import into “\(sessionName)” didn’t finish: \(done) files verified, \(pending) left. "))
            + String(localized: "Insert the card and import again to resume, or discard the unfinished copies.")
    }

    /// Quitting while an import runs (M3).
    public static let quitImportTitle = String(localized: "An import is running")
    public static let quitImportMessage = String(localized: "Stop it and quit? It resumes the next time you import the card.")

    public static func damagedNote(_ n: Int) -> String {
        n == 1 ? String(localized: "The library copy of 1 file was damaged. It is imported again from the card.")
            : String(localized: "The library copy of \(files(n)) was damaged. They are imported again from the card.")
    }

    public static func ejectHelp(canEject: Bool) -> String {
        canEject
            ? String(localized: "Nothing is ever deleted from the card. Eject says whether every file on it has a verified copy in your library.")
            : String(localized: "Only local removable volumes can be ejected.")
    }
}
