import CoreGraphics
import Foundation

// Importing from the Apple Photos library and from an iPhone or iPad on USB. Neither is a
// folder lt-import can walk, so their originals are first copied into a staging folder
// (`ExternalStager`: temp file, fsync, read back and compare, rename), and that folder then
// goes through the regular card import (lt-import's verified copy, dedupe, journal) into a
// new or existing session. The source is only ever read.

/// What an original is, by its file name (and type identifier when the source gives one).
public enum ExternalItemKind: String, Sendable, Equatable {
    case raw, heif, jpeg, video, other

    static let rawExtensions: Set<String> = [
        "arw", "arq", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "rwl",
        "dng", "pef", "srw", "3fr", "fff", "iiq", "erf", "mos", "mrw", "kdc", "dcr", "x3f", "raw",
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts"]

    /// Classify by extension; a RAW type identifier (`public.camera-raw-image`, `com.adobe.raw-image`
    /// for DNG and ProRAW) wins over an odd extension.
    public static func classify(filename: String, uti: String? = nil) -> ExternalItemKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if rawExtensions.contains(ext) { return .raw }
        switch ext {
        case "heic", "heif", "hif": return .heif
        case "jpg", "jpeg": return .jpeg
        default: break
        }
        if videoExtensions.contains(ext) { return .video }
        if let uti, uti == "com.adobe.raw-image" || uti.hasSuffix("raw-image") { return .raw }
        return .other
    }

    /// Photos Luxtable imports (lt-import's RAW, JPEG and HEIF).
    public var isImportable: Bool { self == .raw || self == .heif || self == .jpeg }
}

/// One original on the source: a Photos asset's chosen resource, or a file on the device.
public struct ExternalItem: Identifiable, Hashable, Sendable {
    /// The source's own handle (asset local identifier, device file key).
    public var id: String
    public var filename: String
    public var date: Date
    /// Bytes, when the source knows them before reading (a device does; Photos doesn't).
    public var size: Int64?
    public var kind: ExternalItemKind

    public init(id: String, filename: String, date: Date, size: Int64? = nil, kind: ExternalItemKind? = nil) {
        self.id = id
        self.filename = filename
        self.date = date
        self.size = size
        self.kind = kind ?? ExternalItemKind.classify(filename: filename)
    }
}

/// An album to pick from (Photos only).
public struct ExternalAlbum: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var count: Int

    public init(id: String, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// Which photos to list.
public enum ExternalScope: Hashable, Sendable {
    case all
    case album(String)
    /// Captured on or between these days (local time; both ends inclusive).
    case dates(from: Date, to: Date)

    /// The half-open interval `.dates` covers: start of `from`'s day to the start of the day after `to`.
    public func interval(calendar: Calendar = .current) -> DateInterval? {
        guard case .dates(let a, let b) = self else { return nil }
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        let start = calendar.startOfDay(for: lo)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: hi)) ?? hi
        return DateInterval(start: start, end: end)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let i = interval(calendar: calendar) else { return true }
        return date >= i.start && date < i.end
    }
}

/// What a listing found: the photos it offers and what it leaves out.
public struct ExternalListing: Sendable, Equatable {
    public var items: [ExternalItem]
    /// Videos (not imported from these sources).
    public var videos: Int
    /// File names of originals in a format Luxtable doesn't import (PNG, GIF…).
    public var unsupported: [String]

    public init(items: [ExternalItem], videos: Int = 0, unsupported: [String] = []) {
        self.items = items
        self.videos = videos
        self.unsupported = unsupported
    }

    /// Split classified items into the importable ones and the rest.
    public static func sorting(_ all: [ExternalItem]) -> ExternalListing {
        var out = ExternalListing(items: [])
        for i in all {
            if i.kind.isImportable {
                out.items.append(i)
            } else if i.kind == .video {
                out.videos += 1
            } else if (i.filename as NSString).pathExtension.lowercased() != "aae" { // Photos' edit notes, not photos
                out.unsupported.append(i.filename)
            }
        }
        out.items.sort { ($0.date, $0.filename) < ($1.date, $1.filename) }
        return out
    }
}

public enum ExternalSourceError: Error, Equatable, LocalizedError {
    /// The user hasn't allowed access (Photos: Privacy & Security ▸ Photos).
    case accessDenied(String)
    /// The device went away or is locked.
    case unavailable(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let s), .unavailable(let s), .readFailed(let s): s
        }
    }
}

/// Where originals come from. The live ones wrap PhotoKit (`PhotoKitLibrary`) and
/// ImageCaptureCore (`ImageCaptureDevice`); tests use a fake. Nothing here writes to the source.
public protocol ExternalPhotoSource: AnyObject, Sendable {
    /// "Photos Library", the device's name.
    var name: String { get }
    var isPhotosLibrary: Bool { get }
    /// Ask for access (Photos) or open the device; throws `ExternalSourceError` when it can't.
    func prepare() async throws
    /// Albums to choose from (empty for a device).
    func albums() async -> [ExternalAlbum]
    func list(_ scope: ExternalScope) async throws -> ExternalListing
    func thumbnail(for item: ExternalItem, maxPixelSize: Int) async -> CGImage?
    /// Stream the original's bytes in order into `sink` (which may throw to stop).
    func read(_ item: ExternalItem, into sink: @escaping @Sendable (Data) throws -> Void) async throws
}

/// Reads a file of known size in chunks through `fetch(offset, length)` (a device's
/// `requestReadData`), stopping at a short or empty chunk.
public enum ChunkedRead {
    public static func read(size: Int64, chunk: Int64 = 4 << 20,
                            fetch: (Int64, Int64) async throws -> Data,
                            into sink: (Data) throws -> Void) async throws {
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let want = min(chunk, size - offset)
            let data = try await fetch(offset, want)
            guard !data.isEmpty else {
                throw ExternalSourceError.readFailed("The device stopped sending data after \(offset) of \(size) bytes.")
            }
            try sink(data)
            offset += Int64(data.count)
        }
    }
}
