import Foundation

/// One interactive control as VoiceOver and the audit test see it (N17).
public struct AccessibleControl: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var hint: String?

    public init(_ id: String, _ label: String, hint: String? = nil) {
        self.id = id
        self.label = label
        self.hint = hint
    }
}

/// Window toolbar controls. Views read their labels/hints from here, so the
/// audit test covers exactly what is on screen.
public enum ToolbarControl: String, CaseIterable, Sendable {
    case session, newSession, closeSession, importCard, viewerMode, gridMode, beforeAfter, compare, showSelection
    case undo, redo, copy, copyOptions, apply, auto, optimize, ask, aiCull, archive

    @MainActor
    public func control(_ model: AppModel) -> AccessibleControl {
        let b = model.settings.keyBindings
        switch self {
        case .session:
            return .init(rawValue, String(localized: "Session: \(model.currentSession?.name ?? String(localized: "none"))"),
                         hint: String(localized: "Switch to another session, create one, or close this one"))
        case .newSession:
            return .init(rawValue, String(localized: "New session"), hint: CommandCatalog.help(.newSession, model: model))
        case .closeSession:
            return .init(rawValue, model.currentSession.map { String(localized: "Close session \($0.name)") } ?? String(localized: "Close session"),
                         hint: CommandCatalog.help(.closeSession, model: model))
        case .importCard:
            let verifies = model.importer is any ImportVerifying
            return .init(rawValue, ToolbarHelp.importTitle(mode: model.mode, verifies: verifies),
                         hint: ToolbarHelp.importButton(mode: model.mode, verifies: verifies))
        case .viewerMode: return .init(rawValue, String(localized: "Viewer"), hint: ToolbarHelp.viewerGrid(b))
        case .gridMode: return .init(rawValue, String(localized: "Grid"), hint: ToolbarHelp.viewerGrid(b))
        case .beforeAfter: return .init(rawValue, String(localized: "Before and after"), hint: ToolbarHelp.beforeAfter(b))
        case .compare:
            return .init(rawValue, model.viewer.state.comparePinned == nil ? String(localized: "Compare") : String(localized: "Stop comparing"),
                         hint: ToolbarHelp.compare(b))
        case .showSelection: // [multiview]
            return .init(rawValue, model.settings.showSelectionInViewer ? String(localized: "Showing selection in viewer") : String(localized: "Show selection in viewer"),
                         hint: ToolbarHelp.showSelection)
        case .undo:
            return .init(rawValue, model.history.undoLabel.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo"),
                         hint: model.history.canUndo ? "⌘Z" : String(localized: "Nothing to undo"))
        case .redo:
            return .init(rawValue, model.history.redoLabel.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo"),
                         hint: model.history.canRedo ? "⇧⌘Z" : String(localized: "Nothing to redo"))
        case .copy: return .init(rawValue, String(localized: "Copy adjustments"), hint: model.settings.copyMode == .edited ? String(localized: "Copy what was edited on this photo (⇧⌘C)") : String(localized: "Copy the ticked adjustments from this photo (⇧⌘C)"))
        case .copyOptions: return .init(rawValue, String(localized: "Copy options"), hint: String(localized: "Choose which adjustments Copy and Apply use"))
        case .apply: return .init(rawValue, String(localized: "Apply adjustments"), hint: model.clipboardSummary)
        case .auto: return .init(rawValue, String(localized: "Auto adjust"), hint: ToolbarHelp.autoAdjust())
        case .optimize:
            let n = model.optimizeTargets.count
            return .init(rawValue, n > 1 ? String(localized: "AI Optimize \(n) photos") : String(localized: "AI Optimize"), hint: ToolbarHelp.aiOptimize())
        case .ask:
            return .init(rawValue, String(localized: "Edit with words"),
                         hint: String(localized: "Type an edit like “warmer and a bit brighter” (⌘K); ⌘Z undoes it"))
        case .aiCull:
            if let p = model.cullProgress {
                return .init(rawValue, String(localized: "AI Cull, \(p.done) of \(p.total)"), hint: String(localized: "Scoring on this Mac"))
            }
            return .init(rawValue, String(localized: "AI Cull"), hint: String(localized: "Suggest picks and rejects on this Mac; ⌘Z undoes it"))
        case .archive:
            return .init(rawValue, ArchiveDisplay.accessibilityLabel(model.archiveStatus),
                         hint: ArchiveDisplay.explanation(model.archiveStatus.state))
        }
    }
}

/// Filter/sort bar controls (the bar lays out `FilterBarControl.all`).
public enum FilterBarControl: Hashable, Sendable {
    case star(Int), unrated, pick(PhotoFilter.PickFilter), tag(ColorTag), missing, search, clear, sort

    /// Controls shown for this state (Missing only when something is missing; Clear only when filtered).
    public static func all(filter: PhotoFilter, missingCount: Int, compact: Bool) -> [FilterBarControl] {
        var out: [FilterBarControl] = (1...5).map { .star($0) } + [.unrated]
        out += PhotoFilter.barPickOptions.map { .pick($0) }
        out += ColorTag.allCases.filter { $0 != .none }.map { .tag($0) }
        if missingCount > 0 || filter.missingOnly { out.append(.missing) }
        if !compact { out.append(.search) }
        if filter.isActive { out.append(.clear) }
        out.append(.sort)
        return out
    }

    public func control(filter: PhotoFilter, missingCount: Int, sort: PhotoSort) -> AccessibleControl {
        switch self {
        case .star(let n):
            let on = filter.minRating == n
            return .init("star\(n)", n == 1 ? String(localized: "1 star or more") : String(localized: "\(n) stars or more"),
                         hint: on ? String(localized: "Selected; activate again to clear") : String(localized: "Show photos rated \(n) or more"))
        case .unrated: return .init("unrated", String(localized: "Unrated"), hint: String(localized: "Only photos with no stars"))
        case .pick(let p): return .init("pick-\(p.rawValue)", String(localized: "Flag: \(p.rawValue)"), hint: String(localized: "Filter by pick flag"))
        case .tag(let t):
            return .init("tag-\(t.name)", String(localized: "\(t.title) tag"), hint: String(localized: "Only \(t.title.lowercased())-tagged photos"))
        case .missing:
            return .init("missing", MissingActions.filterTitle(count: missingCount),
                         hint: String(localized: "Photos whose files were moved or deleted outside Luxtable"))
        case .search: return .init("search", String(localized: "Search filenames"), hint: nil)
        case .clear: return .init("clear", filter.activeCriteria == 1 ? String(localized: "Clear 1 filter") : String(localized: "Clear \(filter.activeCriteria) filters"))
        case .sort: return .init("sort", String(localized: "Sort by \(sort.rawValue)"), hint: String(localized: "Change the sort order"))
        }
    }

    /// What activating the control does to the filter.
    public func apply(to filter: inout PhotoFilter) {
        switch self {
        case .star(let n): filter.toggleMinRating(n)
        case .unrated: filter.toggleUnrated()
        case .pick(let p): filter.pick = p
        case .tag(let t): filter.toggleTag(t)
        case .missing: filter.missingOnly.toggle()
        case .clear: filter = PhotoFilter()
        case .search, .sort: break
        }
    }
}

/// Missing-originals UI copy and actions.
public enum MissingActions {
    public static func filterTitle(count: Int) -> String { String(localized: "Missing (\(count.formatted()))") }

    public static func controls(selected: Int) -> [AccessibleControl] {
        [.init("remove", selected == 1 ? String(localized: "Remove 1 missing photo") : String(localized: "Remove \(selected) missing photos"),
               hint: String(localized: "Forget these photos' ratings and edits. Files are never touched.")),
         .init("locate", String(localized: "Locate…"), hint: String(localized: "Point Luxtable at the moved file"))]
    }

    /// Remove targets: the selected photos the store verified missing, on a drive that is
    /// connected (a photo whose drive dropped off is never removable).
    @MainActor
    public static func removable(_ model: AppModel) -> [PhotoID] {
        model.selectedIDs.filter(model.canRemoveMissing)
    }

    /// The confirmation before Remove: it forgets ratings and edits for good.
    public static func confirmRemove(count: Int) -> (title: String, message: String, button: String) {
        let photos = count == 1 ? String(localized: "\(count.formatted()) photo") : String(localized: "\(count.formatted()) photos")
        return (String(localized: "Remove \(photos) from the session?"),
                String(localized: "This deletes ratings and edits for \(photos). The files themselves are never touched."),
                String(localized: "Remove"))
    }

    /// Selected missing photos whose only copy is inside the session store (R4-M5).
    @MainActor
    public static func restorable(_ model: AppModel) -> [PhotoID] {
        model.selectedIDs.filter { model.photo($0)?.copyInStore == true }
    }

    /// Selected "File changed" photos (R4-H3).
    @MainActor
    public static func changed(_ model: AppModel) -> [PhotoID] {
        model.selectedIDs.filter { model.photo($0)?.fileChanged == true }
    }

    public static let restoreToFolder = AccessibleControl(
        "restoreToFolder", String(localized: "Restore to Folder"),
        hint: String(localized: "Move the only copy, kept inside Luxtable's session, back into the folder"))
    public static let restorePrevious = AccessibleControl(
        "restorePrevious", String(localized: "Restore Previous"),
        hint: String(localized: "This file replaced another photo: put back that photo's ratings and edits"))
    public static let keepAsNew = AccessibleControl(
        "keepAsNew", String(localized: "Keep as New"), hint: String(localized: "Treat the file as the new photo it is"))

    public static func badge(_ p: Photo, missing: Bool = false) -> String? {
        if p.isMissing || missing { return String(localized: "Missing") }
        if p.fileChanged { return String(localized: "File changed") }
        return nil
    }
}

/// First-open progress copy (R3-M2).
public enum OpenProgressText {
    public static func title(folder: URL?) -> String { String(localized: "Opening \(folder?.lastPathComponent ?? String(localized: "folder"))") }

    public static func phase(_ p: OpenProgress) -> String {
        switch p.phase {
        case .scanning: p.total > 0 ? String(localized: "Scanning… \(p.done.formatted()) files") : String(localized: "Scanning…")
        case .registering: String(localized: "Registering \(p.done.formatted()) of \(p.total.formatted())")
        case .hashing:
            String(localized: "Verifying files in the background… \(Int((p.fraction * 100).rounded()))% (\(p.done.formatted()) of \(p.total.formatted()))")
        case .updated: String(localized: "Updated")
        }
    }

    /// The grid is usable while hashing continues: only scanning/registering block.
    public static func blocksBrowsing(_ p: OpenProgress) -> Bool { p.phase != .hashing }

    public static let cancel = AccessibleControl("cancelOpen", String(localized: "Cancel opening"), hint: String(localized: "Stop; nothing is written to the folder"))
}

/// Tool-tab strip and panel-header controls.
public enum ToolStripControl {
    /// `title`: the workspace's name for the tab (custom or renamed).
    public static func tab(_ t: ToolTab, title: String? = nil, selected: Bool) -> AccessibleControl {
        let name = title ?? t.title
        return .init("tab-\(t.rawValue)", String(localized: "\(name) tools"), hint: selected ? String(localized: "Selected") : String(localized: "Show the \(name) panels"))
    }

    /// The strip's + (and an empty tab's Add Tool button).
    public static func addTool(tabTitle: String) -> AccessibleControl {
        .init("addtool", String(localized: "Add or remove tools"), hint: String(localized: "Checked tools are in \(tabTitle); choosing one removes it"))
    }

    /// The » menu holding the tabs that don't fit.
    public static func moreTabs(_ count: Int) -> AccessibleControl {
        .init("moretabs", String(localized: "More tool tabs"), hint: count == 1 ? String(localized: "1 more tab") : String(localized: "\(count) more tabs"))
    }

    /// A panel header's ⋯ menu.
    public static func panelMenu(_ p: ToolPanelID) -> AccessibleControl {
        .init("panelmenu-\(p.rawValue)", String(localized: "\(p.title) options"), hint: String(localized: "Remove, move or add tools"))
    }

    /// Arranging a tool within its tab (context menu items and VoiceOver actions).
    public static func arrange(_ p: ToolPanelID, tabTitle: String) -> [AccessibleControl] {
        [.init("moveup-\(p.rawValue)", String(localized: "Move Up"), hint: String(localized: "Move \(p.title) up in \(tabTitle)")),
         .init("movedown-\(p.rawValue)", String(localized: "Move Down"), hint: String(localized: "Move \(p.title) down in \(tabTitle)")),
         .init("remove-\(p.rawValue)", String(localized: "Remove from \(tabTitle)"), hint: String(localized: "The Tools menu still reaches \(p.title)"))]
    }

    public static func panelHeader(_ p: ToolPanelID, collapsed: Bool, favorite: Bool) -> [AccessibleControl] {
        var out = [AccessibleControl("disclose-\(p.rawValue)", PanelChrome.disclosureLabel(p.title, collapsed: collapsed),
                                     hint: collapsed ? String(localized: "Expand") : String(localized: "Collapse")),
                   .init("favorite-\(p.rawValue)", favorite ? String(localized: "Remove \(p.title) from Favorites") : String(localized: "Add \(p.title) to Favorites"))]
        if let g = p.group {
            out += [.init("copy-\(p.rawValue)", String(localized: "Copy \(g.title)"), hint: String(localized: "Copy only this tool's settings")),
                    .init("apply-\(p.rawValue)", String(localized: "Apply \(g.title)"), hint: String(localized: "Apply only this tool's settings to the selection")),
                    .init("reset-\(p.rawValue)", String(localized: "Reset \(g.title)"))]
        }
        return out
    }
}

/// The AI Changes list's controls.
public enum AIChangesControl {
    public static let close = AccessibleControl("aiChangesClose", String(localized: "Close AI Changes"), hint: String(localized: "Esc"))

    @MainActor
    public static func undoAll(_ model: AppModel) -> AccessibleControl {
        .init("aiChangesUndoAll", model.undoAllAIChangesTitle,
              hint: String(localized: "Put every setting AI changed back to its value before; ⌘Z brings them back"))
    }

    /// A line: activating it shows the tool in the sidebar.
    public static func row(_ r: AIChangeRow) -> AccessibleControl {
        .init("aiChange-\(r.field.panel.rawValue)-\(r.field.name)", r.accessibilityLabel, hint: String(localized: "Show it in the tools"))
    }

    public static func undo(_ r: AIChangeRow) -> AccessibleControl {
        .init("aiChangeUndo-\(r.field.panel.rawValue)-\(r.field.name)", String(localized: "Undo AI change to \(r.setting)"),
              hint: r.canUndo ? String(localized: "Put \(r.setting) back to its value before AI") : AIChangeText.cantUndo)
    }
}
