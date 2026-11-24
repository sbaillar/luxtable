import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photo dragged out of the browser to the Finder or another app: its original file.
///
/// The receiver gets a copy (`SentTransferredFile` without access to the original), so a
/// drop can never move or change the file in the session, whatever the receiver asks for.
public struct PhotoFile: Identifiable, Hashable, Sendable, Transferable {
    public let id: PhotoID
    public let url: URL

    public init(id: PhotoID, url: URL) {
        self.id = id
        self.url = url
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
            .suggestedFileName { $0.url.lastPathComponent }
    }
}

extension AppModel {
    /// The originals of `ids` to drag out, in the browser's order. A photo without a file
    /// (a sample, a missing original) is left out.
    public func dragFiles(for ids: [PhotoID]) -> [PhotoFile] {
        let wanted = Set(ids)
        return visiblePhotos.filter { wanted.contains($0.id) }.compactMap { p in
            guard let url = p.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return PhotoFile(id: p.id, url: url)
        }
    }

    /// What a drag that starts on a selected photo carries: the selection, in the browser's order.
    public var dragSelection: [PhotoID] {
        visibleIDs.filter(selection.contains)
    }
}
