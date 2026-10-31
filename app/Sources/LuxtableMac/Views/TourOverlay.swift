import LuxtableCore
import LuxtableUI
import SwiftUI

/// Help ▸ Getting Started over the main window: the window dimmed except the step's part
/// (from the views' `.tourAnchor`s), and the card beside it. A part that isn't on screen
/// (panels hidden, the grid instead of the viewer) gets the card alone, centred.
struct TourOverlay: View {
    @Bindable var model: AppModel
    var tour: TourModel
    let anchors: [TourAnchor: Anchor<CGRect>]
    @State private var cardSize = CGSize(width: 360, height: 200)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let step = tour.step {
            GeometryReader { geo in
                let spot = step.anchor.flatMap { anchors[$0] }.map { geo[$0].insetBy(dx: -6, dy: -6) }
                let origin = TourLayout.cardOrigin(spot: spot, card: cardSize, in: geo.size, toolbar: step.pointsAtToolbar)
                ZStack(alignment: .topLeading) {
                    dim(spot, in: geo.size)
                    card(step)
                        .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: tour.index)
            .transition(.opacity)
            .onChange(of: tour.index, initial: true) { // VoiceOver reads each new card
                AccessibilityNotification.Announcement(spoken(step)).post()
            }
        }
    }

    /// The window darkened with a hole over the lit part, which gets an accent ring.
    /// Decorative; it takes the clicks so nothing under it changes mid-tour.
    private func dim(_ spot: CGRect?, in size: CGSize) -> some View {
        let radius = DS.Radius.m
        return ZStack(alignment: .topLeading) {
            // (`--snapshot` window captures leave out translucent fills: the dim isn't in them.)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                if let spot { p.addRoundedRect(in: spot, cornerSize: CGSize(width: radius, height: radius)) }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            if let spot {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(DS.accent, lineWidth: 2)
                    .frame(width: spot.width, height: spot.height)
                    .offset(x: spot.minX, y: spot.minY)
            }
        }
        .contentShape(.rect)
        .onTapGesture {}
        .accessibilityHidden(true)
    }

    private func card(_ step: TourModel.Step) -> some View {
        let actions = step == .ready ? model.tourActions : []
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(tour.progress).font(DS.Font.label).foregroundStyle(DS.textSecondary)
            Text(step.title(simple: tour.simple)).font(.headline)
            Text(message(step, actions: actions))
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(actions, id: \.self) { a in
                        Button(a.title) {
                            if !model.performTourAction(a) { OpenFolderPanel.run(model: model) }
                        }
                    }
                }
                .padding(.top, DS.Space.xs)
            }
            HStack {
                if !tour.isLast {
                    Button("Skip Tour") { tour.skip() }
                        .buttonStyle(.link)
                        .help("Close the tour (Esc). Help ▸ Getting Started shows it again.")
                }
                Spacer()
                if !tour.isFirst {
                    Button("Back") { tour.back() }
                }
                Button(tour.isLast ? "Done" : "Continue") { tour.next() }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
            }
            .padding(.top, DS.Space.xs)
        }
        .font(.callout)
        .padding(DS.Space.l)
        .frame(width: 360, alignment: .leading)
        .background(DS.panelBackground, in: .rect(cornerRadius: DS.Radius.l))
        .shadow(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(step))
        .accessibilityAddTraits(.isModal)
    }

    private func message(_ step: TourModel.Step, actions: [EmptyState.Action]) -> String {
        step.message(simple: tour.simple, bindings: model.settings.keyBindings, offersActions: !actions.isEmpty)
    }

    private func spoken(_ step: TourModel.Step) -> String {
        let actions = step == .ready ? model.tourActions : []
        return "\(step.title(simple: tour.simple)). \(message(step, actions: actions)) \(tour.progress)"
    }
}
