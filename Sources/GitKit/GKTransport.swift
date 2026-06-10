import Foundation

// MARK: - Transport Protocol

/// Protocol for Git network transports (HTTP, SSH, file).
public protocol GKTransport {
    /// Connects to the remote and returns advertised references.
    func connect() throws -> GKRemoteAdvertisement

    /// Fetches objects from the remote.
    func fetch(wants: [GKObjectID], haves: [GKObjectID]) throws -> Data

    /// Pushes objects and updates remote references.
    func push(commands: [GKPushCommand], packData: Data) throws -> [GKPushResult]
}

/// Advertised references from a remote.
public struct GKRemoteAdvertisement: Sendable {
    public let references: [GKReference]
    public let capabilities: [String]
    public let head: GKObjectID?

    public init(references: [GKReference], capabilities: [String], head: GKObjectID? = nil) {
        self.references = references
        self.capabilities = capabilities
        self.head = head
    }
}

/// A push command (update a reference on the remote).
public struct GKPushCommand: Sendable {
    public let refName: String
    public let oldOID: GKObjectID
    public let newOID: GKObjectID

    public init(refName: String, oldOID: GKObjectID, newOID: GKObjectID) {
        self.refName = refName
        self.oldOID = oldOID
        self.newOID = newOID
    }

    /// Whether this is a delete (newOID is zero).
    public var isDelete: Bool { newOID == .zero }

    /// Whether this is a create (oldOID is zero).
    public var isCreate: Bool { oldOID == .zero }
}

/// Result of a single push command.
public struct GKPushResult: Sendable {
    public let refName: String
    public let success: Bool
    public let message: String?

    public init(refName: String, success: Bool, message: String? = nil) {
        self.refName = refName
        self.success = success
        self.message = message
    }
}

// MARK: - Pack Protocol Helpers

/// Helpers for the Git pack protocol (smart HTTP / SSH).
enum GKPackProtocol {
    /// Parses pkt-line format data.
    static func parsePktLines(_ data: Data) -> [Data] {
        var lines = [Data]()
        var offset = 0
        let bytes = Array(data)

        while offset + 4 <= bytes.count {
            let lenHex = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? "0000"
            guard let length = Int(lenHex, radix: 16) else { break }

            if length == 0 {
                // Flush packet
                offset += 4
                continue
            }

            let lineData = Data(bytes[offset + 4..<offset + length])
            lines.append(lineData)
            offset += length
        }

        return lines
    }

    /// Encodes data as a pkt-line.
    static func pktLine(_ content: String) -> Data {
        let length = content.utf8.count + 4
        let header = String(format: "%04x", length)
        return Data((header + content).utf8)
    }

    /// Flush packet (0000).
    static var flushPacket: Data {
        Data("0000".utf8)
    }
}

// MARK: - Packfile

/// Writes objects into Git packfile format.
enum GKPackfileWriter {
    /// Creates a packfile from a list of objects.
    static func createPackfile(objects: [GKRawObject]) throws -> Data {
        var data = Data()

        // Header: "PACK" + version (2) + object count
        data.append(contentsOf: [0x50, 0x41, 0x43, 0x4B]) // "PACK"
        appendUInt32(&data, 2) // version 2
        appendUInt32(&data, UInt32(objects.count))

        // Objects
        for object in objects {
            let compressed = try GKZlib.compress(object.data)
            let typeNum = packObjectType(object.type)

            // Encode object header (variable-length encoding)
            var size = object.data.count
            var byte = UInt8(Int(typeNum) << 4 | (size & 0x0F))
            size >>= 4

            if size > 0 {
                byte |= 0x80
            }
            data.append(byte)

            while size > 0 {
                byte = UInt8(size & 0x7F)
                size >>= 7
                if size > 0 { byte |= 0x80 }
                data.append(byte)
            }

            // Compressed data (skip zlib header for pack format? No, git uses raw deflate in packs)
            // Actually, packfiles use zlib-compressed data
            data.append(compressed)
        }

        // Trailing SHA-1 checksum
        let checksum = GKSHA1.hash(data)
        data.append(contentsOf: checksum)

        return data
    }

    private static func packObjectType(_ type: GKObjectType) -> UInt8 {
        switch type {
        case .commit: return 1
        case .tree: return 2
        case .blob: return 3
        case .tag: return 4
        }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
