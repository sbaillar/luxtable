import Foundation
import Observation

/// Finds iPhones, iPads (and other cameras that talk over USB rather than mounting as a
/// disk). The live one is `ImageCaptureBrowser`; tests use a fake.
@MainActor
public protocol DeviceBrowsing: AnyObject {
    func start(onAdd: @escaping @MainActor (_ id: String, any ExternalPhotoSource) -> Void,
               onRemove: @escaping @MainActor (_ id: String) -> Void)
    func stop()
}

/// A device plugged in right now, as the import sheet offers it.
public struct ConnectedDevice: Identifiable {
    public var id: String
    public var source: any ExternalPhotoSource
    public var name: String { source.name }
}

/// The devices connected now, kept up to date while the import sheet shows them.
@MainActor @Observable
public final class ConnectedDevices {
    public static let shared = ConnectedDevices(browser: nil)

    public private(set) var devices: [ConnectedDevice] = []
    @ObservationIgnored private var browser: (any DeviceBrowsing)?
    @ObservationIgnored private let makeBrowser: @MainActor () -> any DeviceBrowsing
    public private(set) var isRunning = false

    /// `browser`: `nil` uses ImageCaptureCore.
    public init(browser: (any DeviceBrowsing)?) {
        self.browser = browser
        makeBrowser = { ImageCaptureBrowser() }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let b = browser ?? makeBrowser()
        browser = b
        b.start(onAdd: { [weak self] id, source in
            guard let self, !self.devices.contains(where: { $0.id == id }) else { return }
            self.devices.append(ConnectedDevice(id: id, source: source))
        }, onRemove: { [weak self] id in
            self?.devices.removeAll { $0.id == id }
        })
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        browser?.stop()
        devices = []
    }
}

/// A file on a device, as far as pairing needs it.
public struct DeviceFile: Equatable, Sendable {
    public var key: String
    public var name: String
    /// The RAW the camera shot alongside this JPEG/HEIC (ImageCaptureCore's `pairedRawImage`).
    public var pairedRawKey: String?

    public init(key: String, name: String, pairedRawKey: String? = nil) {
        self.key = key
        self.name = name
        self.pairedRawKey = pairedRawKey
    }
}

public enum DeviceFilePairing {
    /// The originals to offer: the RAW of a RAW+JPEG pair instead of its JPEG, each file once.
    public static func originals(_ files: [DeviceFile]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for f in files {
            let k = f.pairedRawKey ?? f.key
            if seen.insert(k).inserted { out.append(k) }
        }
        return out
    }
}
