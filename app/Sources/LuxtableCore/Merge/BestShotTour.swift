import CoreGraphics
import Foundation

/// The merge sheet's Best Shot tour: the base frame, then the photo built up one frame at a
/// time (each frame's parts laid over the base, the new ones compared up close with the
/// base), then the result with every part outlined.
public struct BestShotTourStep: Equatable, Sendable {
    public enum Picture: Hashable, Sendable {
        /// The source at this index (its preview, upright).
        case source(Int)
        case result
    }

    public var picture: Picture
    /// The parts this step adds (outlined, and compared up close with the base).
    public var highlights: [BestShotPatch]
    /// On a source step: every part laid over the base so far, this step's included.
    public var layers: [BestShotPatch]
    public var caption: String

    public init(picture: Picture, highlights: [BestShotPatch], layers: [BestShotPatch] = [], caption: String) {
        self.picture = picture
        self.highlights = highlights
        self.layers = layers
        self.caption = caption
    }

    /// The tour of `p` (none when nothing came from another frame: no story to tell).
    public static func tour(_ p: PhotoMergePreview) -> [BestShotTourStep] {
        guard !p.patches.isEmpty else { return [] }
        var steps = [BestShotTourStep(picture: .source(p.reference), highlights: [],
                                      caption: String(localized: "Frame \(String(p.reference + 1)): the best frame, the base"))]
        var layers: [BestShotPatch] = []
        for source in Set(p.patches.map(\.source)).sorted() where source != p.reference {
            let given = p.patches.filter { $0.source == source }
            layers += given
            steps.append(BestShotTourStep(picture: .source(source), highlights: given, layers: layers,
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

    /// The base frame's preview (what the tour builds on).
    public var baseImage: CGImage? { image(for: .source(preview?.reference ?? 0)) }
}

extension CGImage {
    /// The part of the image at `bounds` (normalized, top-left origin), grown by `margin` of
    /// its size on every side for context and kept inside the image; nil when empty.
    public func crop(normalized bounds: CGRect, margin: CGFloat = 0) -> CGImage? {
        let grown = bounds.insetBy(dx: -bounds.width * margin, dy: -bounds.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !grown.isNull else { return nil }
        let (w, h) = (CGFloat(width), CGFloat(height))
        let x0 = (grown.minX * w).rounded(), y0 = (grown.minY * h).rounded()
        let px = CGRect(x: x0, y: y0, width: (grown.maxX * w).rounded() - x0, height: (grown.maxY * h).rounded() - y0)
        guard px.width >= 1, px.height >= 1 else { return nil }
        return cropping(to: px)
    }
}
