import Foundation

/// The AI Upscale network: RealESRGAN_x2plus (Xintao Wang et al., Real-ESRGAN, BSD-3-Clause;
/// its RRDBNet from BasicSR, Apache-2.0) in Core ML float16, 256×256 planar RGB tiles in
/// and 512×512 out (`input` → `output`, sRGB-encoded 0..1). Converted by
/// `scripts/upscale-model/` (docs/UPSCALE_MODEL.md). Builds don't bundle it unless
/// `LT_BUNDLE_UPSCALE=1`: the app downloads the authors' release checkpoint on the user's
/// request and converts it on this Mac (`UpscaleModelDownload`, `UpscaleConversion`), so
/// Luxtable distributes none of the trained weights. See `Acknowledgements.md`.
public enum UpscaleModelDescriptor {
    public static let name = "LuxtableUpscale"
    /// SHA-256 of the package's weights; the pinned conversion reproduces it bit for bit
    /// (`convert.py` EXPECTED_WEIGHTS_SHA256).
    public static let weightsSHA256 = "d43bffce05fa1714f1a50e6ef19780f0ef5453a7e9448875316a4d564f46a310"
    /// What the UI says when this build can't upscale.
    public static let reasons = (missing: String(localized: "AI Upscale model not included in this build."),
                                 damaged: String(localized: "The AI Upscale model in this build is damaged (its checksum doesn’t match)."))
    /// Why the menu offers the download again (a downloaded copy failed its check).
    public static let downloadDamaged = String(localized: "The downloaded AI Upscale model is damaged. Photo ▸ Enhance ▸ Download AI Upscale Model… gets it again.")
    /// Why the menu offers the download instead of Upscale 2×.
    public static let notDownloaded = String(localized: "AI Upscale needs its model (about 34 MB). Photo ▸ Enhance ▸ Download AI Upscale Model… gets it.")

    /// The checkpoint the model is converted from, in its authors' GitHub release
    /// (`convert.py` WEIGHTS_URL and WEIGHTS_SHA256).
    public static let checkpointURL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
    public static let checkpointSHA256 = "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb"
    public static let checkpointSize: Int64 = 67_061_725
    /// SHA-256 of the converted package's model spec (`template.py` prints it).
    public static let specSHA256 = "9ab22201b39250d3dd3069da4bf39da17556485077e1f25839f3025b285d3570"
    /// Overrides `checkpointURL` (an https URL of the same file, for a mirror).
    public static let downloadEnvironmentKey = "LT_UPSCALE_MODEL_URL"

    /// Where the checkpoint is downloaded from: the environment's, else `checkpointURL`.
    public static func downloadURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        URL(string: LaunchEnvironment.value(downloadEnvironmentKey, in: environment).flatMap { $0.isEmpty ? nil : $0 } ?? checkpointURL)
    }

    /// The conversion template in `bundle` (`Resources/UpscaleModel`, from
    /// `app/Resources/UpscaleModel`), if the build has it.
    public static func template(in bundle: Bundle) -> URL? {
        let url = bundle.resourceURL?.appendingPathComponent("UpscaleModel", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("recipe.json").path) ? $0 : nil }
    }

    /// What the download prompt says (once, before anything is fetched).
    public static let downloadNotice = String(localized: """
        Luxtable will download RealESRGAN_x2plus (BSD 3-Clause License, 67 MB) from its authors’ GitHub release, \
        convert it and keep it on this Mac (about 34 MB). \
        Its training data (DIV2K, Flickr2K, OST) is licensed for non-commercial research only. Luxtable's \
        Apache-2.0 licence doesn't override those terms; complying with them is up to you. Details are in \
        Luxtable ▸ About Luxtable.
        """)


    /// The bundled package in `bundle`, if the build included it.
    public static func bundledPackage(in bundle: Bundle) -> URL? {
        let url = bundle.resourceURL?.appendingPathComponent("Models/\(name).mlpackage", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

/// AI Upscale's model in builds that don't bundle it: the pinned release checkpoint
/// downloaded on the user's request into a staging folder and checked by SHA-256, the
/// package built from it there (`UpscaleConversion`) and checked against its pins, then
/// moved into place as `<root>/LuxtableUpscale.mlpackage` in one rename (a cancel or
/// failure leaves nothing; the checkpoint isn't kept). `DenoiseModelStore` then checks
/// and compiles it like a bundled one.
@MainActor @Observable
public final class UpscaleModelDownload {
    public enum State: Equatable, Sendable {
        case notDownloaded
        case downloading(Double)
        case installed
        case failed(String)
    }

    public private(set) var state: State
    /// What to fetch and how to convert it.
    public struct Source: Sendable {
        /// The checkpoint: its URL, pinned SHA-256 and size.
        public var checkpoint: DownloadableModelDescriptor.File
        /// The conversion template folder (`UpscaleModelDescriptor.template`).
        public var template: URL
        /// The pinned SHA-256s of the converted model spec and weights.
        public var specSHA256: String
        public var weightsSHA256: String
    }

    /// Nil when this build has no conversion template.
    @ObservationIgnored let source: Source?
    @ObservationIgnored let root: URL
    @ObservationIgnored private let downloader: any ModelDownloader
    @ObservationIgnored private var running: Task<URL, Error>?
    @ObservationIgnored private var sweptStaging = false

    public init(root: URL, source: Source?,
                downloader: any ModelDownloader = URLSessionModelDownloader()) {
        self.root = root
        self.source = source
        self.downloader = downloader
        state = .notDownloaded
        if FileManager.default.fileExists(atPath: packageURL.path) { state = .installed }
    }

    /// Staging folders are `<root>/.upscale-download-<uuid>`: other models' sweeps of
    /// `.download-*` never take one in flight.
    static let stagingPrefix = ".upscale-download-"

    /// The app's: into `<support>/Models`, from `UpscaleModelDescriptor.downloadURL`, with
    /// the template in `bundle`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                bundle: Bundle = .main) -> UpscaleModelDownload {
        var source: Source?
        if let url = UpscaleModelDescriptor.downloadURL(environment: environment),
           let template = UpscaleModelDescriptor.template(in: bundle) {
            source = Source(checkpoint: .init(path: UpscaleConversion.checkpointName, url: url,
                                              sha256: UpscaleModelDescriptor.checkpointSHA256,
                                              size: UpscaleModelDescriptor.checkpointSize),
                            template: template, specSHA256: UpscaleModelDescriptor.specSHA256,
                            weightsSHA256: UpscaleModelDescriptor.weightsSHA256)
        }
        return UpscaleModelDownload(root: AppPaths.support.appendingPathComponent("Models", isDirectory: true), source: source)
    }

    /// Where the package is installed.
    public var packageURL: URL {
        root.appendingPathComponent(UpscaleModelDescriptor.name + ".mlpackage", isDirectory: true)
    }

    /// The installed package, if any.
    public var installedPackage: URL? { state == .installed ? packageURL : nil }

    public var isConfigured: Bool { source != nil }

    public var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// Fetch, convert, check and install the package (one run at a time); returns it. After
    /// `cancel()` this throws `CancellationError` and nothing is installed.
    public func download() async throws -> URL {
        if let running { return try await running.value }
        guard let source else { throw UpscaleError.unavailable(UpscaleModelDescriptor.reasons.missing) }
        state = .downloading(0)
        let task = Task { try await self.fetch(source) }
        running = task
        defer { running = nil }
        do {
            let url = try await task.value
            state = .installed
            return url
        } catch {
            if error is CancellationError || task.isCancelled {
                state = .notDownloaded
                throw CancellationError()
            }
            state = .failed(DownloadableModel.message(error))
            throw error
        }
    }

    public func cancel() {
        running?.cancel()
    }

    private func fetch(_ source: Source) async throws -> URL {
        let fm = FileManager.default
        if !sweptStaging { // a download a crash or quit cut short, before this one's folder exists
            sweptStaging = true
            let root = root, prefix = Self.stagingPrefix
            await Task.detached(priority: .utility) { ModelFiles.sweepStaging(in: root, prefix: prefix) }.value
        }
        let staging = root.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = source.checkpoint
        let checkpoint = staging.appendingPathComponent(file.path)
        let package = staging.appendingPathComponent(packageURL.lastPathComponent, isDirectory: true)
        let name = String(localized: "AI Upscale model")
        do {
            try await ModelFiles.fetch(file.url, to: checkpoint, sha256: file.sha256, size: file.size, path: file.path,
                                       using: downloader, progress: { [weak self] bytes in
                let f = min(1, Double(bytes) / Double(max(file.size, 1)))
                Task { @MainActor in if case .downloading = self?.state { self?.state = .downloading(f) } }
            })
            try Task.checkCancellation()
            // Convert and check off the main actor: the result must be the pinned conversion.
            try await Task.detached(priority: .userInitiated) {
                try UpscaleConversion.build(checkpoint: checkpoint, template: source.template, package: package)
                for (path, pinned) in [(UpscaleConversion.specPath, source.specSHA256),
                                       (DenoiseModelDescriptor.weightsPath, source.weightsSHA256)] {
                    guard try ModelFiles.sha256(of: package.appendingPathComponent(path)) == pinned else {
                        throw ModelFetchError.checksum(path)
                    }
                }
            }.value
        } catch let e as ModelFetchError {
            switch e {
            case .download(let m): throw ModelDownloadError.download(name, m)
            case .checksum(let f): throw ModelDownloadError.checksum(name, f)
            }
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: packageURL.path) {
            _ = try fm.replaceItemAt(packageURL, withItemAt: package) // a damaged earlier copy, swapped atomically
        } else {
            try fm.moveItem(at: package, to: packageURL)
        }
        return packageURL
    }
}

public enum UpscaleError: Error, Equatable, LocalizedError {
    /// The model is missing or damaged (the reason), or the session can't take new photos.
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        case .failed(let m): String(localized: "AI Upscale failed: \(m)")

        }
    }
}
