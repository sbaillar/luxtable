import CoreGraphics
import Foundation
import ImageCaptureCore
import ImageIO

// The ImageCaptureCore side of iPhone and iPad import. Not unit-tested (needs a device on
// USB); what it decides is `DeviceFilePairing`, `ExternalListing.sorting`, `ExternalScope`
// and `ChunkedRead`, which are. It only ever reads: no download-and-delete option, no
// uploads, no deletes are ever sent to the device.

/// `ICDeviceBrowser` for local cameras that aren't mounted as a disk (cards and cameras in
/// mass-storage mode already come in as volumes).
@MainActor
public final class ImageCaptureBrowser: NSObject, DeviceBrowsing, ICDeviceBrowserDelegate {
    private let browser = ICDeviceBrowser()
    private var onAdd: (@MainActor (String, any ExternalPhotoSource) -> Void)?
    private var onRemove: (@MainActor (String) -> Void)?

    override public init() { super.init() }

    public func start(onAdd: @escaping @MainActor (String, any ExternalPhotoSource) -> Void,
                      onRemove: @escaping @MainActor (String) -> Void) {
        self.onAdd = onAdd
        self.onRemove = onRemove
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue
            | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
        browser.start()
    }

    public func stop() {
        browser.stop()
        browser.delegate = nil
    }

    static func key(_ d: ICDevice) -> String { d.uuidString ?? "\(ObjectIdentifier(d).hashValue)" }

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let box = UncheckedBox(device)
        MainActor.assumeIsolated {
            guard let camera = box.value as? ICCameraDevice, camera.transportType != ICDeviceTransport.transportTypeMassStorage.rawValue
            else { return }
            onAdd?(Self.key(camera), ImageCaptureDevice(camera))
        }
    }

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let box = UncheckedBox(device)
        MainActor.assumeIsolated { onRemove?(Self.key(box.value)) }
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// One iPhone, iPad or USB camera as an `ExternalPhotoSource`. Originals are read with
/// `requestReadData` in chunks (the stager writes, verifies and renames them); the device
/// shows its original HEIC/ProRAW files, not the JPEGs it would convert them to.
public final class ImageCaptureDevice: NSObject, ExternalPhotoSource, ICCameraDeviceDelegate, @unchecked Sendable {
    private let camera: ICCameraDevice
    private let lock = NSLock()
    private var ready: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var files: [String: ICCameraFile] = [:]

    init(_ camera: ICCameraDevice) {
        self.camera = camera
        super.init()
    }

    public var name: String { camera.name ?? "iPhone" }
    public var isPhotosLibrary: Bool { false }

    static let lockedMessage = "Unlock the device and tap Trust if it asks whether to trust this Mac, then try again."

    public func prepare() async throws {
        if lock.withLock({ isReady }) { return }
        if await MainActor.run(body: { camera.isAccessRestrictedAppleDevice }) {
            throw ExternalSourceError.unavailable(Self.lockedMessage)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { ready = cont }
            DispatchQueue.main.async { [self] in
                camera.delegate = self
                camera.mediaPresentation = .originalAssets
                if camera.hasOpenSession, camera.contentCatalogPercentCompleted >= 100 {
                    resumeReady(nil)
                } else if !camera.hasOpenSession {
                    camera.requestOpenSession()
                }
            }
        }
    }

    private func resumeReady(_ error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { ready = nil }
            if error == nil { isReady = true }
            return ready
        }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    public func albums() async -> [ExternalAlbum] { [] }

    public func list(_ scope: ExternalScope) async throws -> ExternalListing {
        let media = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var table: [String: ICCameraFile] = [:]
        var described: [DeviceFile] = []
        for f in media {
            let k = Self.key(f)
            table[k] = f
            var raw: String?
            if let r = f.pairedRawImage {
                raw = Self.key(r)
                table[raw!] = r
            }
            described.append(DeviceFile(key: k, name: f.name ?? "", pairedRawKey: raw))
        }
        lock.withLock { files = table }
        let items = DeviceFilePairing.originals(described).compactMap { k -> ExternalItem? in
            guard let f = table[k] else { return nil }
            let date = f.exifCreationDate ?? f.creationDate ?? f.fileCreationDate ?? Date(timeIntervalSince1970: 0)
            guard scope.contains(date) else { return nil }
            let name = f.name ?? "IMG"
            return ExternalItem(id: k, filename: name, date: date, size: Int64(f.fileSize),
                                kind: ExternalItemKind.classify(filename: name, uti: f.uti))
        }
        return ExternalListing.sorting(items)
    }

    static func key(_ f: ICCameraItem) -> String { "\(ObjectIdentifier(f).hashValue)" }

    private func file(_ item: ExternalItem) throws -> ICCameraFile {
        guard let f = lock.withLock({ files[item.id] }) else {
            throw ExternalSourceError.unavailable("\(item.filename) is no longer on the device.")
        }
        return f
    }

    public func thumbnail(for item: ExternalItem, maxPixelSize: Int) async -> CGImage? {
        guard let f = try? file(item) else { return nil }
        let data: Data? = await withCheckedContinuation { cont in
            f.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixelSize]) { data, _ in
                cont.resume(returning: data)
            }
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public func read(_ item: ExternalItem, into sink: @escaping @Sendable (Data) throws -> Void) async throws {
        let f = try file(item)
        let box = UncheckedBox(f)
        try await ChunkedRead.read(size: Int64(f.fileSize), fetch: { offset, length in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                box.value.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                    if let data { cont.resume(returning: data) } else {
                        cont.resume(throwing: error ?? ExternalSourceError.readFailed("The device didn’t send \(item.filename)."))
                    }
                }
            }
        }, into: sink)
    }

    // MARK: ICCameraDeviceDelegate

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { resumeReady(nil) }

    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { resumeReady(ExternalSourceError.unavailable("Couldn’t open \(name): \(error.localizedDescription)")) }
    }

    public func didRemove(_ device: ICDevice) {
        lock.withLock { isReady = false }
        resumeReady(ExternalSourceError.unavailable("\(name) was disconnected."))
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { lock.withLock { isReady = false } }
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
                             error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem,
                             error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
