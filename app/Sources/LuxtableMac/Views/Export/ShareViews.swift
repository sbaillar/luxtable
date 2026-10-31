import AppKit
import LuxtableCore
import LuxtableUI
import SwiftUI

/// The toolbar's Share button; the share picker points at it.
struct ShareToolbarButton: View {
    @Bindable var model: AppModel
    var showsTitle = true

    var body: some View {
        let control = ToolbarControl.share.control(model)
        Button { CommandCatalog.perform(.share, model: model) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(ToolbarPillStyle(showsTitle: showsTitle))
        .background(ShareAnchor(picker: model.sharePresenter as? PlatformSharePicker))
        .disabled(!CommandCatalog.isEnabled(.share, model: model))
        .help(control.hint ?? "")
        .accessibilityLabel(control.label)
    }
}

/// Hands its view to the share picker as the place to point at.
private struct ShareAnchor: NSViewRepresentable {
    let picker: PlatformSharePicker?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        picker?.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { picker?.anchor = view }
}

/// "Preparing 2 of 5 photos to share…" with a Cancel button, while Share… renders.
struct ShareProgressHUD: View {
    let share: ShareModel

    var body: some View {
        if let text = share.progressText {
            HStack(spacing: DS.Space.s) {
                ProgressView(value: share.fraction).progressViewStyle(.circular).controlSize(.small)
                Text(text).font(.system(size: 12))
                Button("Cancel") { share.cancel() }
                    .controlSize(.small)
                    .help("Stop preparing; nothing is shared")
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(.regularMaterial, in: .capsule)
            .padding(.top, DS.Space.m)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
        }
    }
}

/// Settings ▸ Sharing: the size and quality of Share…'s JPEGs, and whether they carry the location.
struct ShareSettingsView: View {
    let defaults: UserDefaults
    @State private var value: ShareSettings

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _value = State(initialValue: ShareSettings(defaults: defaults))
    }

    var body: some View {
        Form {
            Section {
                Picker("Size (long edge)", selection: $value.longEdge) {
                    ForEach(ShareSettings.longEdges, id: \.self) { Text("\($0) px").tag($0) }
                }
                .help("2048 px suits Messages and Mail; 4096 px fills a 4K screen")
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: Binding(get: { Double(value.quality) }, set: { value.quality = Int($0.rounded()) }),
                               in: Double(ShareSettings.qualities.lowerBound)...Double(ShareSettings.qualities.upperBound),
                               step: 1)
                        Text("\(value.quality)").monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                }
                Toggle("Include the location (GPS)", isOn: $value.includeLocation)
                    .help("Off: where the photo was taken stays private. Your name, copyright, caption and keywords go in either way")
            } footer: {
                Text("Share… (⌥⌘E) sends developed sRGB JPEGs of the selected photos: \(value.summary). "
                     + "For other formats and sizes, use File ▸ Export… (⌘E).")
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: value) { _, v in v.save(to: defaults) }
    }
}
