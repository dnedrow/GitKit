import Foundation

// MARK: - Blob

/// Represents a Git blob object (file content).
public struct GKBlob: GKObjectProtocol, Sendable {
    public let oid: GKObjectID
    public let content: Data
    public var type: GKObjectType { .blob }

    /// Creates a blob from raw content data.
    public init(content: Data) {
        self.content = content
        let raw = GKRawObject(type: .blob, data: content)
        self.oid = raw.oid
    }

    /// Creates a blob from an existing raw object.
    init(oid: GKObjectID, data: Data) {
        self.oid = oid
        self.content = data
    }

    public func serialize() -> Data {
        content
    }

    /// The content as a UTF-8 string, if valid.
    public var text: String? {
        String(data: content, encoding: .utf8)
    }

    /// The size of the blob in bytes.
    public var size: Int {
        content.count
    }

    /// Whether this blob appears to be binary content.
    public var isBinary: Bool {
        content.contains(0)
    }
}
