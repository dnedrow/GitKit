import Foundation

// MARK: - Protocols

/// Protocol for objects stored in the Git object database.
public protocol GKObjectProtocol {
    /// The type of this object (blob, tree, commit, tag).
    var type: GKObjectType { get }

    /// The object's unique identifier (SHA-1 hash).
    var oid: GKObjectID { get }

    /// Serializes the object into its raw content (without header).
    func serialize() -> Data
}

/// Protocol for reading from the object database.
public protocol GKObjectDatabaseReading {
    /// Reads a raw object from the database.
    func read(oid: GKObjectID) throws -> GKRawObject

    /// Checks if an object exists in the database.
    func exists(oid: GKObjectID) -> Bool
}

/// Protocol for writing to the object database.
public protocol GKObjectDatabaseWriting {
    /// Writes a raw object to the database and returns its OID.
    @discardableResult
    func write(_ object: GKRawObject) throws -> GKObjectID
}

/// Combined object database protocol.
public protocol GKObjectDatabase: GKObjectDatabaseReading, GKObjectDatabaseWriting {}

// MARK: - Object Types

/// The four types of objects in a Git repository.
public enum GKObjectType: String, Sendable {
    case blob = "blob"
    case tree = "tree"
    case commit = "commit"
    case tag = "tag"

    /// The raw bytes for the type string (used in headers).
    var headerBytes: [UInt8] {
        Array(rawValue.utf8)
    }
}

// MARK: - Raw Object

/// A raw Git object with type, size, and content data.
public struct GKRawObject: Sendable {
    public let type: GKObjectType
    public let data: Data
    public let oid: GKObjectID

    public init(type: GKObjectType, data: Data) {
        self.type = type
        self.data = data
        // Compute OID from the full object representation
        let header = "\(type.rawValue) \(data.count)\0"
        let fullData = Data(header.utf8) + data
        let hash = GKSHA1.hash(fullData)
        self.oid = GKObjectID(bytes: hash)
    }

    /// Computes the OID for the given type and data without storing.
    public static func computeOID(type: GKObjectType, data: Data) -> GKObjectID {
        let header = "\(type.rawValue) \(data.count)\0"
        let fullData = Data(header.utf8) + data
        let hash = GKSHA1.hash(fullData)
        return GKObjectID(bytes: hash)
    }

    /// The full serialized form: "type size\0data"
    public var serialized: Data {
        let header = "\(type.rawValue) \(data.count)\0"
        return Data(header.utf8) + data
    }
}
