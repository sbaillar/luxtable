import Foundation

/// Everything the keyboard can do. `AppModel.perform(_:)` executes these.
public enum KeyCommand: Equatable, Sendable {
    case move(Direction, extend: Bool)
    case rate(Int)
    case tag(ColorTag)
    case pick, reject, unflag
    case zoomToggleAtCursor
    case toggleFullScreen
    /// F / Tab: hide tool panels and filmstrip (C1/LR); real full screen is ⌃⌘F.
    case togglePanels
    /// B: hide just the filmstrip (the tool panels stay).
    case toggleFilmstrip
    /// S: expand/collapse the burst stack of the focused photo.
    case toggleStack
    case copyAdjustments, applyAdjustments, copyFromPrevious
    case undo, redo
    case showCheatSheet
    case gridMode, viewerMode
    case toggleBeforeAfter
    case togglePinCompare
    /// [cmp9] Enter/leave a canvas tool (crop C, straighten R, color picker I).
    case tool(CanvasTool)
    /// A mask tool (brush, eraser, gradients) on the selected layer, adding one if needed.
    case maskTool(CanvasTool)
    case whiteBalancePicker
    case survey
    case toggleClipping
    case auto
    /// ⇧S: soft proof on/off.
    case toggleSoftProof
    case selectAll
    case escape
    /// [lay9] [ / ]: smaller / larger brush (or heal/clone spot).
    case brushSize(Int)

    public enum Direction: Sendable { case left, right, up, down }
}

/// A key press, decoupled from `NSEvent` so routing is unit-testable.
public struct KeyInput: Equatable, Sendable {
    public enum Special: Sendable { case left, right, up, down, space, escape, returnKey, tab }

    public var characters: String
    public var special: Special?
    public var command = false
    public var shift = false
    public var option = false
    public var control = false
    /// Auto-repeat (key held down).
    public var isRepeat = false

    public init(_ characters: String = "", special: Special? = nil, command: Bool = false, shift: Bool = false,
                option: Bool = false, control: Bool = false, isRepeat: Bool = false) {
        self.isRepeat = isRepeat
        self.characters = characters
        self.special = special
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// Maps key presses to commands (PLAN §6 culling keys + §8 copy/apply).
public enum KeyboardRouter {
    public static func command(for key: KeyInput, bindings: KeyBindings = .defaults) -> KeyCommand? {
        if key.control { return nil }
        if let special = key.special {
            guard !key.command, !key.option else { return nil }
            switch special {
            case .left: return .move(.left, extend: key.shift)
            case .right: return .move(.right, extend: key.shift)
            case .up: return .move(.up, extend: key.shift)
            case .down: return .move(.down, extend: key.shift)
            case .space: return key.shift ? nil : .zoomToggleAtCursor
            case .escape: return .escape
            case .returnKey: return .viewerMode
            case .tab: return key.shift ? nil : .togglePanels
            }
        }
        let c = key.characters.lowercased()
        if key.command {
            switch (c, key.shift, key.option) {
            case ("c", true, false): return .copyAdjustments
            case ("v", true, false): return .applyAdjustments
            case ("v", false, true): return .copyFromPrevious
            case ("z", false, false): return .undo
            case ("z", true, false): return .redo
            case ("a", false, false): return .selectAll
            default: return nil
            }
        }
        if key.option { return nil }
        guard let ch = key.characters.first, key.characters.count == 1 else { return nil }
        if ch == "?" { return .showCheatSheet }
        if key.shift, c == "a" { return .auto }
        if key.shift, c == "s" { return .toggleSoftProof }
        if ch == "[" { return .brushSize(-1) } // [lay9]
        if ch == "]" { return .brushSize(1) }
        // Otherwise shift is ignored (caps lock / shifted letters still cull).
        return bindings.command(for: ch)
    }

    /// Rows for the `?` cheat sheet, grouped, with the user's current keys (N15).
    public static func cheatSheet(bindings: KeyBindings = .defaults) -> [(section: String, rows: [(keys: String, action: String)])] {
        func k(_ c: BindableCommand) -> String { bindings.key(for: c).map(KeyBindings.display) ?? "—" }
        func ks(_ cs: [BindableCommand], _ sep: String = " / ") -> String { cs.map(k).joined(separator: sep) }
        return [
            (String(localized: "Navigate"), [("← → ↑ ↓", String(localized: "Previous / next photo")), (String(localized: "⇧ + arrows"), String(localized: "Extend selection")),
                          (ks([.gridMode, .viewerMode]), String(localized: "Grid / Viewer")), ("↩", String(localized: "Open in viewer")), ("⌘A", String(localized: "Select all"))]),
            (String(localized: "Cull"), [(ks([.rate1, .rate2, .rate3, .rate4, .rate5], " "), String(localized: "Rate 1–5 stars")), (k(.rate0), String(localized: "Clear rating")),
                      (ks([.tagRed, .tagYellow, .tagGreen, .tagBlue, .tagPurple], " "), String(localized: "Red, yellow, green, blue, purple tag")),
                      (ks([.tagOrange, .tagPink], " "), String(localized: "Orange, pink tag (unbound unless you assign keys)")),
                      (ks([.pick, .reject, .unflag]), String(localized: "Pick / Reject / Unflag"))]),
            (String(localized: "View"), [(String(localized: "Space"), String(localized: "100% at cursor")), ("\(k(.togglePanels)) / Tab", String(localized: "Hide panels")), ("⌃⌘F", String(localized: "Full screen")),
                      (k(.beforeAfter), String(localized: "Before / after")), (k(.pinCompare), String(localized: "Pin for compare")),
                      (k(.toggleStack), String(localized: "Expand / collapse stack")),
                      ("← → ↩ Esc", String(localized: "Burst strip: frames, use as cover, close")), (k(.survey), String(localized: "Survey the selection")),
                      (k(.toggleClipping), String(localized: "Clipping warning")), ("⇧S", String(localized: "Soft proof on / off")),
                      ("Esc", String(localized: "Back / close"))]),
            (String(localized: "Compose"), [(k(.cropTool), String(localized: "Crop tool (⏎ apply, Esc cancel, X swap orientation)")),
                         (k(.straightenTool), String(localized: "Straighten tool (drag along the horizon)")),
                         (k(.colorPickerTool), String(localized: "Color readout picker")),
                         (k(.whiteBalanceTool), String(localized: "White balance picker")),
                         (ks([.brushTool, .eraserTool]), String(localized: "Brush / erase mask on the selected layer")),
                         (ks([.gradientTool, .radialTool]), String(localized: "Linear / radial gradient mask"))]
                            .filter { $0.keys.contains { $0.isLetter || $0.isNumber } }), // no key bound: not listed
            (String(localized: "Edit"), [("⌘K", String(localized: "Edit with words (“warmer, a bit brighter”)")), ("⇧A", String(localized: "Auto adjust")), ("⌥⌘A", String(localized: "AI Optimize (explained suggestions)")), ("⌘⇧C", String(localized: "Copy the edited adjustments (▾ beside Copy: Edited or Custom)")),
                      ("⌘⇧V", String(localized: "Apply them to the selected photos but the copied one (one ⌘Z)")),
                      ("⌥⌘V", String(localized: "Copy from previous")), ("⌥⇧⌘M", String(localized: "Match total exposures to the focused photo")),
                      ("⇧⌘H", String(localized: "Merge to HDR (2+ photos)")), ("⇧⌘M", String(localized: "Merge to Panorama (2+ photos)")),
                      ("⇧⌘B", String(localized: "Merge a burst to one Best Shot (open eyes, sharpest parts)")),
                      ("⌘Z / ⇧⌘Z", String(localized: "Undo / Redo")), ("?", String(localized: "This cheat sheet"))]),
            (String(localized: "Voice"), [("⌃⌘V", String(localized: "Voice commands on / off; then say:")),
                       ("“next” “back”", String(localized: "Next / previous photo (also “first”, “last”)")),
                       ("“next 3” “go to 12”", String(localized: "Move several, go to a photo (“the 4th photo”)")),
                       ("“reject the next 3”", String(localized: "Several photos at once, one undo step")),
                       ("“five” “3 stars”", String(localized: "Rate (“clear”: no stars)")), ("“pick” “reject”", String(localized: "Flag (“unflag”)")),
                       ("“red” … “pink”", String(localized: "Color tag")), ("“five next”", String(localized: "Rate, then next")),
                       ("“grid” “fit”", String(localized: "Grid, viewer, zoom in / out, fit, hundred percent")),
                       ("“undo” “auto”", String(localized: "Undo, redo, copy / apply adjustments, auto adjust")),
                       ("“edit warmer”", String(localized: "Edit with words")),
                       ("“what can I say?”", String(localized: "Every voice command (also View ▸ What Can I Say?)"))]),
        ]
    }
}
