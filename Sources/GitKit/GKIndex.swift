import Foundation

// MARK: - Index (Staging Area)

/// Protocol for the Git index (staging area).
public protocol GKIndexProtocol {
    /// All entries in the index.
    var entries: [GKIndexEntry] { get }

    /// Adds a file to the index.
    mutating func add(path: String, oid: GKObjectID, mode: GKFileMode, stat: GKFileStat) throws

    /// Removes a file from the index.
    mutating func remove(path: String) throws

    /// Clears all entries.
    mutating func clear()

    /// Writes the index to disk.
    func write(to url: URL) throws

    /// Builds a tree from the current index state.
    func writeTree(objectDB: GKObjectDatabase) throws -> GKObjectID
}

// MARK: - Index Entry

/// A single entry in the Git index.
public struct GKIndexEntry: Sendable, Equatable, Comparable {
    public let mode: GKFileMode
    public let oid: GKObjectID
    public let path: String
    public let flags: GKIndexEntryFlags
    public var stat: GKFileStat

    public init(
        mode: GKFileMode,
        oid: GKObjectID,
        path: String,
        flags: GKIndexEntryFlags = GKIndexEntryFlags(),
        stat: GKFileStat = .empty
    ) {
        self.mode = mode
        self.oid = oid
        self.path = path
        self.flags = flags
        self.stat = stat
    }

    public static func < (lhs: GKIndexEntry, rhs: GKIndexEntry) -> Bool {
        if lhs.path == rhs.path {
            return lhs.flags.stage < rhs.flags.stage
        }
        return lhs.path < rhs.path
    }
}

// MARK: - Index Entry Flags

/// Flags for an index entry.
public struct GKIndexEntryFlags: Sendable, Equatable {
    public let assumeValid: Bool
    public let extended: Bool
    public let stage: UInt8 // 0-3
    public let nameLength: UInt16

    public init(assumeValid: Bool = false, extended: Bool = false, stage: UInt8 = 0, nameLength: UInt16 = 0) {
        self.assumeValid = assumeValid
        self.extended = extended
        self.stage = stage
        self.nameLength = nameLength
    }

    /// Pack flags into a 16-bit value.
    var packed: UInt16 {
        var value: UInt16 = 0
        if assumeValid { value |= 0x8000 }
        if extended { value |= 0x4000 }
        value |= UInt16(stage & 0x03) << 12
        value |= min(nameLength, 0xFFF)
        return value
    }

    /// Unpack flags from a 16-bit value.
    init(packed: UInt16) {
        self.assumeValid = (packed & 0x8000) != 0
        self.extended = (packed & 0x4000) != 0
        self.stage = UInt8((packed >> 12) & 0x03)
        self.nameLength = packed & 0x0FFF
    }
}

// MARK: - Index Implementation

/// The Git index file implementation.
public struct GKIndex: GKIndexProtocol {
    public private(set) var entries: [GKIndexEntry]
    private let version: UInt32

    /// The index file signature "DIRC".
    static let signature: [UInt8] = [0x44, 0x49, 0x52, 0x43]

    public init() {
        self.entries = []
        self.version = 2
    }

    /// Reads an index from disk.
    public init(from url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    /// Parses index from raw data.
    init(data: Data) throws {
        let bytes = Array(data)
        guard bytes.count >= 12 else {
            throw GKError.indexError("Index file too short")
        }

        // Verify signature "DIRC"
        guard Array(bytes[0..<4]) == GKIndex.signature else {
            throw GKError.indexError("Invalid index signature")
        }

        // Version
        let version = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 |
            UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard version == 2 || version == 3 || version == 4 else {
            throw GKError.indexError("Unsupported index version: \(version)")
        }
        self.version = version

        // Entry count
        let entryCount = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 |
                                UInt32(bytes[10]) << 8 | UInt32(bytes[11]))

        var entries = [GKIndexEntry]()
        var offset = 12

        for _ in 0..<entryCount {
            let entryStart = offset

            guard offset + 62 <= bytes.count else {
                throw GKError.indexError("Truncated index entry")
            }

            let ctimeS = Self.readUInt32(bytes, at: offset); offset += 4
            let ctimeN = Self.readUInt32(bytes, at: offset); offset += 4
            let mtimeS = Self.readUInt32(bytes, at: offset); offset += 4
            let mtimeN = Self.readUInt32(bytes, at: offset); offset += 4
            let dev = Self.readUInt32(bytes, at: offset); offset += 4
            let ino = Self.readUInt32(bytes, at: offset); offset += 4
            let modeRaw = Self.readUInt32(bytes, at: offset); offset += 4
            let uid = Self.readUInt32(bytes, at: offset); offset += 4
            let gid = Self.readUInt32(bytes, at: offset); offset += 4
            let size = Self.readUInt32(bytes, at: offset); offset += 4

            let oidBytes = Array(bytes[offset..<offset + 20]); offset += 20
            let oid = GKObjectID(bytes: oidBytes)

            let flagsPacked = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]); offset += 2
            let flags = GKIndexEntryFlags(packed: flagsPacked)

            // Read path (null-terminated)
            var nameEnd = offset
            while nameEnd < bytes.count && bytes[nameEnd] != 0 {
                nameEnd += 1
            }
            let path = String(bytes: bytes[offset..<nameEnd], encoding: .utf8) ?? ""
            offset = nameEnd + 1

            // Entries are padded to 8-byte boundaries
            let entrySize = offset - entryStart
            let padding = (8 - (entrySize % 8)) % 8
            offset += padding

            let mode: GKFileMode
            let modeOctal = String(modeRaw, radix: 8)
            if let m = GKFileMode(rawValue: modeOctal) {
                mode = m
            } else {
                mode = .regular
            }

            entries.append(GKIndexEntry(
                mode: mode, oid: oid, path: path, flags: flags,
                stat: GKFileStat(
                    ctimeSeconds: ctimeS, ctimeNanoseconds: ctimeN,
                    mtimeSeconds: mtimeS, mtimeNanoseconds: mtimeN,
                    dev: dev, ino: ino, uid: uid, gid: gid, fileSize: size
                )
            ))
        }

        self.entries = entries.sorted()
    }

    public mutating func add(path: String, oid: GKObjectID, mode: GKFileMode, stat: GKFileStat = .empty) throws {
        // Remove existing entry with same path and stage 0
        entries.removeAll { $0.path == path && $0.flags.stage == 0 }

        let flags = GKIndexEntryFlags(nameLength: UInt16(min(path.utf8.count, 0xFFF)))

        let entry = GKIndexEntry(
            mode: mode, oid: oid, path: path, flags: flags, stat: stat
        )
        entries.append(entry)
        entries.sort()
    }

    /// Marks "racily clean" entries so a subsequent status verifies them by
    /// content. Any entry whose cached mtime is at or after the index file's own
    /// mtime could have been modified within the same timestamp tick; its cached
    /// file size is zeroed ("smudged") so it never matches a real file on disk.
    ///
    /// - Parameter indexMtimeSeconds: The mtime (seconds) the index file has (or
    ///   will have) on disk.
    public mutating func smudgeRacilyCleanEntries(indexMtimeSeconds: UInt32) {
        for i in entries.indices where !entries[i].stat.isEmpty {
            if entries[i].stat.isRacyClean(indexMtimeSeconds: indexMtimeSeconds) {
                entries[i].stat.fileSize = 0
            }
        }
    }

    public mutating func remove(path: String) throws {
        let before = entries.count
        entries.removeAll { $0.path == path }
        if entries.count == before {
            throw GKError.indexError("Path not in index: \(path)")
        }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public func write(to url: URL) throws {
        var data = Data()

        // Header
        data.append(contentsOf: GKIndex.signature)
        Self.appendUInt32(&data, version)
        Self.appendUInt32(&data, UInt32(entries.count))

        // Entries
        for entry in entries {
            let entryStart = data.count
            Self.appendUInt32(&data, entry.stat.ctimeSeconds)
            Self.appendUInt32(&data, entry.stat.ctimeNanoseconds)
            Self.appendUInt32(&data, entry.stat.mtimeSeconds)
            Self.appendUInt32(&data, entry.stat.mtimeNanoseconds)
            Self.appendUInt32(&data, entry.stat.dev)
            Self.appendUInt32(&data, entry.stat.ino)
            Self.appendUInt32(&data, entry.mode.octal)
            Self.appendUInt32(&data, entry.stat.uid)
            Self.appendUInt32(&data, entry.stat.gid)
            Self.appendUInt32(&data, entry.stat.fileSize)
            data.append(contentsOf: entry.oid.bytes)

            let flagValue = entry.flags.packed
            data.append(UInt8(flagValue >> 8))
            data.append(UInt8(flagValue & 0xFF))

            data.append(contentsOf: entry.path.utf8)
            data.append(0) // null terminator

            // Pad to 8-byte boundary
            let entrySize = data.count - entryStart
            let padding = (8 - (entrySize % 8)) % 8
            data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }

        // Checksum
        let checksum = GKSHA1.hash(data)
        data.append(contentsOf: checksum)

        try data.write(to: url)
    }

    public func writeTree(objectDB: GKObjectDatabase) throws -> GKObjectID {
        try writeTreeRecursive(entries: entries, prefix: "", objectDB: objectDB)
    }

    private func writeTreeRecursive(entries: [GKIndexEntry], prefix: String, objectDB: GKObjectDatabase) throws -> GKObjectID {
        var treeEntries = [GKTreeEntry]()
        var i = 0

        while i < entries.count {
            let entry = entries[i]
            let relativePath = prefix.isEmpty ? entry.path : String(entry.path.dropFirst(prefix.count))

            if let slashIdx = relativePath.firstIndex(of: "/") {
                // This is a subtree
                let dirName = String(relativePath[..<slashIdx])
                let subPrefix = prefix + dirName + "/"

                // Collect all entries under this subtree
                var subEntries = [GKIndexEntry]()
                while i < entries.count && entries[i].path.hasPrefix(subPrefix) {
                    subEntries.append(entries[i])
                    i += 1
                }

                let subtreeOID = try writeTreeRecursive(entries: subEntries, prefix: subPrefix, objectDB: objectDB)
                treeEntries.append(GKTreeEntry(mode: .directory, name: dirName, oid: subtreeOID))
            } else {
                // This is a blob entry
                treeEntries.append(GKTreeEntry(mode: entry.mode, name: relativePath, oid: entry.oid))
                i += 1
            }
        }

        let tree = GKTree(entries: treeEntries)
        let rawObject = GKRawObject(type: .tree, data: tree.serialize())
        try objectDB.write(rawObject)
        return rawObject.oid
    }

    // MARK: - Helpers

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
