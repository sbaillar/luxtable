import LuxtableCore
import LuxtableUI
import SwiftUI

/// Photos library or iPhone/iPad import: pick the photos, copy them out, then the regular
/// import sheet takes over (destination, rename, dedupe, verified copy). Logic in `ExternalImportModel`.
struct ExternalImportSheet: View {
    let app: AppModel
    @Bindable var model: ExternalImportModel
    @State private var albumID = ""
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var scopeKind = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 920, height: 640)
        .background(DS.panelBackground)
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: model.source.isPhotosLibrary ? "photo.on.rectangle" : "iphone")
                .font(.system(size: 22))
                .foregroundStyle(DS.accent)
                .frame(width: 44, height: 44)
                .background(DS.accent.opacity(0.14), in: .rect(cornerRadius: DS.Radius.l))
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(model.title).font(.system(size: 15, weight: .semibold))
                Text(model.phase == .ready ? model.summaryLine
                     : String(localized: "Originals are copied; \(model.origin) is never changed."))
                    .font(DS.Font.label).foregroundStyle(DS.textSecondary)
            }
            Spacer()
            scopePicker
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder private var scopePicker: some View {
        HStack(spacing: DS.Space.s) {
            Picker("Show", selection: $scopeKind) {
                Text("All Photos").tag(0)
                if model.source.isPhotosLibrary, !model.albums.isEmpty { Text("Album").tag(1) }
                Text("Date Range").tag(2)
            }
            .fixedSize()
            if scopeKind == 1 {
                Picker("Album", selection: $albumID) {
                    ForEach(model.albums) { a in Text("\(a.title) (\(a.count))").tag(a.id) }
                }
                .labelsHidden().frame(maxWidth: 220)
            } else if scopeKind == 2 {
                DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden()
                Text("to").foregroundStyle(DS.textSecondary)
                DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden()
            }
        }
        .disabled(model.isBusy)
        .onChange(of: scopeKind) { applyScope() }
        .onChange(of: albumID) { applyScope() }
        .onChange(of: from) { applyScope() }
        .onChange(of: to) { applyScope() }
    }

    private func applyScope() {
        let scope: ExternalScope
        switch scopeKind {
        case 1:
            if albumID.isEmpty, let first = model.albums.first { albumID = first.id }
            scope = albumID.isEmpty ? .all : .album(albumID)
        case 2: scope = .dates(from: from, to: to)
        default: scope = .all
        }
        Task { await model.setScope(scope) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView(model.source.isPhotosLibrary ? "Reading your Photos library…" : "Reading \(model.source.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let why), .failed(let why):
            message(title: model.source.isPhotosLibrary ? String(localized: "Can’t read Photos")
                        : String(localized: "Can’t read \(model.source.name)"), text: why,
                    symbol: "exclamationmark.triangle", action: (String(localized: "Try Again"), { Task { await model.load() } }))
        case .staging:
            VStack(spacing: DS.Space.m) {
                ProgressView(value: Double(model.done), total: Double(max(model.total, 1))).frame(width: 360)
                Text("Copying \(model.done) of \(model.total) originals (\(Formatters.bytes(model.doneBytes)))…")
                    .foregroundStyle(DS.textSecondary)
                Text("Each copy is checked before the import goes on. Nothing in \(model.origin) is changed.")
                    .font(DS.Font.caption).foregroundStyle(DS.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stagedWithProblems(let r):
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label("\(r.failed.count) of \(r.failed.count + r.staged.count) originals couldn’t be copied",
                      systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                ForEach(r.failed.prefix(10), id: \.self) { f in
                    Text("\(f.filename): \(f.reason)").font(DS.Font.caption).foregroundStyle(DS.textSecondary)
                }
                Text("They stay in \(model.origin). Continue to import the \(r.staged.count) that were copied.")
                    .font(DS.Font.label)
            }
            .frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready where model.items.isEmpty:
            message(title: String(localized: "No photos here"),
                    text: String(localized: "Nothing to import in this selection. \(model.summaryLine)"),
                    symbol: "photo.on.rectangle.angled", action: nil)
        case .ready:
            grid
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Text("\(model.selected.count) of \(model.items.count) selected")
                    .font(DS.Font.label).foregroundStyle(DS.textSecondary)
                Spacer()
                Button("Select All") { model.selectAll() }
                Button("None") { model.selectNone() }
            }
            .buttonStyle(.borderless).font(DS.Font.label)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: DS.Space.s)], spacing: DS.Space.s) {
                    ForEach(model.items) { item in
                        Button { model.toggle(item) } label: {
                            ExternalTile(model: model, item: item, selected: model.isSelected(item))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.isSelected(item) ? String(localized: "\(item.filename), selected")
                                            : String(localized: "\(item.filename), not selected"))
                        .accessibilityAddTraits(model.isSelected(item) ? .isSelected : [])
                    }
                }
                .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.m)
            }
        }
        .background(DS.viewerBackground)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            Text("Next: choose the session. Photos already in your library are found and skipped.")
                .font(DS.Font.label).foregroundStyle(DS.textSecondary).lineLimit(1)
            Spacer()
            switch model.phase {
            case .staging:
                Button("Stop") { model.cancel() }.keyboardShortcut(.cancelAction)
            case .stagedWithProblems:
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.continueWithStaged() }.keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Continue with \(ImportWording.items(photos: model.selected.count, videos: 0))…") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(DS.Space.m)
        .frame(height: 64)
    }

    private func message(title: String, text: String, symbol: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(DS.textTertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(DS.Font.label).foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if let action { Button(action.0, action: action.1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExternalTile: View {
    let model: ExternalImportModel
    let item: ExternalItem
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.cellBackground)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "photo").font(.system(size: 22, weight: .light)).foregroundStyle(DS.textTertiary)
                        }
                    }
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: DS.Radius.s))
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? DS.accent : DS.textSecondary)
                    .background(Circle().fill(.black.opacity(selected ? 0 : 0.25)))
                    .padding(DS.Space.xs)
                if item.kind == .raw {
                    Text("RAW").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule).foregroundStyle(.white)
                        .padding(DS.Space.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(selected ? DS.accent : .clear, lineWidth: 1.5))
            Text(item.filename).font(DS.Font.caption).lineLimit(1)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(DS.Font.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
        }
        .opacity(selected ? 1 : 0.7)
        .task(id: item.id) {
            image = model.cachedThumbnail(item)
            if image == nil { image = await model.thumbnail(item) }
        }
        .contentShape(.rect)
    }
}
