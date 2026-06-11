import Foundation

// MARK: - Packfile Reader

/// Parses Git packfiles into fully-materialized objects.
///
/// Resolves both `OFS_DELTA` and `REF_DELTA` entries, including chained
/// deltas (a delta whose base is itself a delta) and thin packs (where a
/// `REF_DELTA` base lives outside the pack and is supplied via `baseLookup`).
enum GKPackfileReader {
    /// Pack entry type numbers as stored in the variable-length entry header.
    private enum PackEntryType {
        static let commit: UInt8 = 1
        static let tree: UInt8 = 2
        static let blob: UInt8 = 3
        static let tag: UInt8 = 4
        static let ofsDelta: UInt8 = 6
        static let refDelta: UInt8 = 7
    }

    /// A single parsed entry, retaining enough information to resolve deltas lazily.
    private struct RawEntry {
        /// The byte offset of this entry's header within the pack.
        let offset: Int
        /// The pack entry type number (1–4, 6, or 7).
        let typeNum: UInt8
        /// Decompressed payload: full object data for base types, delta
        /// instructions for delta types.
        let payload: Data
        /// For `OFS_DELTA`: the absolute pack offset of the base entry.
        let baseOffset: Int?
        /// For `REF_DELTA`: the OID of the base object.
        let baseOID: GKObjectID?
    }

    /// Parses a packfile into fully-materialized objects.
    /// - Parameters:
    ///   - data: The complete packfile bytes, including the 12-byte header and
    ///     trailing 20-byte SHA-1 checksum.
    ///   - baseLookup: Resolves a `REF_DELTA` base that is not contained in the
    ///     pack (a thin pack). Returns `nil` when the object is unknown.
    /// - Returns: The materialized objects, in the order their entries appear.
    /// - Throws: `GKError.packfileError` on malformed input, unresolvable
    ///   bases, or a trailer-checksum mismatch.
    static func parse(
        _ data: Data,
        baseLookup: (GKObjectID) throws -> GKRawObject? = { _ in nil }
    ) throws -> [GKRawObject] {
        let bytes = [UInt8](data)

        // Header (12 bytes) + trailer (20 bytes) at minimum.
        guard bytes.count >= 32 else {
            throw GKError.packfileError("Packfile too short")
        }

        // Signature "PACK".
        guard bytes[0] == 0x50, bytes[1] == 0x41, bytes[2] == 0x43, bytes[3] == 0x4B else {
            throw GKError.packfileError("Invalid packfile signature")
        }

        // Version (big-endian); only 2 and 3 are supported.
        let version = readUInt32BE(bytes, at: 4)
        guard version == 2 || version == 3 else {
            throw GKError.packfileError("Unsupported packfile version: \(version)")
        }

        let objectCount = Int(readUInt32BE(bytes, at: 8))

        // Verify the trailing SHA-1 over all preceding bytes before parsing.
        try verifyTrailer(bytes)

        // The body occupies everything between the header and the 20-byte trailer.
        let bodyEnd = bytes.count - 20

        // First pass: split the body into raw entries, recording each offset.
        var entries = [RawEntry]()
        entries.reserveCapacity(objectCount)
        var entryByOffset = [Int: Int]() // pack offset -> index in `entries`

        var offset = 12
        for _ in 0..<objectCount {
            guard offset < bodyEnd else {
                throw GKError.packfileError("Unexpected end of pack body")
            }
            let entryStart = offset
            let (typeNum, size, headerLen) = decodeEntryHeader(bytes, at: offset)
            offset += headerLen

            var baseOffset: Int?
            var baseOID: GKObjectID?

            switch typeNum {
            case PackEntryType.ofsDelta:
                let (negOffset, consumed) = decodeOffset(bytes, at: offset)
                offset += consumed
                let base = entryStart - negOffset
                guard base >= 0 else {
                    throw GKError.packfileError("OFS_DELTA base offset out of range")
                }
                baseOffset = base
            case PackEntryType.refDelta:
                guard offset + 20 <= bodyEnd else {
                    throw GKError.packfileError("REF_DELTA truncated base OID")
                }
                baseOID = GKObjectID(bytes: Array(bytes[offset..<offset + 20]))
                offset += 20
            default:
                break
            }

            // Decompress the zlib stream that forms this entry's payload.
            let (payload, consumed) = try GKZlib.inflateZlibStream(bytes, from: offset)
            guard payload.count == size else {
                throw GKError.packfileError(
                    "Entry size mismatch: header \(size), inflated \(payload.count)")
            }
            offset += consumed

            entryByOffset[entryStart] = entries.count
            entries.append(RawEntry(
                offset: entryStart,
                typeNum: typeNum,
                payload: payload,
                baseOffset: baseOffset,
                baseOID: baseOID
            ))
        }

        // Second pass: materialize every entry, resolving deltas on demand.
        var resolvedByOffset = [Int: GKRawObject]()
        var resolvedByOID = [GKObjectID: GKRawObject]()
        var results = [GKRawObject]()
        results.reserveCapacity(entries.count)

        for entry in entries {
            let object = try materialize(
                entry,
                entries: entries,
                entryByOffset: entryByOffset,
                resolvedByOffset: &resolvedByOffset,
                resolvedByOID: &resolvedByOID,
                baseLookup: baseLookup
            )
            results.append(object)
        }

        return results
    }

    // MARK: - Single-Object Reading

    /// Materializes a single object located at `offset` within `bytes` (the
    /// complete pack file), resolving only its delta base chain — without
    /// parsing the rest of the pack.
    /// - Parameters:
    ///   - offset: The byte offset of the entry's header within the pack.
    ///   - bytes: The complete pack file bytes.
    ///   - offsetForOID: Resolves a `REF_DELTA` base OID to an offset within
    ///     this same pack (typically backed by a `.idx`). Returns `nil` when
    ///     the base is not in this pack.
    ///   - baseLookup: Resolves a `REF_DELTA` base that lives outside this pack
    ///     (another pack or loose storage). Returns `nil` when unknown.
    /// - Returns: The fully-materialized object, inheriting its base's type.
    /// - Throws: `GKError.packfileError` when an entry is malformed or a base
    ///   cannot be resolved.
    static func readObject(
        at offset: Int,
        in bytes: [UInt8],
        offsetForOID: (GKObjectID) -> Int? = { _ in nil },
        baseLookup: (GKObjectID) throws -> GKRawObject? = { _ in nil }
    ) throws -> GKRawObject {
        // Walk the delta chain from the requested entry down to a base object,
        // collecting delta payloads (requested-first). The chain is bounded by
        // the pack's delta depth and resolved iteratively.
        var deltas = [Data]()
        var currentOffset = offset

        while true {
            let entry = try readEntryRaw(at: currentOffset, in: bytes)

            switch entry.typeNum {
            case PackEntryType.ofsDelta:
                guard let baseOffset = entry.baseOffset, baseOffset >= 0 else {
                    throw GKError.packfileError("OFS_DELTA base offset out of range")
                }
                deltas.append(entry.payload)
                currentOffset = baseOffset

            case PackEntryType.refDelta:
                guard let baseOID = entry.baseOID else {
                    throw GKError.packfileError("REF_DELTA missing base OID")
                }
                deltas.append(entry.payload)
                if let baseOffset = offsetForOID(baseOID) {
                    currentOffset = baseOffset
                } else if let external = try baseLookup(baseOID) {
                    return try applyChain(base: external, deltas: deltas)
                } else {
                    throw GKError.packfileError("REF_DELTA base not found: \(baseOID.hex)")
                }

            default:
                let base = try baseObject(typeNum: entry.typeNum, payload: entry.payload)
                return try applyChain(base: base, deltas: deltas)
            }
        }
    }

    /// Reads and inflates a single entry's header and payload at `start`.
    private static func readEntryRaw(
        at start: Int,
        in bytes: [UInt8]
    ) throws -> (typeNum: UInt8, payload: Data, baseOffset: Int?, baseOID: GKObjectID?) {
        guard start >= 0, start < bytes.count else {
            throw GKError.packfileError("Pack offset out of range")
        }

        var offset = start
        let (typeNum, size, headerLen) = decodeEntryHeader(bytes, at: offset)
        offset += headerLen

        var baseOffset: Int?
        var baseOID: GKObjectID?

        switch typeNum {
        case PackEntryType.ofsDelta:
            let (negOffset, consumed) = decodeOffset(bytes, at: offset)
            offset += consumed
            baseOffset = start - negOffset
        case PackEntryType.refDelta:
            guard offset + 20 <= bytes.count else {
                throw GKError.packfileError("REF_DELTA truncated base OID")
            }
            baseOID = GKObjectID(bytes: Array(bytes[offset..<offset + 20]))
            offset += 20
        default:
            break
        }

        let (payload, _) = try GKZlib.inflateZlibStream(bytes, from: offset)
        guard payload.count == size else {
            throw GKError.packfileError(
                "Entry size mismatch: header \(size), inflated \(payload.count)")
        }
        return (typeNum, payload, baseOffset, baseOID)
    }

    /// Applies a chain of delta payloads (requested-first) to a base object.
    /// The innermost delta (closest to the base) is applied first.
    private static func applyChain(base: GKRawObject, deltas: [Data]) throws -> GKRawObject {
        var result = base
        for payload in deltas.reversed() {
            let reconstructed = try applyDelta(base: result, delta: payload)
            // Delta results inherit the base object's type.
            result = GKRawObject(type: result.type, data: reconstructed)
        }
        return result
    }

    // MARK: - Materialization

    /// Materializes a single entry, resolving its delta chain iteratively.
    ///
    /// Uses an explicit work stack rather than recursion so that deep delta
    /// chains cannot overflow the call stack. Results are memoized by both
    /// pack offset and OID.
    private static func materialize(
        _ entry: RawEntry,
        entries: [RawEntry],
        entryByOffset: [Int: Int],
        resolvedByOffset: inout [Int: GKRawObject],
        resolvedByOID: inout [GKObjectID: GKRawObject],
        baseLookup: (GKObjectID) throws -> GKRawObject?
    ) throws -> GKRawObject {
        if let cached = resolvedByOffset[entry.offset] {
            return cached
        }

        // Build the chain of delta entries down to a resolvable base.
        var stack = [RawEntry]()
        var current = entry
        var base: GKRawObject

        while true {
            if current.typeNum == PackEntryType.ofsDelta {
                guard let baseOffset = current.baseOffset else {
                    throw GKError.packfileError("OFS_DELTA missing base offset")
                }
                if let cached = resolvedByOffset[baseOffset] {
                    base = cached
                    stack.append(current)
                    break
                }
                guard let baseIndex = entryByOffset[baseOffset] else {
                    throw GKError.packfileError("OFS_DELTA base not found in pack")
                }
                stack.append(current)
                current = entries[baseIndex]
            } else if current.typeNum == PackEntryType.refDelta {
                guard let baseOID = current.baseOID else {
                    throw GKError.packfileError("REF_DELTA missing base OID")
                }
                if let cached = resolvedByOID[baseOID] {
                    base = cached
                    stack.append(current)
                    break
                }
                if let external = try baseLookup(baseOID) {
                    base = external
                    stack.append(current)
                    break
                }
                throw GKError.packfileError("REF_DELTA base not found: \(baseOID.hex)")
            } else {
                // Reached a base object; materialize it directly.
                base = try makeBaseObject(current)
                resolvedByOffset[current.offset] = base
                resolvedByOID[base.oid] = base
                break
            }
        }

        // Apply deltas from the base outward (stack is innermost-last).
        var result = base
        while let deltaEntry = stack.popLast() {
            let reconstructed = try applyDelta(base: result, delta: deltaEntry.payload)
            // Delta results inherit the base object's type.
            result = GKRawObject(type: result.type, data: reconstructed)
            resolvedByOffset[deltaEntry.offset] = result
            resolvedByOID[result.oid] = result
        }

        return result
    }

    /// Builds a `GKRawObject` from a non-delta entry.
    private static func makeBaseObject(_ entry: RawEntry) throws -> GKRawObject {
        try baseObject(typeNum: entry.typeNum, payload: entry.payload)
    }

    /// Maps a pack base-type number to a `GKObjectType` and builds the object.
    private static func baseObject(typeNum: UInt8, payload: Data) throws -> GKRawObject {
        let type: GKObjectType
        switch typeNum {
        case PackEntryType.commit: type = .commit
        case PackEntryType.tree: type = .tree
        case PackEntryType.blob: type = .blob
        case PackEntryType.tag: type = .tag
        default:
            throw GKError.packfileError("Unknown base object type: \(typeNum)")
        }
        return GKRawObject(type: type, data: payload)
    }

    // MARK: - Delta Application

    /// Applies a Git delta to a base object's data, producing the full result.
    ///
    /// Delta format: base-size varint, result-size varint, then a sequence of
    /// instructions. A copy instruction (high bit set) copies a run from the
    /// base; an insert instruction (high bit clear) appends literal bytes.
    private static func applyDelta(base: GKRawObject, delta: Data) throws -> Data {
        let baseBytes = [UInt8](base.data)
        let d = [UInt8](delta)
        var pos = 0

        let (baseSize, baseConsumed) = decodeDeltaSize(d, at: pos)
        pos += baseConsumed
        guard baseSize == baseBytes.count else {
            throw GKError.packfileError(
                "Delta base size mismatch: header \(baseSize), actual \(baseBytes.count)")
        }

        let (resultSize, resultConsumed) = decodeDeltaSize(d, at: pos)
        pos += resultConsumed

        var output = [UInt8]()
        output.reserveCapacity(resultSize)

        while pos < d.count {
            let opcode = d[pos]
            pos += 1

            if opcode & 0x80 != 0 {
                // Copy instruction: offset and size are built from selected bytes.
                var copyOffset = 0
                var copySize = 0
                if opcode & 0x01 != 0 { copyOffset |= Int(d[pos]); pos += 1 }
                if opcode & 0x02 != 0 { copyOffset |= Int(d[pos]) << 8; pos += 1 }
                if opcode & 0x04 != 0 { copyOffset |= Int(d[pos]) << 16; pos += 1 }
                if opcode & 0x08 != 0 { copyOffset |= Int(d[pos]) << 24; pos += 1 }
                if opcode & 0x10 != 0 { copySize |= Int(d[pos]); pos += 1 }
                if opcode & 0x20 != 0 { copySize |= Int(d[pos]) << 8; pos += 1 }
                if opcode & 0x40 != 0 { copySize |= Int(d[pos]) << 16; pos += 1 }
                // A copy size of zero means 0x10000 bytes.
                if copySize == 0 { copySize = 0x10000 }

                guard copyOffset + copySize <= baseBytes.count else {
                    throw GKError.packfileError("Delta copy out of base bounds")
                }
                output.append(contentsOf: baseBytes[copyOffset..<copyOffset + copySize])
            } else if opcode != 0 {
                // Insert instruction: the opcode is the literal byte count.
                let insertSize = Int(opcode)
                guard pos + insertSize <= d.count else {
                    throw GKError.packfileError("Delta insert out of bounds")
                }
                output.append(contentsOf: d[pos..<pos + insertSize])
                pos += insertSize
            } else {
                throw GKError.packfileError("Invalid delta opcode 0x00")
            }
        }

        guard output.count == resultSize else {
            throw GKError.packfileError(
                "Delta result size mismatch: header \(resultSize), produced \(output.count)")
        }
        return Data(output)
    }

    // MARK: - Header / Varint Decoding

    /// Decodes a pack entry header: a 3-bit type plus a little-endian,
    /// 7-bits-per-byte size. Returns the type, size, and bytes consumed.
    private static func decodeEntryHeader(_ bytes: [UInt8], at start: Int) -> (type: UInt8, size: Int, length: Int) {
        var index = start
        var byte = bytes[index]
        index += 1

        let type = (byte >> 4) & 0x07
        var size = Int(byte & 0x0F)
        var shift = 4

        while byte & 0x80 != 0 {
            byte = bytes[index]
            index += 1
            size |= Int(byte & 0x7F) << shift
            shift += 7
        }

        return (type, size, index - start)
    }

    /// Decodes the `OFS_DELTA` base offset (a big-endian, 7-bits-per-byte
    /// varint with the +1 carry convention). Returns the offset and bytes consumed.
    private static func decodeOffset(_ bytes: [UInt8], at start: Int) -> (offset: Int, length: Int) {
        var index = start
        var byte = bytes[index]
        index += 1
        var value = Int(byte & 0x7F)

        while byte & 0x80 != 0 {
            value += 1
            byte = bytes[index]
            index += 1
            value = (value << 7) | Int(byte & 0x7F)
        }

        return (value, index - start)
    }

    /// Decodes a delta size field (little-endian, 7-bits-per-byte varint).
    private static func decodeDeltaSize(_ bytes: [UInt8], at start: Int) -> (size: Int, length: Int) {
        var index = start
        var size = 0
        var shift = 0
        while true {
            let byte = bytes[index]
            index += 1
            size |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        return (size, index - start)
    }

    // MARK: - Helpers

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    /// Verifies the trailing 20-byte SHA-1 over all preceding pack bytes.
    private static func verifyTrailer(_ bytes: [UInt8]) throws {
        let bodyEnd = bytes.count - 20
        let expected = Array(bytes[bodyEnd...])
        let actual = GKSHA1.hash(Data(bytes[0..<bodyEnd]))
        guard actual == expected else {
            throw GKError.packfileError("Packfile checksum mismatch")
        }
    }
}
