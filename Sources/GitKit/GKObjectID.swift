import Foundation

// MARK: - Object ID (SHA-1 Hash)

/// Represents a 20-byte SHA-1 object identifier used throughout Git.
public struct GKObjectID: Hashable, Sendable {
    /// The raw 20-byte SHA-1 hash.
    public let bytes: [UInt8]

    /// The hexadecimal string representation of the SHA-1 hash.
    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A zero (null) object ID.
    public static let zero = GKObjectID(bytes: [UInt8](repeating: 0, count: 20))

    /// Creates an object ID from raw bytes.
    /// - Parameter bytes: Exactly 20 bytes.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 20, "GKObjectID requires exactly 20 bytes")
        self.bytes = bytes
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
