import Foundation

/// Simple mode's plain sliders: each is an ordinary adjustment under an everyday name
/// (no new pipeline stage), so an edit made here is the same edit in the full tools.
/// Every slider runs -100…100 with 0 = untouched.
public enum SimpleAdjustment: String, CaseIterable, Identifiable, Sendable {
    case light, contrast, color, warmth, highlights, shadows

    public var id: String { rawValue }

    /// Exposure stops per slider unit: ±100 is ±2 EV.
    static let evPerUnit = 0.02
    /// Mireds per slider unit: ±100 moves the white balance ±80 mireds from as shot
    /// (5,500 K as shot: about 3,800 K to 9,800 K).
    static let miredPerUnit = 0.8

    public var spec: SliderSpec {
        switch self {
        case .light: SliderSpec("Light", -100...100, help: "Make the whole photo brighter or darker (Exposure).")
        case .contrast: SliderSpec("Contrast", -100...100, help: "More or less difference between darks and lights.")
        case .color: SliderSpec("Color", -100...100, help: "Stronger or softer colors (Saturation). All the way left is black and white.")
        case .warmth: SliderSpec("Warmth", -100...100, help: "Cooler (bluer) or warmer (more golden) light (White Balance). 0 is as shot.")
        case .highlights: SliderSpec("Highlights", -100...100, help: "Bring back detail in bright areas such as sky (–), or brighten them (+).")
        case .shadows: SliderSpec("Shadows", -100...100, help: "Lift dark areas to show detail (+), or deepen them (–).")
        }
    }

    /// The slider's position for `edit`. `asShot`: the camera's white balance, which
    /// Warmth is measured from (5,500 K when it isn't known).
    public func value(in edit: EditState, asShot: WhiteBalanceValue?) -> Double {
        let v: Double = switch self {
        case .light: edit.exposure.ev / Self.evPerUnit
        case .contrast: edit.exposure.contrast
        case .color: edit.exposure.saturation
        case .highlights: edit.hdr.highlights
        case .shadows: edit.hdr.shadows
        case .warmth:
            edit.whiteBalance.asShot ? 0
                : (Self.mired(Self.baseKelvin(asShot)) - Self.mired(edit.whiteBalance.temperature)) / Self.miredPerUnit
        }
        return spec.normalize(v)
    }

    /// Set the slider to `value` on `edit`.
    public func apply(_ value: Double, to edit: inout EditState, asShot: WhiteBalanceValue?) {
        let v = spec.normalize(value)
        switch self {
        case .light: edit.exposure.ev = SliderSpec.snap(v * Self.evPerUnit, step: Specs.exposure.step)
        case .contrast: edit.exposure.contrast = v
        case .color: edit.exposure.saturation = v
        case .highlights: edit.hdr.highlights = v
        case .shadows: edit.hdr.shadows = v
        case .warmth:
            // 0 is the camera's own white balance again.
            guard v != 0 else {
                edit.whiteBalance.asShot = true
                return
            }
            if edit.whiteBalance.asShot {
                // Leaving As Shot keeps the camera's tint, as the White Balance panel does.
                edit.whiteBalance.tint = asShot.map { ($0.tint * 10).rounded() / 10 } ?? 0
                edit.whiteBalance.asShot = false
            }
            let kelvin = 1_000_000 / (Self.mired(Self.baseKelvin(asShot)) - v * Self.miredPerUnit)
            edit.whiteBalance.temperature = Specs.temperature.normalize(kelvin)
        }
    }

    /// Whether `edit` has this slider away from 0.
    public func isAdjusted(_ edit: EditState, asShot: WhiteBalanceValue?) -> Bool {
        !spec.isDefault(value(in: edit, asShot: asShot))
    }

    private static func baseKelvin(_ asShot: WhiteBalanceValue?) -> Double {
        asShot.map(\.kelvin).flatMap { $0 > 0 ? $0 : nil } ?? Specs.temperature.defaultValue
    }

    private static func mired(_ kelvin: Double) -> Double { 1_000_000 / max(kelvin, 1) }
}

/// Simple mode's wording (kept out of the view, unit-tested).
public enum SimpleModeText {
    public static let menuTitle = "Simple Mode"
    public static let simple = "Simple"
    public static let full = "Full"
    public static let switchHelp = "Simple shows a few easy controls; Full shows every tool (⌃⌘S). Your edits are the same in both."
    public static let autoTitle = "Auto"
    public static let autoHelp = "Let Luxtable fix brightness, contrast and color in one click (⇧A). ⌘Z undoes it."
    public static let looks = "Looks"
    public static let adjust = "Adjust"
    public static let cropTitle = "Crop & Straighten"
    public static let beforeAfter = "Before / After"
    public static let resetTitle = "Start Over"
    public static let resetHelp = "Take this photo back to how it was shot (⇧⌘R). ⌘Z brings your edit back."
    public static let noPhoto = "Choose a photo to edit it."
    public static let moreTools = "Need more? Switch to Full for every tool. Edits made here show there too."

    /// The toast after switching.
    public static func switched(toSimple: Bool) -> String {
        toSimple ? "Simple mode: a few easy controls (⌃⌘S for every tool)" : "Full mode: every tool (⌃⌘S for Simple)"
    }
}

extension AppModel {
    /// Simple mode's slider for the focused photo.
    public func simpleValue(_ adjustment: SimpleAdjustment) -> Double {
        guard let f = focusedID else { return 0 }
        return adjustment.value(in: edit(for: f), asShot: asShot(for: f))
    }

    /// Move a Simple mode slider: one undo step per drag, named like the slider.
    public func setSimple(_ adjustment: SimpleAdjustment, _ value: Double) {
        guard let f = focusedID else { return }
        let asShot = asShot(for: f)
        updateEdit(label: adjustment.spec.label, coalesceKey: "simple-\(adjustment.rawValue)") { e in
            adjustment.apply(value, to: &e, asShot: asShot)
        }
    }

    /// Switch between Simple and Full (View ▸ Simple Mode, the tools pane's switch).
    public func setSimpleMode(_ on: Bool) {
        guard settings.simpleMode != on else { return }
        settings.simpleMode = on
        show(Toast(SimpleModeText.switched(toSimple: on), symbol: on ? "wand.and.stars" : "slider.horizontal.3"))
    }
}
