import Foundation

/// Slider specs for presence, layer tools, brushes and spots.
public enum LayerToolSpecs {
    public static let vibrance = SliderSpec(String(localized: "Vibrance"), -100...100, help: String(localized: "Boost muted colours first, protecting skin."))
    public static let texture = SliderSpec(String(localized: "Texture"), -100...100, help: String(localized: "Medium-sized detail: + crisper, – smoother."))
    public static let dehaze = SliderSpec(String(localized: "Dehaze"), -100...100, help: String(localized: "Remove (+) or add (–) atmospheric haze."))
    public static let temperatureShift = SliderSpec(String(localized: "Temp"), -3000...3000, step: 10, format: .signedInteger,
                                                    help: String(localized: "Warm (+) or cool (–) this layer, in Kelvin."))
    public static let tintShift = SliderSpec(String(localized: "Tint"), -150...150, help: String(localized: "Green (–) to magenta (+) for this layer."))
    public static let sharpening = SliderSpec(String(localized: "Sharpen"), -100...100, help: String(localized: "Sharpen (+) or soften (–) under the mask."))
    public static let brushSize = SliderSpec(String(localized: "Size"), 0.005...0.5, default: 0.05, step: 0.005, format: .percent,
                                             help: String(localized: "Brush diameter, as a share of the long edge ([ and ])."))
    public static let brushHardness = SliderSpec(String(localized: "Hardness"), 0...1, default: 0.5, step: 0.01, format: .percent,
                                                 help: String(localized: "Hard (100 %) or soft brush edge."))
    public static let brushFlow = SliderSpec(String(localized: "Flow"), 0.05...1, default: 1, step: 0.01, format: .percent,
                                             help: String(localized: "How much each pass of the brush adds."))
    /// Up to lt-core `MAX_PLANE_FEATHER` (0.05 of the long edge): the pipeline caps it there
    /// so a feathered mask renders the same in every view and in exports.
    public static let maskFeather = SliderSpec(String(localized: "Feather"), 0...0.05, step: 0.001, format: .percent,
                                               help: String(localized: "Soften the whole mask's edge."))
    public static let spotSize = SliderSpec(String(localized: "Size"), 0.005...0.2, default: 0.02, step: 0.005, format: .percent,
                                            help: String(localized: "Spot radius, as a share of the long edge."))
    public static let lumaLow = SliderSpec(String(localized: "Darkest"), 0...1, step: 0.01, format: .percent, help: String(localized: "Tones below this are left out."))
    public static let lumaHigh = SliderSpec(String(localized: "Brightest"), 0...1, default: 1, step: 0.01, format: .percent,
                                            help: String(localized: "Tones above this are left out."))
    public static let lumaFalloff = SliderSpec(String(localized: "Falloff"), 0...0.5, default: 0.1, step: 0.01, format: .percent,
                                               help: String(localized: "How softly the range fades at both ends."))
}
