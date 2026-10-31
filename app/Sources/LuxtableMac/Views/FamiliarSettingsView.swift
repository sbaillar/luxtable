import LuxtableCore
import LuxtableUI
import SwiftUI

/// Settings › Familiar: the layout, the keyboard set and the names, each chosen on its own
/// (Capture One panels with Lightroom keys is fine). The look never changes.
struct FamiliarSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: $settings.layoutPreset) {
                    ForEach(LayoutPreset.allCases) { l in
                        PresetRow(title: l.title, summary: l.summary).tag(l)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Where the tool panels and Copy / Apply sit.").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
            }

            Section {
                Picker("Keyboard shortcuts", selection: Binding(get: { settings.keyPreset },
                                                                set: { settings.useKeyPreset($0) })) {
                    ForEach(KeyPreset.allCases) { k in
                        PresetRow(title: k.title, summary: k.summary).tag(k)
                    }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Text(FamiliarText.keysStatus(settings.keyPreset, settings.keyBindings))
                        .font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                    Spacer()
                    Button("Reset to \(settings.keyPreset.title)") { settings.useKeyPreset(settings.keyPreset) }
                        .disabled(settings.keyPreset.changes(in: settings.keyBindings) == 0)
                }
            } footer: {
                Text("Independent of the layout. Change single keys in the Shortcuts tab.")
                    .font(DS.Font.caption).foregroundStyle(DS.textSecondary)
            }

            Section {
                Picker("Names", selection: $settings.namePreset) {
                    Text("Follow the layout (\(settings.layoutPreset.names.title))").tag(NameSet?.none)
                    ForEach(NameSet.allCases) { n in Text(n.title).tag(NameSet?.some(n)) }
                }
                Text(FamiliarText.namesExample(settings.names))
                    .font(DS.Font.caption).foregroundStyle(DS.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}

/// The first-run choice: one pick sets the layout, its keys and its names.
struct FamiliarChoiceList: View {
    @Binding var selection: LayoutPreset
    /// First run only: an "I'm new to photo editing" row first (starts in Simple mode).
    var newToEditing: Binding<Bool>?

    var body: some View {
        let newcomer = newToEditing?.wrappedValue ?? false
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let newToEditing {
                row(title: FamiliarText.newcomerTitle, detail: FamiliarText.newcomerSummary, selected: newcomer) {
                    newToEditing.wrappedValue = true
                }
            }
            ForEach(LayoutPreset.allCases) { l in
                row(title: FamiliarText.choiceTitle(l, offersNewcomer: newToEditing != nil),
                    detail: "\(l.summary). Keys: \(KeyPreset(layout: l).summary).",
                    selected: selection == l && !newcomer) { selection = l }
            }
        }
    }

    private func row(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? DS.accent : DS.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.label.weight(.semibold)).foregroundStyle(DS.text)
                    Text(detail)
                        .font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.s)
            .background(selected ? DS.accent.opacity(0.12) : Color.primary.opacity(0.04),
                        in: .rect(cornerRadius: DS.Radius.m))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PresetRow: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(summary).font(DS.Font.caption).foregroundStyle(DS.textSecondary)
        }
    }
}

/// The Familiar pane's wording (kept out of the view, unit-tested).
enum FamiliarText {
    static func keysStatus(_ preset: KeyPreset, _ bindings: KeyBindings) -> String {
        let n = preset.changes(in: bindings)
        return n == 0 ? String(localized: "\(preset.title) keys, unchanged")
            : n == 1 ? String(localized: "\(preset.title) keys + 1 of your own change")
            : String(localized: "\(preset.title) keys + \(n) of your own changes")
    }

    static func namesExample(_ n: NameSet) -> String {
        "\(n.copyButton) / \(n.applyButton) · \(n.layers) · \(n.styles) · \(n.newVariant)"
    }

    /// The status bar's reminder of what is in use.
    static func statusLine(_ layout: LayoutPreset, _ keys: KeyPreset) -> String {
        layout.rawValue == keys.rawValue ? String(localized: "\(layout.title) layout and keys")
            : String(localized: "\(layout.title) layout · \(keys.title) keys")
    }

    /// `offersNewcomer`: the first-run list, whose own row is for "nothing yet".
    static func choiceTitle(_ l: LayoutPreset, offersNewcomer: Bool = false) -> String {
        l == .luxtable && !offersNewcomer ? String(localized: "Luxtable, or nothing yet") : l.title
    }

    static let newcomerTitle = String(localized: "Nothing yet: I'm new to photo editing")
    static let newcomerSummary = String(localized: "Start in Simple mode: an Auto button, looks and a few easy sliders. Every tool is one switch away (View ▸ Simple Mode).")
}
