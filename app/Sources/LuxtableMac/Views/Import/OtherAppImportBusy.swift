import LuxtableCore
import LuxtableUI
import SwiftUI

/// The busy line of an import-from-another-app sheet: a spinner beside `text`, or, once
/// the work says how far it is, a bar with what it is doing under it.
struct OtherAppImportBusy: View {
    let text: LocalizedStringKey
    let work: OtherAppImportWork

    var body: some View {
        if let step = work.step {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(text).font(DS.Font.label).foregroundStyle(DS.text)
                if let fraction = step.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(step.line).font(DS.Font.caption).foregroundStyle(DS.textSecondary).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step.line)
        } else {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(text).font(DS.Font.label).foregroundStyle(DS.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
        }
    }
}

/// Cancel while such an import runs: it stops only before anything is written.
struct OtherAppImportCancel: View {
    let work: OtherAppImportWork

    var body: some View {
        Button("Cancel", role: .cancel) { work.cancel() }
            .keyboardShortcut(.cancelAction)
            .disabled(!work.canCancel)
            .help("Stops the import before anything is written. Once it is writing, it finishes.")
    }
}
