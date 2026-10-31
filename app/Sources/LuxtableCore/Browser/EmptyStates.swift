import Foundation

/// What the viewer says when there's no photo to show, and what it offers next
/// (kept out of the view so every case is tested).
public enum EmptyState: Equatable, Sendable {
    case loading
    /// No session open, recent sessions to pick from (listed under the message).
    case recents
    /// No session and no recents: the first run.
    case firstRun
    /// Every original of the open session is gone (the banner offers Locate Folder…).
    case originalsMissing
    /// The selected smart folder has no members yet.
    case emptySmartFolder(name: String, criteria: SmartCriteria)
    /// The library filter hides every photo.
    case noMatches
    /// The open session has no photos.
    case emptySession
    case selectPhoto

    public enum Action: Equatable, Sendable {
        case importCard, openFolder, clearFilters, showAllPhotos
        /// File ▸ New Session… (offered with no session open, when the store can make one).
        case newSession
        /// Sample photos in a separate demo window (first run, when the app can open one).
        case trySamples

        public var title: String {
            switch self {
            case .importCard: String(localized: "Import from Card…")
            case .openFolder: String(localized: "Open Folder…")
            case .clearFilters: String(localized: "Clear Filters")
            case .showAllPhotos: String(localized: "Show All Photos")
            case .newSession: String(localized: "New Session…")
            case .trySamples: String(localized: "Try with Sample Photos")
            }
        }
    }

    public var symbol: String {
        switch self {
        case .loading: "hourglass"
        case .recents: "rectangle.stack"
        case .firstRun: "camera.aperture"
        case .originalsMissing: "externaldrive.badge.questionmark"
        case .emptySmartFolder: "folder.badge.gearshape"
        case .noMatches: "line.3.horizontal.decrease.circle"
        case .emptySession: "sdcard"
        case .selectPhoto: "hand.point.up.left"
        }
    }

    public var title: String {
        switch self {
        case .loading: String(localized: "Opening session…")
        case .recents: String(localized: "Open a session")
        case .firstRun: String(localized: "Welcome to Luxtable")
        case .originalsMissing: String(localized: "This session’s photos aren’t there")
        case .emptySmartFolder(let name, _): String(localized: "Nothing in “\(name)” yet")
        case .noMatches: String(localized: "No photos match the filters")
        case .emptySession: String(localized: "This session is empty")
        case .selectPhoto: String(localized: "Select a photo")
        }
    }

    public var message: String {
        switch self {
        case .loading: ""
        case .recents: String(localized: "Pick one of your recent sessions, or bring in new photos.")
        case .firstRun:
            String(localized: "Insert a memory card and the import sheet opens by itself. Or open any folder of RAW files: Luxtable browses it in place and never moves your originals.")
        case .originalsMissing: String(localized: "Ratings and edits are kept. Locate the folder to see them again.")
        case .emptySmartFolder(_, let criteria): criteria.explanation
        case .noMatches: String(localized: "The rating, tag, pick or search filters hide every photo in this session.")
        case .emptySession: String(localized: "Insert a memory card to import, or open a folder of RAW files. You can also drag photos into the window.")
        case .selectPhoto: String(localized: "Click a thumbnail below, or press → to start culling. Press ? for all shortcuts.")
        }
    }

    public var actions: [Action] {
        switch self {
        case .loading, .originalsMissing, .selectPhoto: []
        case .recents, .firstRun, .emptySession: [.importCard, .openFolder]
        case .emptySmartFolder: [.showAllPhotos]
        case .noMatches: [.clearFilters]
        }
    }
}

extension AppModel {
    /// The viewer's empty state for the current session, filter and focus.
    public var emptyState: EmptyState {
        if isLoading { return .loading }
        if currentSession == nil { return sessionList.isEmpty ? .firstRun : .recents }
        if sessionOriginalsMissing { return .originalsMissing }
        if visiblePhotos.isEmpty {
            // Typed search text can be what hides everything: then it's the filters, not the folder.
            if let scope = filter.smartFolder, filter.text.isEmpty, let folder = smartFolders.folder(scope.id) {
                return .emptySmartFolder(name: folder.name, criteria: scope.criteria)
            }
            return filter.isActive ? .noMatches : .emptySession
        }
        return .selectPhoto
    }

    /// The empty state's buttons: with no session open (after Close Session too), New
    /// Session… comes first when the store can make one. The first run also offers the
    /// sample photos, last.
    public var emptyStateActions: [EmptyState.Action] {
        let state = emptyState
        let noSession = state == .recents || state == .firstRun
        let samples = state == .firstRun && mode == .live && openSamples != nil
        return (noSession && canCreateSession ? [.newSession] : []) + state.actions + (samples ? [.trySamples] : [])
    }

    /// An empty state's button. `.openFolder` shows the Open sheet when there are recents;
    /// without any it needs the folder panel: the view runs it and calls `openFolder(_:)`
    /// (returns false here).
    @discardableResult
    public func performEmptyStateAction(_ action: EmptyState.Action) -> Bool {
        switch action {
        case .importCard: sheet = .importCard(nil)
        case .openFolder: return beginOpen()
        case .clearFilters: clearFilters()
        case .showAllPhotos: selectSmartFolder(nil)
        case .newSession: beginNewSession()
        case .trySamples: openSamples?()
        }
        return true
    }

    /// Clear the search and the filters; a selected smart folder stays selected (its
    /// rules aren't a filter the user typed).
    public func clearFilters() {
        var cleared = PhotoFilter()
        cleared.smartFolder = filter.smartFolder
        filter = cleared
    }
}

extension SmartCriteria {
    /// What would appear in a folder with these rules, in a sentence.
    public var explanation: String {
        var parts: [String] = []
        switch (minRating.flatMap { $0 > 0 ? $0 : nil }, maxRating) {
        case (nil, 0?): parts.append(String(localized: "unrated"))
        case let (lo?, hi?) where lo == hi: parts.append(String(localized: "rated exactly \(lo)★"))
        case let (lo?, hi?): parts.append(String(localized: "rated \(lo)★ to \(hi)★"))
        case let (lo?, nil): parts.append(String(localized: "rated \(lo)★ or more"))
        case let (nil, hi?): parts.append(String(localized: "rated up to \(hi)★"))
        case (nil, nil): break
        }
        if !tags.isEmpty {
            let names = ColorTag.allCases.filter(tags.contains).map { $0.title.lowercased() }
            parts.append(String(localized: "tagged \(names.joined(separator: String(localized: " or ")))"))
        }
        switch pick {
        case .picked?: parts.append(String(localized: "picked"))
        case .rejected?: parts.append(String(localized: "rejected"))
        case PickState.none?: parts.append(String(localized: "neither picked nor rejected"))
        case nil: break
        }
        if let t = Self.trimmed(text) { parts.append(String(localized: "matching “\(t)”")) }
        if let c = Self.trimmed(camera) { parts.append(String(localized: "shot with a camera matching “\(c)”")) }
        if let l = Self.trimmed(lens) { parts.append(String(localized: "shot with a lens matching “\(l)”")) }
        let day = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        switch (dateFrom, dateTo) {
        case let (a?, b?): parts.append(String(localized: "taken \(day(a)) to \(day(b))"))
        case let (a?, nil): parts.append(String(localized: "taken on or after \(day(a))"))
        case let (nil, b?): parts.append(String(localized: "taken on or before \(day(b))"))
        case (nil, nil): break
        }
        switch (isoMin, isoMax) {
        case let (a?, b?): parts.append(String(localized: "at ISO \(String(a))–\(String(b))"))
        case let (a?, nil): parts.append(String(localized: "at ISO \(String(a)) or more"))
        case let (nil, b?): parts.append(String(localized: "at ISO \(String(b)) or less"))
        case (nil, nil): break
        }
        switch edited {
        case true?: parts.append(String(localized: "edited"))
        case false?: parts.append(String(localized: "not edited yet"))
        case nil: break
        }
        let words = keywords.compactMap(Self.trimmed)
        if !words.isEmpty {
            parts.append((words.count == 1 ? String(localized: "with the keyword ") : String(localized: "with the keywords "))
                + words.map { "“\($0)”" }.joined(separator: ", "))
        }
        guard !parts.isEmpty else { return String(localized: "Every photo in the session appears here.") }
        return String(localized: "Photos \(parts.joined(separator: ", ")) appear here as soon as there are any.")
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}
