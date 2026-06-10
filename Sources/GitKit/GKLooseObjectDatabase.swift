import Foundation

// MARK: - Loose Object Database

/// File-system-based loose object storage (.git/objects/).
final class GKLooseObjectDatabase: GKObjectDatabase {
    let objectsURL: URL

    init(objectsURL: URL) {
        self.objectsURL = objectsURL
    }

    func read(oid: GKObjectID) throws -> GKRawObject {
        let path = objectPath(for: oid)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw GKError.objectNotFound(oid)
        }

        let compressed = try Data(contentsOf: path)
        let decompressed = try GKZlib.decompress(compressed)

        // Parse "type size\0content"
        guard let nullIdx = decompressed.firstIndex(of: 0) else {
            throw GKError.invalidObject("Missing null byte in object header")
        }

        let header = String(data: decompressed[..<nullIdx], encoding: .ascii) ?? ""
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let type = GKObjectType(rawValue: String(parts[0])) else {
            throw GKError.invalidObject("Invalid object header: \(header)")
        }

        let content = decompressed[(nullIdx + 1)...]
        return GKRawObject(type: type, data: Data(content))
    }

    func exists(oid: GKObjectID) -> Bool {
        let path = objectPath(for: oid)
        return FileManager.default.fileExists(atPath: path.path)
    }

    @discardableResult
    func write(_ object: GKRawObject) throws -> GKObjectID {
        let path = objectPath(for: object.oid)
        let dir = path.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Don't overwrite existing objects (content-addressable)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            return object.oid
        }

        let compressed = try GKZlib.compress(object.serialized)
        try compressed.write(to: path)
        return object.oid
    }

    // MARK: - Private

    private func objectPath(for oid: GKObjectID) -> URL {
        let hex = oid.hex
        let prefix = String(hex.prefix(2))
        let suffix = String(hex.dropFirst(2))
        return objectsURL.appendingPathComponent(prefix).appendingPathComponent(suffix)
    }
}
