import CoreGraphics
import LuxtableAI
import Foundation

/// Per-panel actions invoked from tool panel headers and the Layers panel.
extension AppModel {
    /// A panel header's Copy: the focused photo, for this group only. Apply (the header's
    /// or the toolbar's) then pastes just this group until the next Copy; the Copy options
    /// are left alone (L6).
    public func copyGroup(_ group: AdjustGroup) {
        guard let p = focusedPhoto, !p.isVideo else { return }
        copyAdjustments(only: group)
        show(Toast(String(localized: "Copied \(group.title) from \(p.filename). Apply pastes just this group"), symbol: "doc.on.doc"))
    }

    /// Paste only `group` from the clipboard onto the selection but the copied photo (one
    /// undo step). Returns images changed.
    @discardableResult
    public func applyGroup(_ group: AdjustGroup) -> Int {
        guard clipboard != nil else {
            show(Toast(String(localized: "Copy adjustments first"), symbol: "doc.on.clipboard"))
            return 0
        }
        let rel = group.supportsRelative ? settings.copyRelativeGroups.intersection([group]) : []
        var o = PasteOptions(groups: [group], relative: rel)
        o.keepStraighten = settings.copyKeepsStraighten
        return pasteLoadingAsShotIfNeeded(to: applyTargets, options: o)
    }

    /// Apply a preset (or a stack) to the focused image, or all selected with Edit All Selected. One undo step.
    public func applyPresets(_ stack: [Preset]) {
        guard !stack.isEmpty else { return }
        let label = stack.count == 1 ? String(localized: "Style \(stack[0].name)") : String(localized: "\(stack.count) Styles")
        updateEdit(label: label) { e in e = Preset.apply(stack, to: e) }
    }

    /// The Styles panel's Original row: the photo back as shot, no adjustments at all
    /// (the focused image, or all selected with Edit All Selected). One undo step.
    public func resetToOriginal() {
        updateEdit(label: String(localized: "Original")) { $0 = EditState() }
    }

    /// The focused edit as a click on `preset`'s row leaves it (hover preview; a look's row
    /// applies the look), or nil without a focused image.
    public func previewEdit(applying preset: Preset) -> EditState? {
        focusedID.map { LookPack.applying(preset, to: edit(for: $0)) }
    }
}

/// Runs on-device Vision segmentation for AI masks.
public struct AIMasker: Sendable {
    /// Seam for tests.
    public var segment: @Sendable (AITarget, CGImage) async throws -> VisionMask?

    public init(segment: @escaping @Sendable (AITarget, CGImage) async throws -> VisionMask?) {
        self.segment = segment
    }

    /// Vision-backed: subject = foreground instance mask, person = person segmentation,
    /// background = inverted subject, sky = the Core ML segmentation model
    /// (`SkySegmentation`, downloaded on first use).
    public static let vision = AIMasker { target, image in
        let v = VisionService()
        switch target {
        case .subject: return try await v.subjectMask(image)
        case .person: return try await v.personMask(image)
        case .background:
            return try await v.subjectMask(image).map { m in
                VisionMask(width: m.width, height: m.height, bytes: m.bytes.map { 255 - $0 })
            }
        case .sky: return try await SkySegmentation.shared.mask(for: image)
        case .face, .skin, .eyes, .teeth, .hair, .clothes: return try await AIMasker.people(target, image)
        }
    }

    public static func isAvailable(_ target: AITarget) -> Bool { true }

    /// Tooltip of an AI mask button.
    @MainActor
    public static func help(_ target: AITarget) -> String {
        switch target {
        case .sky:
            SkySegmentation.shared.state == .ready
                ? String(localized: "Mask the sky on this Mac, on the selected layer (or a new one)")
                : String(localized: "Mask the sky on this Mac. The first time, an 86 MB model is downloaded and prepared.")
        default:
            String(localized: "Mask the \(target.maskNoun) with Apple Vision on this Mac, on the selected layer (or a new one)")
        }
    }
}

extension AITarget {
    /// The target in UI sentences, lowercase ("sky", "hair"); the raw value is its stable ID.
    var maskNoun: String {
        switch self {
        case .subject: String(localized: "subject")
        case .sky: String(localized: "sky")
        case .person: String(localized: "person")
        case .background: String(localized: "background")
        case .face: String(localized: "face")
        case .skin: String(localized: "skin")
        case .eyes: String(localized: "eyes")
        case .teeth: String(localized: "teeth")
        case .hair: String(localized: "hair")
        case .clothes: String(localized: "clothes")
        }
    }
}

public enum AIMaskError: Error, Equatable, LocalizedError {
    case unavailable(AITarget)
    case nothingFound(AITarget)
    case noImage

    public var errorDescription: String? {
        switch self {
        case .unavailable(let t): String(localized: "\(t.maskNoun.localizedCapitalized) masks aren't available on this Mac.")
        case .nothingFound(let t): String(localized: "No \(t.maskNoun) found in this photo.")
        case .noImage: String(localized: "No preview available for this photo.")
        }
    }
}

extension AppModel {
    /// The best image available for analysis: embedded preview, else the cached thumbnail.
    func analysisImage(for photo: Photo) async -> CGImage? {
        if let url = photo.url, let previews, let img = try? await previews.preview(for: url, maxPixelSize: 1024) {
            return img
        }
        return await thumbnails.image(for: photo, bucket: 1024)
    }

    /// Add an AI mask (`.ai(.add, target)`) to layer `layerID` (or a new layer) of the focused
    /// image, computing the mask with Vision. Returns the layer id, or throws a user-facing error.
    @discardableResult
    public func addAIMask(_ target: AITarget, toLayer layerID: Int?, masker: AIMasker = .vision) async throws -> Int {
        guard AIMasker.isAvailable(target) else { throw AIMaskError.unavailable(target) }
        guard let photo = focusedPhoto else { throw AIMaskError.noImage }
        guard let image = await analysisImage(for: photo) else { throw AIMaskError.noImage }
        guard let mask = try await masker.segment(target, image), mask.coverage > 0.001 else {
            throw AIMaskError.nothingFound(target)
        }
        var added = layerID ?? -1
        updateEdits([photo.id], label: String(localized: "AI \(target.maskNoun.localizedCapitalized) Mask")) { _, e in
            added = LayerOps.addShape(.ai(.add, target), toLayer: layerID, newLayerName: target.maskNoun.localizedCapitalized,
                                      in: &e.layers)
        }
        // The viewer's cache: the one its overlay and renders read (not always `.shared`).
        viewer.masks.set(mask, photo: photo.id, target: target)
        return added
    }
}
