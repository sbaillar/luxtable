import CoreGraphics
import Foundation
import Photos
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Apple Photos library as an `ExternalPhotoSource` (PhotoKit). Read only: assets are
/// fetched, their original resource is streamed with `PHAssetResourceManager` (downloading it
/// from iCloud when the library keeps only optimized copies), and nothing is ever changed in
/// the library. Not unit-tested (needs a real library and the user's permission); the choices
/// it makes are `PhotoResourceChoice`, `ExternalListing.sorting` and `ExternalScope`, which are.
public final class PhotoKitLibrary: ExternalPhotoSource {
    public init() {}

    public var name: String { String(localized: "Photos Library") }
    public var isPhotosLibrary: Bool { true }

    public static let deniedMessage = String(localized: """
        Luxtable isn’t allowed to read your Photos library. Turn it on in System Settings \
        \u{25B8} Privacy & Security \u{25B8} Photos, then try again.
        """)

    public func prepare() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch status {
        case .authorized, .limited: return
        default: throw ExternalSourceError.accessDenied(Self.deniedMessage)
        }
    }

    public func albums() async -> [ExternalAlbum] {
        await Task.detached(priority: .userInitiated) {
            func albums(_ result: PHFetchResult<PHAssetCollection>) -> [ExternalAlbum] {
                var out: [ExternalAlbum] = []
                result.enumerateObjects { c, _, _ in
                    let n = PHAsset.fetchAssets(in: c, options: nil).count
                    if n > 0 { out.append(ExternalAlbum(id: c.localIdentifier, title: c.localizedTitle ?? String(localized: "Album"), count: n)) }
                }
                return out
            }
            let smart = albums(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites,
                                                                      options: nil))
                + albums(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRAW, options: nil))
            let mine = albums(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
            return smart + mine.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    public func list(_ scope: ExternalScope) async throws -> ExternalListing {
        try await Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets: PHFetchResult<PHAsset>
            switch scope {
            case .all:
                assets = PHAsset.fetchAssets(with: opts)
            case .album(let id):
                guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
                else { throw ExternalSourceError.unavailable(String(localized: "That album is no longer in your Photos library.")) }
                assets = PHAsset.fetchAssets(in: c, options: opts)
            case .dates:
                let i = scope.interval()!
                opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                             i.start as NSDate, i.end as NSDate)
                assets = PHAsset.fetchAssets(with: opts)
            }
            var all: [ExternalItem] = []
            assets.enumerateObjects { a, _, stop in
                if Task.isCancelled { stop.pointee = true }
                all.append(Self.item(a))
            }
            try Task.checkCancellation()
            return ExternalListing.sorting(all)
        }.value
    }

    static func resources(_ a: PHAsset) -> [(PHAssetResource, PhotoResourceChoice.Resource)] {
        PHAssetResource.assetResources(for: a).map { r in
            let role: PhotoResourceChoice.Role = switch r.type {
            case .photo: .original
            case .alternatePhoto: .alternate
            default: .other
            }
            return (r, PhotoResourceChoice.Resource(role: role, filename: r.originalFilename, uti: r.uniformTypeIdentifier))
        }
    }

    static func item(_ a: PHAsset) -> ExternalItem {
        let date = a.creationDate ?? Date(timeIntervalSince1970: 0)
        if a.mediaType == .video { return ExternalItem(id: a.localIdentifier, filename: "video", date: date, kind: .video) }
        guard let r = PhotoResourceChoice.pick(resources(a).map(\.1)) else {
            return ExternalItem(id: a.localIdentifier, filename: "photo", date: date, kind: .other)
        }
        return ExternalItem(id: a.localIdentifier, filename: r.filename, date: date, kind: r.kind)
    }

    static func asset(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

    public func thumbnail(for item: ExternalItem, maxPixelSize: Int) async -> CGImage? {
        guard let asset = Self.asset(item.id) else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        let side = CGFloat(maxPixelSize)
        let box = PHRequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                box.id = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                               contentMode: .aspectFit, options: opts) { image, _ in
                    #if os(macOS)
                    cont.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    #else
                    cont.resume(returning: image?.cgImage)
                    #endif
                }
            }
        } onCancel: {
            if let id = box.id { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    public func read(_ item: ExternalItem, into sink: @escaping @Sendable (Data) throws -> Void) async throws {
        guard let asset = Self.asset(item.id) else {
            throw ExternalSourceError.unavailable(String(localized: "\(item.filename) is no longer in your Photos library."))
        }
        let all = Self.resources(asset)
        guard let chosen = PhotoResourceChoice.pick(all.map(\.1)), let resource = all.first(where: { $0.1 == chosen })?.0
        else { throw ExternalSourceError.unavailable(String(localized: "\(item.filename) has no original in your Photos library.")) }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true // an optimized library keeps the original in iCloud
        let manager = PHAssetResourceManager.default()
        let box = PHRequestBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.dataID = manager.requestData(for: resource, options: opts, dataReceivedHandler: { data in
                    guard box.error == nil else { return }
                    do { try sink(data) } catch {
                        box.error = error
                        if let id = box.dataID { manager.cancelDataRequest(id) }
                    }
                }, completionHandler: { error in
                    if let e = box.error ?? error { cont.resume(throwing: e) } else { cont.resume() }
                })
            }
        } onCancel: {
            if let id = box.dataID { manager.cancelDataRequest(id) }
        }
        try Task.checkCancellation()
    }
}

/// A PhotoKit request id (and the first sink error), shared with PhotoKit's callback queues.
private final class PHRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: PHImageRequestID?
    private var _dataID: PHAssetResourceDataRequestID?
    private var _error: Error?

    var id: PHImageRequestID? {
        get { lock.withLock { _id } }
        set { lock.withLock { _id = newValue } }
    }

    var dataID: PHAssetResourceDataRequestID? {
        get { lock.withLock { _dataID } }
        set { lock.withLock { _dataID = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
}
