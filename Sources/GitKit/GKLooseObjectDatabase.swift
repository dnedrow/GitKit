import Foundation

// MARK: - Loose Object Database

/// File-system-based object storage for `.git/objects/`.
///
/// Objects are written as loose files. Reads consult, in order: an in-memory
/// cache, loose storage, packfiles via their `.idx` (reading only the requested
/// object and its delta base chain), and finally a whole-pack parse for any
/// `.pack` that lacks a usable index.
final class GKLooseObjectDatabase: GKObjectDatabase {
    let objectsURL: URL

    /// Materialized objects cached for this instance's lifetime. Objects are
    /// content-addressed and immutable, so caching by OID is always safe.
    private var cache: [GKObjectID: GKRawObject] = [:]

    /// Packs that have a usable `.idx`, paired with their pack bytes. Loaded lazily.
    private var indexedPacks: [(index: GKPackIndex, bytes: [UInt8])]?

    /// Objects from packs that have no usable `.idx`, materialized by a
    /// whole-pack parse as a correctness fallback. Loaded lazily.
    private var indexlessPackObjects: [GKObjectID: GKRawObject]?

    init(objectsURL: URL) {
        self.objectsURL = objectsURL
    }

    func read(oid: GKObjectID) throws -> GKRawObject {
        if let cached = cache[oid] {
            return cached
        }
        if let loose = try readLoose(oid: oid) {
            cache[oid] = loose
            return loose
        }
        if let packed = try readFromIndexedPacks(oid: oid) {
            cache[oid] = packed
            return packed
        }
        if let fallback = indexlessObject(for: oid) {
            cache[oid] = fallback
            return fallback
        }
        throw GKError.objectNotFound(oid)
    }

    func exists(oid: GKObjectID) -> Bool {
        if cache[oid] != nil {
            return true
        }
        if FileManager.default.fileExists(atPath: objectPath(for: oid).path) {
            return true
        }
        loadIndexedPacksIfNeeded()
        if indexedPacks?.contains(where: { $0.index.contains(oid) }) == true {
            return true
        }
        return indexlessObject(for: oid) != nil
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

    // MARK: - Loose Reading

    /// Reads an object from loose storage, or returns `nil` if it is not present.
    private func readLoose(oid: GKObjectID) throws -> GKRawObject? {
        let path = objectPath(for: oid)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
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

    // MARK: - Indexed Packfile Reading

    /// Reads a single object from any indexed pack that contains it, resolving
    /// only the object and its delta base chain.
    private func readFromIndexedPacks(oid: GKObjectID) throws -> GKRawObject? {
        loadIndexedPacksIfNeeded()
        guard let packs = indexedPacks else { return nil }

        for pack in packs {
            guard let offset = pack.index.offset(for: oid) else { continue }
            return try GKPackfileReader.readObject(
                at: Int(offset),
                in: pack.bytes,
                offsetForOID: { pack.index.offset(for: $0).map(Int.init) },
                baseLookup: { [weak self] base in try self?.resolveDeltaBase(oid: base) }
            )
        }
        return nil
    }

    /// Resolves a `REF_DELTA` base that lives outside the current pack: from the
    /// cache, loose storage, another indexed pack, or an index-less pack.
    private func resolveDeltaBase(oid: GKObjectID) throws -> GKRawObject? {
        if let cached = cache[oid] { return cached }
        if let loose = try readLoose(oid: oid) { return loose }
        if let packed = try readFromIndexedPacks(oid: oid) { return packed }
        return indexlessObject(for: oid)
    }

    /// Loads packs that have a usable `.idx`, reading both index and pack bytes.
    private func loadIndexedPacksIfNeeded() {
        guard indexedPacks == nil else { return }

        var packs = [(index: GKPackIndex, bytes: [UInt8])]()
        for packURL in packURLs() {
            let idxURL = packURL.deletingPathExtension().appendingPathExtension("idx")
            guard let idxData = try? Data(contentsOf: idxURL),
                  let index = try? GKPackIndex(data: idxData),
                  let packData = try? Data(contentsOf: packURL) else { continue }
            packs.append((index, [UInt8](packData)))
        }
        indexedPacks = packs
    }

    // MARK: - Index-less Packfile Fallback

    /// Returns an object from an index-less pack, parsing such packs on first use.
    private func indexlessObject(for oid: GKObjectID) -> GKRawObject? {
        loadIndexlessPacksIfNeeded()
        return indexlessPackObjects?[oid]
    }

    /// Whole-pack parses any `.pack` that has no usable `.idx`, so reads stay
    /// correct even without an index. `REF_DELTA` bases outside a pack resolve
    /// against loose storage.
    private func loadIndexlessPacksIfNeeded() {
        guard indexlessPackObjects == nil else { return }

        var objects = [GKObjectID: GKRawObject]()
        for packURL in packURLs() {
            let idxURL = packURL.deletingPathExtension().appendingPathExtension("idx")
            // Skip packs that already have a usable index — those use random access.
            let hasIndex = (try? Data(contentsOf: idxURL)).flatMap { try? GKPackIndex(data: $0) } != nil
            if hasIndex { continue }

            guard let data = try? Data(contentsOf: packURL),
                  let parsed = try? GKPackfileReader.parse(data, baseLookup: { [weak self] oid in
                    try self?.readLoose(oid: oid)
                  }) else { continue }

            for object in parsed {
                objects[object.oid] = object
            }
        }
        indexlessPackObjects = objects
    }

    // MARK: - Private

    /// All `.pack` files under `objects/pack/`.
    private func packURLs() -> [URL] {
        let packDir = objectsURL.appendingPathComponent("pack")
        return (try? FileManager.default.contentsOfDirectory(
            at: packDir,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "pack" } ?? []
    }

    private func objectPath(for oid: GKObjectID) -> URL {
        let hex = oid.hex
        let prefix = String(hex.prefix(2))
        let suffix = String(hex.dropFirst(2))
        return objectsURL.appendingPathComponent(prefix).appendingPathComponent(suffix)
    }
}
