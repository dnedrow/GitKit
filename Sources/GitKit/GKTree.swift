import Foundation

// MARK: - Tree

/// Represents a Git tree object (directory listing).
public struct GKTree: GKObjectProtocol, Sendable {
    public let oid: GKObjectID
    public let entries: [GKTreeEntry]
    public var type: GKObjectType { .tree }

    /// Creates a tree from entries and computes its OID.
    public init(entries: [GKTreeEntry]) {
        self.entries = entries.sorted()
        let data = GKTree.serializeEntries(self.entries)
        let raw = GKRawObject(type: .tree, data: data)
        self.oid = raw.oid
    }

    /// Creates a tree from raw object data.
    init(oid: GKObjectID, data: Data) throws {
        self.oid = oid
        self.entries = try GKTree.parseEntries(data)
    }

    public func serialize() -> Data {
        GKTree.serializeEntries(entries)
    }

    // MARK: - Parsing

    private static func parseEntries(_ data: Data) throws -> [GKTreeEntry] {
        var entries = [GKTreeEntry]()
        var offset = 0
        let bytes = Array(data)

        while offset < bytes.count {
            // Read mode (space-terminated)
            guard let spaceIdx = bytes[offset...].firstIndex(of: 0x20) else {
                throw GKError.invalidTree("Missing space after mode")
            }
            let modeStr = String(bytes: bytes[offset..<spaceIdx], encoding: .ascii) ?? ""
            offset = spaceIdx + 1

            // Read name (null-terminated)
            guard let nullIdx = bytes[offset...].firstIndex(of: 0x00) else {
                throw GKError.invalidTree("Missing null after name")
            }
            let name = String(bytes: bytes[offset..<nullIdx], encoding: .utf8) ?? ""
            offset = nullIdx + 1

            // Read 20-byte SHA-1
            guard offset + 20 <= bytes.count else {
                throw GKError.invalidTree("Truncated SHA-1")
            }
            let oidBytes = Array(bytes[offset..<offset + 20])
            let oid = GKObjectID(uncheckedBytes: oidBytes)
            offset += 20

            guard let mode = GKFileMode(rawValue: modeStr) else {
                throw GKError.invalidTree("Invalid mode: \(modeStr)")
            }

            entries.append(GKTreeEntry(mode: mode, name: name, oid: oid))
        }

        return entries
    }

    private static func serializeEntries(_ entries: [GKTreeEntry]) -> Data {
        var data = Data()
        for entry in entries {
            data.append(contentsOf: entry.mode.rawValue.utf8)
            data.append(0x20) // space
            data.append(contentsOf: entry.name.utf8)
            data.append(0x00) // null
            data.append(contentsOf: entry.oid.bytes)
        }
        return data
    }
}

// MARK: - Tree Entry

/// A single entry in a tree object.
public struct GKTreeEntry: Sendable, Comparable {
    public let mode: GKFileMode
    public let name: String
    public let oid: GKObjectID

    public init(mode: GKFileMode, name: String, oid: GKObjectID) {
        self.mode = mode
        self.name = name
        self.oid = oid
    }

    /// Whether this entry represents a subtree (directory).
    public var isTree: Bool {
        mode == .directory
    }

    public static func < (lhs: GKTreeEntry, rhs: GKTreeEntry) -> Bool {
        // Git sorts tree entries with a trailing '/' for directories
        let lhsName = lhs.isTree ? lhs.name + "/" : lhs.name
        let rhsName = rhs.isTree ? rhs.name + "/" : rhs.name
        return lhsName < rhsName
    }

    public static func == (lhs: GKTreeEntry, rhs: GKTreeEntry) -> Bool {
        lhs.name == rhs.name && lhs.mode == rhs.mode && lhs.oid == rhs.oid
    }
}

// MARK: - File Mode

/// Git file modes for tree entries.
public enum GKFileMode: RawRepresentable, Sendable, Equatable, Hashable {
    case regular
    case executable
    case symlink
    case gitlink
    case directory

    public init?(rawValue: String) {
        switch rawValue {
        case "100644": self = .regular
        case "100755": self = .executable
        case "120000": self = .symlink
        case "160000": self = .gitlink
        case "40000", "040000": self = .directory
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .regular: return "100644"
        case .executable: return "100755"
        case .symlink: return "120000"
        case .gitlink: return "160000"
        case .directory: return "40000"
        }
    }

    /// The octal integer representation.
    public var octal: UInt32 {
        switch self {
        case .regular: return 0o100644
        case .executable: return 0o100755
        case .symlink: return 0o120000
        case .gitlink: return 0o160000
        case .directory: return 0o040000
        }
    }
}
