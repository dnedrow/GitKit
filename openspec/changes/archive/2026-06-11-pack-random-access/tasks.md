## 1. Pack index reader

- [x] 1.1 Create `Sources/GitKit/GKPackIndex.swift` with a type that loads a `.idx` file and validates the `\377tOc` magic and version 2; throw `GKError.packfileError` otherwise
- [x] 1.2 Parse the 256-entry fanout table, the sorted 20-byte OID table, the CRC table, and the 4-byte offset table
- [x] 1.3 Implement `offset(for: GKObjectID) -> UInt64?` using fanout-bounded binary search, resolving 8-byte large offsets when the high bit of a 4-byte offset is set
- [x] 1.4 Implement `contains(_ oid: GKObjectID) -> Bool`

## 2. Single-object pack reading

- [x] 2.1 Extract/share `GKPackfileReader`'s entry-header decode, offset-varint decode, and delta-apply logic so it can be reused without duplication
- [x] 2.2 Add a single-object reader that, given pack bytes and a byte offset, decodes the entry header and inflates only that entry via `GKZlib.inflateZlibStream`
- [x] 2.3 Resolve `OFS_DELTA` bases by reading `entryOffset - negOffset` within the same pack (iteratively for chains)
- [x] 2.4 Resolve `REF_DELTA` bases by OID via the owning `GKPackIndex`, else a caller-supplied `baseLookup`; throw `GKError.packfileError` when unresolvable
- [x] 2.5 Apply the delta and return a `GKRawObject` that inherits the base object's type

## 3. Object database integration

- [x] 3.1 In `GKLooseObjectDatabase`, enumerate `objects/pack/*.idx` and, on a loose miss, locate the pack whose index contains the OID
- [x] 3.2 Read the single requested object by offset (with delta base chain), replacing eager whole-pack parsing on the read path
- [x] 3.3 Resolve `REF_DELTA` bases via the pack index, then loose storage, then other packs
- [x] 3.4 Fall back to whole-pack `GKPackfileReader.parse` for any `.pack` that lacks a usable `.idx`
- [x] 3.5 Update `exists(oid:)` to report membership via loose storage and pack indexes
- [x] 3.6 Add an in-memory `[GKObjectID: GKRawObject]` cache populated by loose, indexed, and fallback reads

## 4. Tests

- [x] 4.1 `.idx` parsing test: validate magic/version and `offset(for:)`/`contains(_:)` against a real index
- [x] 4.2 Single-object read tests: non-delta, `OFS_DELTA`, `REF_DELTA` (in-pack and via `baseLookup`), and a chained delta
- [x] 4.3 Parity test: index-based reads return objects equal (by OID and data) to `GKPackfileReader.parse` for the same pack
- [x] 4.4 Fallback test: a `.pack` with no `.idx` still resolves packed objects correctly
- [x] 4.5 Cache test: repeated reads of the same OID are served without re-inflation
- [x] 4.6 Run `swift build` and `swift test`; fix any failures
