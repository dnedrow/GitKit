import Foundation

// MARK: - Pack Index (.idx v2)

/// Reads a Git pack index version 2 (`.idx`) file, mapping an object's OID to
/// its byte offset within the corresponding `.pack`.
///
/// The v2 layout is:
/// ```
/// 4   magic   \377tOc
/// 4   version 2
/// 256×4  fanout (cumulative object counts by first OID byte)
/// N×20   sorted object IDs
/// N×4    CRC32 of each packed object
/// N×4    4-byte offsets (high bit set ⇒ index into large-offset table)
/// M×8    8-byte large offsets
/// 20     packfile SHA-1
/// 20     index SHA-1
/// ```
struct GKPackIndex {
    private let data: [UInt8]
    private let count: Int
    private let fanout: [Int]
    private let oidTableStart: Int
    private let offsetTableStart: Int
    private let largeOffsetTableStart: Int

    /// Parses a `.idx` v2 file.
    /// - Throws: `GKError.packfileError` if the magic or version is invalid.
    init(data rawData: Data) throws {
        let bytes = [UInt8](rawData)
        guard bytes.count >= 8 + 256 * 4 else {
            throw GKError.packfileError("Pack index too short")
        }

        // Magic: \377tOc
        guard bytes[0] == 0xFF, bytes[1] == 0x74, bytes[2] == 0x4F, bytes[3] == 0x63 else {
            throw GKError.packfileError("Invalid pack index signature")
        }

        let version = GKPackIndex.readUInt32BE(bytes, at: 4)
        guard version == 2 else {
            throw GKError.packfileError("Unsupported pack index version: \(version)")
        }

        // 256-entry fanout table.
        var fan = [Int]()
        fan.reserveCapacity(256)
        var p = 8
        for _ in 0..<256 {
            fan.append(Int(GKPackIndex.readUInt32BE(bytes, at: p)))
            p += 4
        }

        let n = fan[255]
        let oidStart = 8 + 256 * 4
        let crcStart = oidStart + n * 20
        let offStart = crcStart + n * 4
        let largeStart = offStart + n * 4

        // Must at least contain the offset table and trailing checksums.
        guard bytes.count >= largeStart + 40 else {
            throw GKError.packfileError("Pack index truncated")
        }

        self.data = bytes
        self.count = n
        self.fanout = fan
        self.oidTableStart = oidStart
        self.offsetTableStart = offStart
        self.largeOffsetTableStart = largeStart
    }

    /// The number of objects indexed.
    var objectCount: Int { count }

    /// Returns the byte offset of `oid` within the `.pack`, or `nil` if the
    /// object is not present in this index.
    func offset(for oid: GKObjectID) -> UInt64? {
        guard count > 0 else { return nil }

        // Narrow the search window using the fanout table.
        let first = Int(oid.bytes[0])
        var lo = first == 0 ? 0 : fanout[first - 1]
        var hi = fanout[first]

        while lo < hi {
            let mid = (lo + hi) / 2
            switch compareOID(at: mid, with: oid.bytes) {
            case 0: return resolveOffset(at: mid)
            case let c where c < 0: lo = mid + 1
            default: hi = mid
            }
        }
        return nil
    }

    /// Whether `oid` is present in this index.
    func contains(_ oid: GKObjectID) -> Bool {
        offset(for: oid) != nil
    }

    // MARK: - Private

    /// Compares the stored OID at `index` with `target`: -1, 0, or 1.
    private func compareOID(at index: Int, with target: [UInt8]) -> Int {
        let base = oidTableStart + index * 20
        for i in 0..<20 {
            let a = data[base + i]
            let b = target[i]
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }

    /// Resolves the pack offset for the object at table `index`, following the
    /// large-offset table when the 4-byte offset has its high bit set.
    private func resolveOffset(at index: Int) -> UInt64 {
        let raw = GKPackIndex.readUInt32BE(data, at: offsetTableStart + index * 4)
        if raw & 0x8000_0000 == 0 {
            return UInt64(raw)
        }
        let largeIndex = Int(raw & 0x7FFF_FFFF)
        return GKPackIndex.readUInt64BE(data, at: largeOffsetTableStart + largeIndex * 8)
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func readUInt64BE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }
}
