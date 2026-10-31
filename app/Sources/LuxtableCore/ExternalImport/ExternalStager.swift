import CryptoKit
import Foundation

/// An original that couldn't be copied out of the source, and why.
public struct StageFailure: Equatable, Sendable, Hashable {
    public var filename: String
    public var reason: String

    public init(filename: String, reason: String) {
        self.filename = filename
        self.reason = reason
    }
}

public struct StageResult: Equatable, Sendable {
    public var folder: URL
    /// Staged file per item id.
    public var staged: [String: URL] = [:]
    public var failed: [StageFailure] = []
    public var bytes: Int64 = 0
}

/// Copies originals out of an `ExternalPhotoSource` into a staging folder, one file at a
/// time, the way lt-import copies a card: the bytes go to a hidden `.partial` file (lt-import's
/// scan skips dot files), are fsynced, read back from disk and compared (SHA-256) with what
/// the source sent, checked against the size the source announced, and only then renamed to
/// their final name. The file's modification date is set to the capture date (lt-import
/// orders by it). A failed or cancelled file leaves nothing behind; the source is only read.
public struct ExternalStager: Sendable {
    public init() {}

    public func stage(_ items: [ExternalItem], from source: any ExternalPhotoSource, into folder: URL,
                      progress: @escaping @MainActor (_ done: Int, _ bytes: Int64) -> Void = { _, _ in })
        async throws -> StageResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result = StageResult(folder: folder)
        var used = Set<String>()
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            let name = Self.uniqueName(item.filename, used: &used)
            do {
                let (url, bytes) = try await stageOne(item, name: name, from: source, into: folder)
                result.staged[item.id] = url
                result.bytes += bytes
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                result.failed.append(StageFailure(filename: item.filename, reason: error.localizedDescription))
            }
            let (done, bytes) = (i + 1, result.bytes)
            await progress(done, bytes)
        }
        return result
    }

    func stageOne(_ item: ExternalItem, name: String, from source: any ExternalPhotoSource, into folder: URL)
        async throws -> (URL, Int64) {
        let fm = FileManager.default
        let partial = folder.appendingPathComponent(".\(name).partial")
        let final = folder.appendingPathComponent(name)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw ExternalSourceError.readFailed(String(localized: "Couldn’t create a file in the staging folder."))
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            let writer = HashingWriter(handle)
            do {
                try await source.read(item, into: writer.write)
                try writer.finish()
            } catch {
                try? writer.finish()
                throw error
            }
            let (digest, count) = writer.result
            if let size = item.size, size != count {
                throw ExternalSourceError.readFailed(String(localized: "Only \(count) of \(size) bytes arrived."))
            }
            guard count > 0 else { throw ExternalSourceError.readFailed(String(localized: "The original is empty.")) }
            guard try Self.sha256(of: partial) == digest else {
                throw ExternalSourceError.readFailed(String(localized: "The copy didn’t read back the same as the original."))
            }
            try fm.setAttributes([.modificationDate: item.date], ofItemAtPath: partial.path)
            try fm.moveItem(at: partial, to: final)
            return (final, count)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `name`, or `name-2`, `name-3`… when another staged file already has it (two
    /// `IMG_0001.HEIC` from different years). Case-insensitive, like the default file system.
    static func uniqueName(_ filename: String, used: inout Set<String>) -> String {
        let clean = ExternalStaging.safeName(filename, fallback: "Photo")
        let ns = clean as NSString
        let (stem, ext) = (ns.deletingPathExtension, ns.pathExtension)
        var candidate = clean
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    static func sha256(of url: URL) throws -> SHA256.Digest {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }
}

/// Writes and hashes the chunks a source sends (from whatever queue it calls on).
final class HashingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hasher = SHA256()
    private var count: Int64 = 0
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }

    var write: @Sendable (Data) throws -> Void {
        { [self] data in
            try lock.withLock {
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                count += Int64(data.count)
            }
        }
    }

    /// fsync and close.
    func finish() throws {
        try lock.withLock {
            guard !closed else { return }
            closed = true
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    var result: (SHA256.Digest, Int64) { lock.withLock { (hasher.finalize(), count) } }
}

/// The staging folders: `<support>/Import Staging/<id>/<source name>/`. The folder's name is
/// what the import sheet shows ("Import from Photos Library"). Staged copies are Luxtable's
/// own temporary files: removed once no import reads them (never anything of the user's).
public enum ExternalStaging {
    public static var root: URL { AppPaths.support.appendingPathComponent("Import Staging", isDirectory: true) }

    public static func makeFolder(for sourceName: String, root: URL = root) -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(safeName(sourceName, fallback: "Import"), isDirectory: true)
    }

    /// Whether `url` is a staging folder (so the sheet talks about Photos, not a card).
    public static func isStaged(_ url: URL?, root: URL = root) -> Bool {
        guard let url else { return false }
        let r = root.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(r)
    }

    /// Remove every staging folder except those `keeping` reads from.
    public static func cleanUp(keeping: [URL], root: URL = root) {
        let fm = FileManager.default
        let keep = Set(keeping.filter { isStaged($0, root: root) }.map {
            $0.standardizedFileURL.deletingLastPathComponent().lastPathComponent
        })
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for d in dirs where !keep.contains(d.lastPathComponent) { try? fm.removeItem(at: d) }
    }

    /// A file or folder name: no `/` or `:`, no leading dot, never empty.
    static func safeName(_ s: String, fallback: String) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        return t.isEmpty ? fallback : t
    }
}
