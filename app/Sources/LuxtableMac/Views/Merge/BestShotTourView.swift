import LuxtableCore
import LuxtableUI
import SwiftUI

/// The Best Shot preview as a short tour (`BestShotTourStep.tour`): the base frame, then the
/// photo built up one frame at a time (each frame's parts laid over the base), with the
/// parts being added compared up close under it (the base's, then that frame's), then the
/// result with every part outlined. It plays once and rests on the result; Replay plays it
/// again. With Reduce Motion it shows the result at once.
struct BestShotTourView: View {
    let model: MergeModel
    let steps: [BestShotTourStep]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var plays = 0

    static let stepDuration: Duration = .milliseconds(2400)
    /// Close-ups per step (the largest parts first).
    static let closeUps = 2

    var body: some View {
        let step = steps[min(index, steps.count - 1)]
        let aspect = model.preview.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        VStack(spacing: DS.Space.xs) {
            ZStack(alignment: .bottom) {
                GeometryReader { geo in
                    let rect = Self.fitted(aspect: aspect, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        picture(step, in: rect)
                        Outlines(highlights: step.highlights, rect: rect)
                            .id(index) // each step's outlines draw in fresh
                            .transition(.opacity)
                    }
                }
                HStack(spacing: DS.Space.s) {
                    Text(step.caption).font(DS.Font.label).foregroundStyle(.white)
                    if index == steps.count - 1, steps.count > 1 {
                        Button("Replay", systemImage: "arrow.counterclockwise") { plays += 1 }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.white)
                            .help("Show again which frame each part came from")
                            .accessibilityLabel("Replay the Best Shot tour")
                    }
                }
                .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, DS.Space.s)
            }
            // Under the photo, never over the parts they show; the row keeps its height when empty.
            CloseUps(pairs: closeUps(step))
                .id(index)
                .transition(.opacity)
                .frame(height: CloseUps.height)
        }
        .task(id: plays) { await play() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Best Shot preview: \(steps.last?.caption ?? "")")
    }

    /// A source step: the base with every part so far laid over it, each from its own frame.
    /// The base step and the result: the picture itself.
    @ViewBuilder private func picture(_ step: BestShotTourStep, in rect: CGRect) -> some View {
        let base = step.picture == .result ? model.image(for: .result) : model.baseImage
        ZStack(alignment: .topLeading) {
            if let base { photo(base, in: rect).id(step.picture == .result ? "result" : "base") }
            if step.picture != .result {
                ForEach(Array(step.layers.enumerated()), id: \.offset) { _, layer in
                    if let source = model.image(for: .source(layer.source)) {
                        photo(source, in: rect)
                            .mask(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 8)
                                    .frame(width: layer.bounds.width * rect.width, height: layer.bounds.height * rect.height)
                                    .offset(x: rect.minX + layer.bounds.minX * rect.width,
                                            y: rect.minY + layer.bounds.minY * rect.height)
                                    .blur(radius: 3) // a soft edge, as the merge blends it
                            }
                            .transition(.opacity)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func photo(_ image: CGImage, in rect: CGRect) -> some View {
        Image(decorative: image, scale: 1).resizable()
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    /// The step's parts up close, largest first: the base's (before) and the frame's (or,
    /// on the result, the Best Shot's).
    private func closeUps(_ step: BestShotTourStep) -> [CloseUps.Pair] {
        let parts = step.highlights.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
        return parts.prefix(Self.closeUps).compactMap { part in
            let after = step.picture == .result ? model.image(for: .result) : model.image(for: .source(part.source))
            guard let before = model.baseImage?.crop(normalized: part.bounds, margin: 0.25),
                  let now = after?.crop(normalized: part.bounds, margin: 0.25) else { return nil }
            let label = step.picture == .result ? String(localized: "Best Shot")
                : String(localized: "Frame \(String(part.source + 1))")
            return CloseUps.Pair(before: before, after: now, afterLabel: label, kind: part.kind)
        }
    }

    private func play() async {
        guard !reduceMotion else { return index = steps.count - 1 }
        index = 0
        for i in steps.indices.dropFirst() {
            do { try await Task.sleep(for: Self.stepDuration) } catch { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = i }
        }
    }

    /// The largest rect of `aspect` centred in `size`.
    static func fitted(aspect: CGFloat, in size: CGSize) -> CGRect {
        let w = min(size.width, size.height * aspect), h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    static func color(_ kind: BestShotPatch.Kind) -> Color { kind == .face ? .yellow : .cyan }
}

/// The parts a step adds, outlined: faces in yellow, sharper areas in cyan.
private struct Outlines: View {
    let highlights: [BestShotPatch]
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, h in
                let color = BestShotTourView.color(h.kind)
                RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 2)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .frame(width: max(h.bounds.width * rect.width, 12), height: max(h.bounds.height * rect.height, 12))
                    .offset(x: rect.minX + h.bounds.minX * rect.width, y: rect.minY + h.bounds.minY * rect.height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Before and after, up close: the base's part next to the one that replaces it.
private struct CloseUps: View {
    struct Pair {
        var before: CGImage
        var after: CGImage
        var afterLabel: String
        var kind: BestShotPatch.Kind
    }

    let pairs: [Pair]
    static let side: CGFloat = 72
    /// The row's height: a tile and its label.
    static let height: CGFloat = side + 16

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: DS.Space.xxs) {
                    tile(pair.before, label: String(localized: "Before"), color: DS.textSecondary)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.textSecondary)
                    tile(pair.after, label: pair.afterLabel, color: BestShotTourView.color(pair.kind))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tile(_ image: CGImage, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: Self.side, height: Self.side).clipped()
                .clipShape(.rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 1.5))
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.textSecondary)
        }
    }
}
