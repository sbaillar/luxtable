import LuxtableCore
import SwiftUI

/// Simple mode's one panel, in place of the tool tabs: Auto, Looks on the photo itself,
/// a few plain sliders, Crop & Straighten and Before / After. Everything here is an
/// ordinary adjustment (`SimpleAdjustment`), so Full mode shows the same edit.
struct SimplePanel: View {
    @Bindable var model: AppModel
    @State private var thumbnails: StyleThumbnails?
    @State private var hovered: UUID?

    private var canEdit: Bool { model.focusedPhoto.map { !$0.isVideo } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if !canEdit {
                    PanelNote(verbatim: SimpleModeText.noPhoto)
                }
                autoButton
                section(SimpleModeText.looks) { looks }
                section(SimpleModeText.adjust) {
                    VStack(spacing: DS.Space.s) {
                        ForEach(SimpleAdjustment.allCases) { a in
                            ToolSlider(spec: a.spec, value: model.simpleValue(a), onEnd: { model.endEditGesture() }) { v in
                                model.setSimple(a, v)
                            }
                        }
                    }
                }
                section(SimpleModeText.cropTitle) { photoTools }
                HStack {
                    Button(SimpleModeText.resetTitle, systemImage: "arrow.counterclockwise") {
                        CommandCatalog.perform(.resetAllAdjustments, model: model)
                    }
                    .disabled(!CommandCatalog.isEnabled(.resetAllAdjustments, model: model))
                    .help(SimpleModeText.resetHelp)
                    Spacer()
                }
                .controlSize(.small)
                PanelNote(verbatim: SimpleModeText.moreTools)
            }
            .padding(DS.Space.m)
            .disabled(!canEdit)
        }
        .scrollIndicators(.automatic)
        .task(id: model.focusedID) { if let id = model.focusedID { await model.loadDevelopInfo(for: [id]) } }
        .onAppear(perform: refreshThumbnails)
        .onChange(of: model.focusedID) { refreshThumbnails() }
        .onChange(of: model.focusedEdit) { refreshThumbnails() }
        .onDisappear {
            hovered = nil
            if model.optimizePanel == nil { model.viewer.setPreviewEdit(nil) }
            thumbnails?.cancel()
        }
    }

    private var autoButton: some View {
        Button {
            Task { await model.autoAdjust() }
        } label: {
            Label(SimpleModeText.autoTitle, systemImage: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(DS.accent)
        .help(SimpleModeText.autoHelp)
        .accessibilityHint(SimpleModeText.autoHelp)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title.uppercased())
                .font(DS.Font.panelTitle).tracking(0.6)
                .foregroundStyle(DS.textSecondary)
            content()
        }
    }

    // MARK: Looks

    private var looks: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ScrollView(.horizontal) {
                HStack(spacing: DS.Space.s) {
                    let original = StyleThumbnails.originalID
                    tile(id: original, title: String(localized: "Original"), applied: model.focusedEdit == EditState(),
                         preview: EditState()) { model.resetToOriginal() }
                        .accessibilityLabel("Back to the original")
                    ForEach(LookPack.all, id: \.id) { look in
                        tile(id: look.preset.id, title: look.name, applied: model.focusedEdit.look?.id == look.id,
                             preview: model.previewEdit(applying: look.preset)) { model.applyLook(look) }
                            .help(look.summary)
                            .accessibilityLabel("Apply look \(look.name)")
                    }
                }
                .padding(.bottom, DS.Space.xs)
            }
            .scrollIndicators(.visible)
            if let look = model.focusedEdit.look {
                LookIntensityRow(model: model, look: look)
            }
        }
    }

    private func tile(id: UUID, title: String, applied: Bool, preview: EditState?, apply: @escaping () -> Void) -> some View {
        Button {
            hover(nil, preview: nil)
            apply()
        } label: {
            VStack(spacing: DS.Space.xxs) {
                Group {
                    if let t = thumbnails?.tile(id) {
                        Image(decorative: t.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .opacity(t.isStale ? 0.55 : 1)
                    } else {
                        Image(systemName: "camera.filters").foregroundStyle(DS.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.05))
                    }
                }
                .frame(width: 72, height: 50)
                .clipShape(.rect(cornerRadius: DS.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s)
                    .strokeBorder(applied ? DS.accent : hovered == id ? DS.accent.opacity(0.5) : .clear, lineWidth: 2))
                Text(title)
                    .font(DS.Font.caption)
                    .foregroundStyle(applied ? DS.accent : DS.textSecondary)
                    .lineLimit(1)
                    .frame(width: 72)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(applied ? .isSelected : [])
        .onHover { inside in hover(inside ? id : (hovered == id ? nil : hovered), preview: inside ? preview : nil) }
    }

    /// Hover previews the tile in the viewer (AI Optimize, when open, owns the preview).
    private func hover(_ id: UUID?, preview: EditState?) {
        hovered = id
        guard model.optimizePanel == nil else { return }
        model.viewer.setPreviewEdit(model.focusedID == nil ? nil : preview)
    }

    private func refreshThumbnails() {
        if thumbnails == nil {
            thumbnails = StyleThumbnails(render: StyleThumbnails.render(with: model.tools))
        }
        thumbnails?.refresh(photo: model.focusedPhoto, edit: model.focusedEdit, presets: LookPack.all.map(\.preset))
    }

    // MARK: Crop, straighten, before / after

    private var photoTools: some View {
        let keys = model.settings.keyBindings
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                ForEach([CanvasTool.crop, .straighten], id: \.self) { tool in
                    Button { model.perform(.tool(tool)) } label: {
                        Label(tool.viewerLabel, systemImage: tool.viewerSymbol)
                    }
                    .buttonStyle(ToolbarPillStyle(showsTitle: true, isOn: model.viewer.canvasTool == tool))
                    .help(ToolbarHelp.tool(tool, keys))
                    .accessibilityLabel("\(tool.viewerLabel) tool")
                }
                Button { model.viewer.rotate(by: -1) } label: {
                    Label(CommandCatalog.title(.rotateLeft, model: model), systemImage: "rotate.left")
                }
                .buttonStyle(ToolbarPillStyle())
                .help("Rotate left (⌘[)")
            }
            Button { model.perform(.toggleBeforeAfter) } label: {
                Label(SimpleModeText.beforeAfter, systemImage: "square.split.2x1")
            }
            .buttonStyle(ToolbarPillStyle(showsTitle: true, isOn: model.viewer.state.beforeAfter))
            .help(ToolbarHelp.beforeAfter(keys))
            .accessibilityLabel(ToolbarControl.beforeAfter.control(model).label)
        }
    }
}

/// Simple / Full: the switch at the top of the tools pane (also View ▸ Simple Mode, ⌃⌘S).
struct SimpleModeSwitch: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker(SimpleModeText.menuTitle, selection: Binding(get: { model.settings.simpleMode },
                                                            set: { model.setSimpleMode($0) })) {
            Text(SimpleModeText.simple).tag(true)
            Text(SimpleModeText.full).tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(SimpleModeText.switchHelp)
        .accessibilityLabel(SimpleModeText.menuTitle)
    }
}
