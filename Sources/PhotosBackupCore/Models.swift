import Foundation

public enum BackupError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidArgument(String)
    case permission(String)
    case storage(String)
    case integrity(String)
    case conflict(String)
    case diskBudget(required: Int64, available: Int64)

    public var description: String {
        switch self {
        case .invalidConfiguration(let s): return "Configuration: \(s)"
        case .invalidArgument(let s): return "Argument: \(s)"
        case .permission(let s): return "Photos permission: \(s)"
        case .storage(let s): return "Storage: \(s)"
        case .integrity(let s): return "Integrity: \(s)"
        case .conflict(let s): return "Conflict: \(s)"
        case .diskBudget(let need, let have): return "Spool budget exceeded (need \(need) bytes; \(have) available)"
        }
    }
}

public enum Representation: String, Codable, CaseIterable {
    case original
    case current
}

public enum PhotoCurrentResourcePolicy {
    public static func kind(resourceType: String, assetIsImage: Bool) -> String? {
        switch resourceType {
        case "fullSizePhoto": return "image"
        case "fullSizePairedVideo": return "paired-video"
        case "fullSizeVideo": return assetIsImage ? "paired-video" : "video"
        default: return nil
        }
    }

    public static func matchingTypes(kind: String, assetIsImage: Bool) -> Set<String> {
        switch kind {
        case "image": return ["fullSizePhoto"]
        case "paired-video": return assetIsImage ? ["fullSizePairedVideo", "fullSizeVideo"] : ["fullSizePairedVideo"]
        case "video": return assetIsImage ? [] : ["fullSizeVideo"]
        default: return []
        }
    }
}

public enum ExportProgressPhase: String {
    case unknown, waiting, exporting, completed, failed, cancelled
}

public enum ExportBudgetPolicy {
    public static func shouldMonitor(_ phase: ExportProgressPhase) -> Bool {
        phase == .unknown || phase == .waiting || phase == .exporting
    }
    public static func exceedsLimit(currentBytes: Int64, limit: Int64) -> Bool {
        currentBytes > limit
    }
}

public struct BackupItem: Codable, Hashable, Identifiable {
    public let libraryID: String
    public let assetID: String
    public let resourceID: String
    public let representation: Representation
    public let filename: String
    public let uniformType: String
    public let sourceModified: Date?
    public let creationDate: Date?
    public let contentType: String
    public let sourceSize: Int64?
    public let identityAmbiguous: Bool
    public let resourceKind: String
    public let exportUnavailableReason: String?

    public var id: String { "\(libraryID)/\(assetID)/\(resourceID)/\(representation.rawValue)" }
    public var blobName: String {
        let encoded = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "manifests/\(encoded)"
    }

    public var encodedIdentity: String {
        Data(id.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func objectName(hash: String) -> String {
        let library = Data(libraryID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "objects/\(library)/\(hash.lowercased())"
    }

    public init(libraryID: String, assetID: String, resourceID: String, representation: Representation,
                filename: String, uniformType: String, sourceModified: Date?, creationDate: Date?, contentType: String,
                sourceSize: Int64? = nil, identityAmbiguous: Bool = false, resourceKind: String = "", exportUnavailableReason: String? = nil) {
        self.libraryID = libraryID; self.assetID = assetID; self.resourceID = resourceID
        self.representation = representation; self.filename = filename; self.uniformType = uniformType
        self.sourceModified = sourceModified; self.creationDate = creationDate; self.contentType = contentType
        self.sourceSize = sourceSize
        self.identityAmbiguous = identityAmbiguous
        self.resourceKind = resourceKind; self.exportUnavailableReason = exportUnavailableReason
    }

}

public struct ExportDescriptor: Codable, Hashable {
    public let filename: String
    public let uniformType: String
    public let contentType: String
    public init(filename: String, uniformType: String, contentType: String) {
        self.filename = filename; self.uniformType = uniformType; self.contentType = contentType
    }
    public init(item: BackupItem) {
        self.init(filename: item.filename, uniformType: item.uniformType, contentType: item.contentType)
    }
}

public struct BlobRecord: Codable, Equatable {
    public let etag: String
    public let size: Int64
    public let metadata: [String: String]
    public init(etag: String, size: Int64, metadata: [String: String]) {
        self.etag = etag; self.size = size; self.metadata = metadata
    }
}

public struct ListedBlob: Equatable {
    public let name: String
    public let record: BlobRecord

    public init(name: String, record: BlobRecord) {
        self.name = name
        self.record = record
    }
}

public struct BlobListPage: Equatable {
    public let blobs: [ListedBlob]
    public let continuationToken: String?

    public init(blobs: [ListedBlob], continuationToken: String?) {
        self.blobs = blobs
        self.continuationToken = continuationToken
    }
}

public protocol PhotoLibrary: AnyObject {
    func authorization() -> String
    func requestAuthorization() async -> String
    func enumerate(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws
    func export(_ item: BackupItem, to destination: URL, maximumBytes: Int64) async throws -> ExportDescriptor
    func verify(_ item: BackupItem) async throws
}

public protocol BlobStore: AnyObject {
    func blob(_ name: String) async throws -> BlobRecord?
    func uncommittedBlockIDs(_ name: String) async throws -> Set<String>
    func putBlock(_ name: String, id: String, bytes: Data) async throws
    func commit(_ name: String, blockIDs: [String], metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord
    func setMetadata(_ name: String, metadata: [String: String], ifMatch: String) async throws
    func publish(_ name: String, metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord
    func probe(prefix: String) async throws
}

public struct RunSummary: Codable {
    public var examined = 0
    public var skipped = 0
    public var uploaded = 0
    public var resumed = 0
    public var pending = 0
    public var wouldUpload = 0
    public var failed = 0
    public var bytesTransferred: Int64 = 0
    public var bytesReused: Int64 = 0
    public var unclassifiableAssets = 0
    public var dryRun = false
}

public struct PhotoInventoryPolicy: Equatable {
    public let includeHiddenAssets: Bool
    public let includeAllBurstAssets: Bool
    public let includesRecentlyDeleted: Bool
    public let sharedAlbumCoverageVerified: Bool
    public static let completeAccessibleLibrary = PhotoInventoryPolicy(includeHiddenAssets: true, includeAllBurstAssets: true,
                                                                        includesRecentlyDeleted: false, sharedAlbumCoverageVerified: false)
    public init(includeHiddenAssets: Bool, includeAllBurstAssets: Bool,
                includesRecentlyDeleted: Bool, sharedAlbumCoverageVerified: Bool) {
        self.includeHiddenAssets = includeHiddenAssets; self.includeAllBurstAssets = includeAllBurstAssets
        self.includesRecentlyDeleted = includesRecentlyDeleted; self.sharedAlbumCoverageVerified = sharedAlbumCoverageVerified
    }
}

public extension Date {
    /// A nanosecond epoch token preserves Foundation Date's representable precision
    /// closely enough for version comparisons and avoids Azure's millisecond rounding.
    var versionToken: String {
        let scaled = timeIntervalSince1970 * 1_000_000_000
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled <= Double(Int64.max) else {
            return iso8601Fractional
        }
        return "ns:\(Int64(scaled.rounded()))"
    }

    var iso8601Fractional: String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}
