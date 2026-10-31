import LuxtableCore
import LuxtableUI
import SwiftUI

/// The Best Shot preview as a short tour (`BestShotTourStep.tour`): the base frame, each
/// frame that gave something with those parts lit and the rest dimmed, then the result
/// with every part outlined. It plays once and rests on the result; Replay plays it again.
/// With Reduce Motion it shows the result at once.
struct BestShotTourView: View {
    let model: MergeModel
    let steps: [BestShotTourStep]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var plays = 0

    static let stepDuration: Duration = .milliseconds(1600)

    var body: some View {
        let step = steps[min(index, steps.count - 1)]
        let aspect = model.preview.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let rect = Self.fitted(aspect: aspect, in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image = model.image(for: step.picture) {
                        Image(decorative: image, scale: 1).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .id(step.picture) // a crossfade between frames
                            .transition(.opacity)
                    }
                    Spotlight(highlights: step.highlights, rect: rect, dims: step.picture != .result)
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
        .task(id: plays) { await play() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Best Shot preview: \(steps.last?.caption ?? "")")
    }

    private func play() async {
        guard !reduceMotion else { return index = steps.count - 1 }
        index = 0
        for i in steps.indices.dropFirst() {
            do { try await Task.sleep(for: Self.stepDuration) } catch { return }
            withAnimation(.easeInOut(duration: 0.45)) { index = i }
        }
    }

    /// The largest rect of `aspect` centred in `size`.
    static func fitted(aspect: CGFloat, in size: CGSize) -> CGRect {
        let w = min(size.width, size.height * aspect), h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// The parts a step lights: dims the rest of the photo (on a source frame) and outlines
/// each part, faces in yellow, sharper areas in cyan.
private struct Spotlight: View {
    let highlights: [BestShotPatch]
    let rect: CGRect
    let dims: Bool

    var body: some View {
        let boxes = highlights.map { h in
            (h.kind, CGRect(x: rect.minX + h.bounds.minX * rect.width, y: rect.minY + h.bounds.minY * rect.height,
                            width: h.bounds.width * rect.width, height: h.bounds.height * rect.height))
        }
        ZStack(alignment: .topLeading) {
            if dims, !boxes.isEmpty {
                Path { p in
                    p.addRect(rect)
                    for (_, b) in boxes { p.addRoundedRect(in: b, cornerSize: CGSize(width: 6, height: 6)) }
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
            }
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                let color: Color = box.0 == .face ? .yellow : .cyan
                RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 2)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .frame(width: box.1.width, height: box.1.height)
                    .offset(x: box.1.minX, y: box.1.minY)
            }
        }
        .allowsHitTesting(false)
    }
}
