import Foundation

/// Which of a Photos asset's resources is the original Luxtable imports.
///
/// Photos keeps the camera's file as the `photo` resource (HEIC, JPEG, a ProRAW DNG, or the
/// RAW of a RAW-only import); for a RAW+JPEG pair the JPEG is the `photo` and the RAW the
/// `alternatePhoto`. Edits live in other resources (`fullSizePhoto`, adjustment data) and are
/// never taken: the RAW of a pair wins, then the unedited original.
public enum PhotoResourceChoice {
    public enum Role: Sendable, Equatable {
        case original, alternate, other
    }

    public struct Resource: Sendable, Equatable {
        public var role: Role
        public var filename: String
        public var uti: String?

        public init(role: Role, filename: String, uti: String? = nil) {
            self.role = role
            self.filename = filename
            self.uti = uti
        }

        public var kind: ExternalItemKind { ExternalItemKind.classify(filename: filename, uti: uti) }
    }

    /// The resource to copy, or `nil` when the asset has no original at all.
    public static func pick(_ resources: [Resource]) -> Resource? {
        if let raw = resources.first(where: { $0.role == .alternate && $0.kind == .raw }) { return raw }
        return resources.first { $0.role == .original }
    }
}
