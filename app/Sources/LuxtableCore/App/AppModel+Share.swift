import Foundation

// MARK: - Share…

extension AppModel {
    /// Share… (⌥⌘E): render the selection (focused if none) as JPEGs with the Sharing
    /// settings, then show the share picker. Videos are left out; one share at a time.
    public func beginShare() {
        if share?.isBusy == true { return }
        let items = exportItems
        guard !items.isEmpty else {
            show(Toast(exportSkippedVideos > 0 ? "Videos aren't shared. Select photos to share" : "Select photos to share",
                       symbol: "square.and.arrow.up", isError: true))
            return
        }
        let defaults = settings.userDefaults
        let model = ShareModel(items: items, settings: ShareSettings(defaults: defaults), service: exporter,
                               credit: ExportRecipeStore(defaults: defaults).credit, folders: shareFolders,
                               presenter: sharePresenter)
        model.report = { [weak self] message, isError in
            self?.show(Toast(message, symbol: isError ? "exclamationmark.triangle" : "square.and.arrow.up", isError: isError))
        }
        share = model
        model.start()
    }

    /// Whether Share… can start now (a photo with a file is selected, no share is rendering).
    public var canShare: Bool {
        share?.isBusy != true && selectedIDs.contains { photo($0).map { !$0.isVideo && $0.url != nil } ?? false }
    }
}
