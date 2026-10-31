import CoreGraphics
import Foundation
import Observation

/// File ▸ Import from Photos Library… and an iPhone or iPad in the import sheet: list the
/// source's photos (Photos: all, one album or a date range), tick the ones to bring in, copy
/// them into a staging folder (`ExternalStager`), then hand that folder to the card import
/// (`onStaged`), which dedupes against the library and copies, verifies and registers into
/// a new or existing session. Nothing is ever written to the source.
@MainActor @Observable
public final class ExternalImportModel: Identifiable {
    public enum Phase: Equatable, Sendable {
        case loading
        /// Access refused or the device can't be read: why, in words.
        case unavailable(String)
        case ready
        case staging
        /// Some originals couldn't be copied; the rest are staged and can go on.
        case stagedWithProblems(StageResult)
        case failed(String)
    }

    public nonisolated let id = UUID()
    public let source: any ExternalPhotoSource
    public private(set) var phase: Phase = .loading
    public private(set) var albums: [ExternalAlbum] = []
    public private(set) var scope: ExternalScope = .all
    public private(set) var listing = ExternalListing(items: [])
    /// Item ids the user unticked.
    public private(set) var excluded: Set<String> = []
    public private(set) var done = 0
    public private(set) var doneBytes: Int64 = 0
    public private(set) var total = 0

    @ObservationIgnored private let stager: ExternalStager
    @ObservationIgnored private let stagingRoot: URL
    @ObservationIgnored private let onStaged: @MainActor (URL) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let thumbs = NSCache<NSString, CGImageBox>()

    public init(source: any ExternalPhotoSource, stagingRoot: URL = ExternalStaging.root,
                stager: ExternalStager = ExternalStager(), onStaged: @escaping @MainActor (URL) -> Void) {
        self.source = source
        self.stagingRoot = stagingRoot
        self.stager = stager
        self.onStaged = onStaged
        thumbs.totalCostLimit = 64 << 20
    }

    public var title: String { source.isPhotosLibrary ? String(localized: "Import from Photos Library") : String(localized: "Import from \(source.name)") }

    /// Where the originals stay, for "they stay in …".
    public var origin: String { source.isPhotosLibrary ? String(localized: "your Photos library") : String(localized: "the \(source.name)") }

    public var items: [ExternalItem] { listing.items }

    // MARK: Loading

    /// Ask for access (or open the device), then list the albums and the photos.
    public func load() async {
        phase = .loading
        do {
            try await source.prepare()
        } catch {
            phase = .unavailable(error.localizedDescription)
            return
        }
        albums = await source.albums()
        await reload()
    }

    /// Show all photos, one album, or a date range.
    public func setScope(_ s: ExternalScope) async {
        guard s != scope, !isBusy else { return }
        scope = s
        await reload()
    }

    private func reload() async {
        generation += 1
        let g = generation
        phase = .loading
        do {
            let l = try await source.list(scope)
            guard g == generation else { return }
            listing = l
            excluded = []
            phase = .ready
        } catch {
            guard g == generation else { return }
            listing = ExternalListing(items: [])
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Selection

    public func isSelected(_ i: ExternalItem) -> Bool { !excluded.contains(i.id) }

    public func toggle(_ i: ExternalItem) {
        guard !isBusy else { return }
        if excluded.contains(i.id) { excluded.remove(i.id) } else { excluded.insert(i.id) }
    }

    public func selectAll() { if !isBusy { excluded = [] } }
    public func selectNone() { if !isBusy { excluded = Set(items.map(\.id)) } }

    public var selected: [ExternalItem] { items.filter(isSelected) }

    /// "212 photos · 3 videos not imported · 2 PNG files not imported".
    public var summaryLine: String {
        var parts = [ImportWording.items(photos: items.count, videos: 0)]
        if listing.videos > 0 {
            parts.append(listing.videos == 1 ? String(localized: "1 video not imported")
                         : String(localized: "\(listing.videos) videos not imported"))
        }
        if !listing.unsupported.isEmpty {
            let n = listing.unsupported.count
            parts.append(n == 1 ? String(localized: "1 file in other formats not imported")
                         : String(localized: "\(n) files in other formats not imported"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Copying out

    public var isBusy: Bool { phase == .staging || phase == .loading }
    public var canStart: Bool { phase == .ready && !selected.isEmpty }

    /// Copy the ticked originals into a fresh staging folder; when every one made it, the
    /// import sheet opens on it.
    public func start() {
        guard canStart else { return }
        let picked = selected
        let folder = ExternalStaging.makeFolder(for: source.name, root: stagingRoot)
        ExternalStaging.cleanUp(keeping: ImportRegistry.shared.running.compactMap(\.volume), root: stagingRoot)
        total = picked.count
        done = 0
        doneBytes = 0
        phase = .staging
        let source = source
        let stager = stager
        task = Task { [weak self] in
            do {
                let r = try await stager.stage(picked, from: source, into: folder) { d, b in
                    self?.done = d
                    self?.doneBytes = b
                }
                self?.finish(r)
            } catch {
                try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
                self?.phase = error is CancellationError ? .ready : .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ r: StageResult) {
        if r.staged.isEmpty {
            try? FileManager.default.removeItem(at: r.folder.deletingLastPathComponent())
            let why = r.failed.first?.reason ?? String(localized: "Nothing was copied.")
            phase = .failed(String(localized: "None of the photos could be copied from \(origin). \(why)"))
        } else if r.failed.isEmpty {
            phase = .ready
            onStaged(r.folder)
        } else {
            phase = .stagedWithProblems(r)
        }
    }

    /// Go on with what was copied (after `stagedWithProblems`).
    public func continueWithStaged() {
        guard case .stagedWithProblems(let r) = phase else { return }
        phase = .ready
        onStaged(r.folder)
    }

    /// Stop copying out: what was staged is dropped, nothing at the source changes.
    public func cancel() { task?.cancel() }

    /// Await the copy (tests).
    public func wait() async { await task?.value }

    // MARK: Thumbnails

    public func cachedThumbnail(_ i: ExternalItem) -> CGImage? { thumbs.object(forKey: i.id as NSString)?.image }

    public func thumbnail(_ i: ExternalItem, maxPixelSize: Int = 256) async -> CGImage? {
        if let hit = cachedThumbnail(i) { return hit }
        guard let img = await source.thumbnail(for: i, maxPixelSize: maxPixelSize), !Task.isCancelled else { return nil }
        thumbs.setObject(CGImageBox(img), forKey: i.id as NSString, cost: img.bytesPerRow * img.height)
        return img
    }
}

extension ImportWording {
    /// The import's last line when it came from Photos or a device (instead of the card's).
    public static let stagedLine = String(localized: """
        The originals are still in Photos or on your device; nothing there was changed. \
        Luxtable's temporary copies are removed when you close this sheet.
        """)
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

extension ExternalImportModel: Equatable {
    public nonisolated static func == (a: ExternalImportModel, b: ExternalImportModel) -> Bool { a === b }
}

extension AppModel {
    /// Photos and iPhone import copy through lt-import (live mode only).
    public var canImportExternal: Bool { mode == .live && importer is any ImportVerifying }

    /// File ▸ Import from Photos Library…
    public func showPhotosLibraryImport(source: any ExternalPhotoSource = PhotoKitLibrary()) {
        showExternalImport(source)
    }

    /// The import sheet's iPhone or iPad source.
    public func showExternalImport(_ source: any ExternalPhotoSource) {
        guard canImportExternal else { return }
        let m = ExternalImportModel(source: source) { [weak self] folder in self?.sheet = .importCard(folder) }
        sheet = .externalImport(m)
    }

    /// A sheet closed: staged copies no running import reads are removed.
    /// (Staging is Luxtable's own temporary copy: the originals stay in Photos or on the device.)
    func cleanUpStaging(root: URL = ExternalStaging.root) {
        ExternalStaging.cleanUp(keeping: ImportRegistry.shared.running.compactMap(\.volume), root: root)
    }
}
