import CoreGraphics
import Foundation
import Observation

/// A part of the main window the Getting Started tour lights up. Views tag themselves
/// with `.tourAnchor(_:)`; a part that isn't on screen gets the card without a spotlight.
public enum TourAnchor: String, CaseIterable, Sendable {
    case browser, viewer, tools, crop
}

/// Help ▸ Getting Started: a short coach-mark walk through the main window. Each step
/// dims the window, lights one part and explains it on a small card. It starts by itself
/// once, when first-run setup closes, and once in the sample-photos window.
@MainActor @Observable
public final class TourModel {
    public enum Step: String, CaseIterable, Sendable {
        case browse, viewer, tools, crop, bringIn, export, ready

        /// The part lit for this step (`nil`: the card alone).
        public var anchor: TourAnchor? {
            switch self {
            case .browse: .browser
            case .viewer: .viewer
            case .tools: .tools
            case .crop: .crop
            case .bringIn, .export, .ready: nil
            }
        }

        /// Import and Share sit in the window toolbar, which the dim can't cover: the card
        /// goes under them instead of in the middle.
        public var pointsAtToolbar: Bool { self == .bringIn || self == .export }

        public func title(simple: Bool) -> String {
            switch self {
            case .browse: String(localized: "Browse and cull")
            case .viewer: String(localized: "Look closely")
            case .tools: simple ? String(localized: "Simple editing") : String(localized: "Adjust the photo")
            case .crop: String(localized: "Crop")
            case .bringIn: String(localized: "Bring photos in")
            case .export: String(localized: "Export and share")
            case .ready: String(localized: "You’re ready")
            }
        }

        /// The card's text, with the user's own keys. `offersActions`: the last card has
        /// buttons to bring photos in.
        public func message(simple: Bool, bindings b: KeyBindings, offersActions: Bool = false) -> String {
            switch self {
            case .browse:
                let key = { (c: BindableCommand) in b.key(for: c).map(KeyBindings.display) }
                guard let r1 = key(.rate1), let r5 = key(.rate5), let pick = key(.pick), let reject = key(.reject) else {
                    return String(localized: "The filmstrip shows the session’s photos: click one, or move with ← and →. Rate, pick and reject from the Photo menu, which lists their keys.")
                }
                return String(localized: "The filmstrip shows the session’s photos: click one, or move with ← and →. Press \(r1)–\(r5) to rate, \(pick) to pick and \(reject) to reject.")
            case .viewer:
                let beforeAfter = b.help(String(localized: "Before/After"), .beforeAfter)
                return String(localized: "Space zooms to 100% where the pointer is; ⌘+ and ⌘− zoom in steps. \(beforeAfter) shows the photo as shot next to your edit.")
            case .tools:
                return simple
                    ? String(localized: "Auto fixes light and color in one click, a look restyles the photo, and six sliders fine-tune it. Crop & Straighten is at the bottom. View ▸ Simple Mode (⌃⌘S) switches to every tool.")
                    : String(localized: "The tool tabs hold every adjustment, from white balance and exposure to layers. For a few easy controls instead, choose View ▸ Simple Mode (⌃⌘S).")
            case .crop:
                let crop = b.help(CanvasTool.crop.viewerLabel, .cropTool)
                return String(localized: "\(crop) puts a box on the photo to move and resize; the arrow next to it picks a ratio such as Square or 16:9. Return applies, Esc cancels.")
            case .bringIn:
                return String(localized: "Import, at the left of the toolbar, copies a memory card and checks every file (⇧⌘I); an iPhone or iPad plugged in over USB is listed there too. File ▸ Import from Photos Library… brings in photos from Photos.")
            case .export:
                return String(localized: "File ▸ Export… (⌘E) saves the selected photos with your export recipes. Share… (⌥⌘E), next to Import, sends JPEGs with Messages, Mail or AirDrop.")
            case .ready:
                return offersActions
                    ? String(localized: "Bring in some photos to begin. Help ▸ Getting Started shows this tour again at any time.")
                    : String(localized: "Help ▸ Getting Started shows this tour again at any time.")
            }
        }
    }

    /// The steps for the panel in use: Simple mode's panel has Crop & Straighten itself,
    /// so the stage bar's Crop gets no step of its own there.
    public static func steps(simple: Bool) -> [Step] {
        Step.allCases.filter { !simple || $0 != .crop }
    }

    /// The steps of the running tour (fixed when it starts, so ⌃⌘S mid-tour doesn't move it).
    public private(set) var steps: [Step] = []
    public private(set) var index = 0
    public private(set) var isActive = false
    /// Simple mode was on when the tour started (the tools step describes its panel).
    public private(set) var simple = false

    @ObservationIgnored private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// The step on screen (`nil`: no tour).
    public var step: Step? { isActive ? steps[index] : nil }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index == steps.count - 1 }
    public var progress: String { String(localized: "Step \(index + 1) of \(steps.count)") }

    /// Start from the first step (Help ▸ Getting Started replays it at any time).
    public func start() {
        simple = settings.simpleMode
        steps = Self.steps(simple: simple)
        index = 0
        isActive = true
    }

    /// Start unless it was already shown (first-run setup closing, the sample window).
    @discardableResult
    public func autoStart() -> Bool {
        guard !settings.tourShown, !isActive else { return false }
        start()
        return true
    }

    /// The next card; Next on the last one finishes.
    public func next() {
        guard isActive else { return }
        if isLast { finish() } else { index += 1 }
    }

    public func back() {
        if isActive, index > 0 { index -= 1 }
    }

    /// Skip Tour (Esc): it isn't offered again by itself.
    public func skip() { end() }

    /// Done on the last card.
    public func finish() { end() }

    private func end() {
        isActive = false
        settings.tourShown = true
    }

    /// While the tour is up: → and Return go on, ← goes back, Esc skips. Other plain keys
    /// are swallowed (no rating under the dim); Tab and Space reach the card's buttons and
    /// ⌘ shortcuts the menus. True when the key was used.
    public func handle(_ key: KeyInput) -> Bool {
        guard isActive, !key.command, !key.option, !key.control else { return false }
        switch key.special {
        case .right, .returnKey: next()
        case .left: back()
        case .escape: skip()
        case .tab, .space: return false
        case .up, .down, nil: break
        }
        return true
    }
}

/// Where the tour's card goes: beside the lit part where it fits (below, above, right,
/// left), else inside it at its foot; under the toolbar's left end for the toolbar steps;
/// centred with nothing lit.
public enum TourLayout {
    public static let margin: CGFloat = 16

    public static func cardOrigin(spot: CGRect?, card: CGSize, in bounds: CGSize, toolbar: Bool = false) -> CGPoint {
        let m = margin
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, m), max(m, bounds.width - card.width - m)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, m), max(m, bounds.height - card.height - m)) }
        guard let s = spot else {
            if toolbar { return CGPoint(x: m, y: m) }
            return CGPoint(x: clampX((bounds.width - card.width) / 2), y: clampY((bounds.height - card.height) / 2))
        }
        if s.maxY + m + card.height <= bounds.height - m {
            return CGPoint(x: clampX(s.midX - card.width / 2), y: s.maxY + m)
        }
        if s.minY - m - card.height >= m {
            return CGPoint(x: clampX(s.midX - card.width / 2), y: s.minY - m - card.height)
        }
        if s.maxX + m + card.width <= bounds.width - m {
            return CGPoint(x: s.maxX + m, y: clampY(s.midY - card.height / 2))
        }
        if s.minX - m - card.width >= m {
            return CGPoint(x: s.minX - m - card.width, y: clampY(s.midY - card.height / 2))
        }
        return CGPoint(x: clampX(s.midX - card.width / 2), y: clampY(s.maxY - m - card.height))
    }
}

extension AppModel {
    /// First-run setup closed (Start Using Luxtable or Skip for Now): the sheet goes and
    /// the tour starts, once. Users who finished setup before never see the sheet again,
    /// so they get the tour only from the Help menu.
    public func endOnboarding() {
        sheet = nil
        tour.autoStart()
    }

    /// The last card's buttons: the first-run empty state's (a card, a folder, the samples).
    public var tourActions: [EmptyState.Action] { emptyStateActions }

    /// One of the last card's buttons: the tour ends, then the action runs. False when the
    /// view must run the folder panel (as for the empty state's Open Folder…).
    @discardableResult
    public func performTourAction(_ action: EmptyState.Action) -> Bool {
        tour.finish()
        return performEmptyStateAction(action)
    }
}
