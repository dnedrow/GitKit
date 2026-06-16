import Foundation

// MARK: - Object ID (SHA-1 Hash)

/// Represents a 20-byte SHA-1 object identifier used throughout Git.
///
/// > Security: Object IDs are SHA-1 digests. SHA-1 is no longer considered
/// > collision-resistant (see SHAttered, 2017), so identity equality alone is
/// > **not** a security boundary against a determined attacker who can craft
/// > colliding object contents. GitKit verifies that retrieved object content
/// > re-hashes to the requested OID (see ``GKLooseObjectDatabase``), which
/// > prevents tampered storage from serving content for an unrelated OID, but
/// > it cannot defend against a true SHA-1 collision. Treat OIDs as integrity
/// > checks against accidental corruption and as content addresses, not as
/// > authentication tokens. Future support for Git's SHA-256 object format is
/// > planned.
public struct GKObjectID: Hashable, Sendable {
    /// The raw 20-byte SHA-1 hash.
    public let bytes: [UInt8]

    /// The hexadecimal string representation of the SHA-1 hash.
    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A zero (null) object ID.
    public static let zero = GKObjectID(uncheckedBytes: [UInt8](repeating: 0, count: 20))

    /// Creates an object ID from raw bytes.
    ///
    /// Use this initializer for any byte buffer whose length has not already
    /// been validated — for example, bytes parsed from disk, the network, or
    /// other untrusted input. The initializer throws rather than trapping so
    /// malformed input cannot crash the process.
    ///
    /// - Parameter bytes: Exactly 20 bytes.
    /// - Throws: ``GKError/invalidObject(_:)`` if `bytes.count != 20`.
    public init(bytes: [UInt8]) throws {
        guard bytes.count == 20 else {
            throw GKError.invalidObject(
                "GKObjectID requires exactly 20 bytes, got \(bytes.count)"
            )
        }
        self.bytes = bytes
    }

    /// Internal initializer for callers that have already validated the byte
    /// count (e.g. fresh `GKSHA1.hash` output, or a slice of an already
    /// bounds-checked buffer). Asserts in debug builds, trusts the caller in
    /// release builds. Never use this with parser input.
    internal init(uncheckedBytes: [UInt8]) {
        assert(uncheckedBytes.count == 20, "GKObjectID requires exactly 20 bytes")
        self.bytes = uncheckedBytes
    }

    /// Creates an object ID from a 40-character hex string.
    /// - Parameter hex: A 40-character hexadecimal string.
    public init?(hex: String) {
        guard hex.count == 40 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(20)
        var index = hex.startIndex
        for _ in 0..<20 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }
        self.bytes = bytes
    }
}

extension GKObjectID: CustomStringConvertible {
    public var description: String { hex }
}

extension GKObjectID: Comparable {
    public static func < (lhs: GKObjectID, rhs: GKObjectID) -> Bool {
        for i in 0..<20 {
            if lhs.bytes[i] < rhs.bytes[i] { return true }
            if lhs.bytes[i] > rhs.bytes[i] { return false }
        }
        return false
    }
}
