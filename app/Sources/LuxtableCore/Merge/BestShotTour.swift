import CoreGraphics
import Foundation

/// The merge sheet's Best Shot tour: the base frame, then each frame that gave something
/// with the parts it gave highlighted, then the result with every part outlined.
public struct BestShotTourStep: Equatable, Sendable {
    public enum Picture: Hashable, Sendable {
        /// The source at this index (its preview, upright).
        case source(Int)
        case result
    }

    public var picture: Picture
    public var highlights: [BestShotPatch]
    public var caption: String

    public init(picture: Picture, highlights: [BestShotPatch], caption: String) {
        self.picture = picture
        self.highlights = highlights
        self.caption = caption
    }

    /// The tour of `p` (none when nothing came from another frame: no story to tell).
    public static func tour(_ p: PhotoMergePreview) -> [BestShotTourStep] {
        guard !p.patches.isEmpty else { return [] }
        var steps = [BestShotTourStep(picture: .source(p.reference), highlights: [],
                                      caption: String(localized: "Frame \(String(p.reference + 1)): the best frame, the base"))]
        for source in Set(p.patches.map(\.source)).sorted() where source != p.reference {
            let given = p.patches.filter { $0.source == source }
            steps.append(BestShotTourStep(picture: .source(source), highlights: given,
                                          caption: String(localized: "Frame \(String(source + 1)): \(gifts(given))")))
        }
        steps.append(BestShotTourStep(picture: .result, highlights: p.patches, caption: String(localized: "The Best Shot")))
        return steps
    }

    /// "a face", "2 sharper areas", "a face and a sharper area", …
    static func gifts(_ patches: [BestShotPatch]) -> String {
        let faces = patches.filter { $0.kind == .face }.count
        let sharper = patches.count - faces
        var parts: [String] = []
        if faces > 0 { parts.append(faces == 1 ? String(localized: "a face") : String(localized: "\(faces) faces")) }
        if sharper > 0 {
            parts.append(sharper == 1 ? String(localized: "a sharper area") : String(localized: "\(sharper) sharper areas"))
        }
        return parts.joined(separator: String(localized: " and "))
    }
}

extension MergeModel {
    /// The Best Shot tour of the current preview, once the source frames are loaded.
    public var bestShotTour: [BestShotTourStep] {
        guard kind == .burst, let p = preview, frameImages.count == sources.count else { return [] }
        return BestShotTourStep.tour(p)
    }

    /// What a tour step shows: a source's preview, or the result.
    public func image(for picture: BestShotTourStep.Picture) -> CGImage? {
        switch picture {
        case .result: preview?.image
        case .source(let i): frameImages.indices.contains(i) ? frameImages[i] ?? preview?.image : preview?.image
        }
    }
}
