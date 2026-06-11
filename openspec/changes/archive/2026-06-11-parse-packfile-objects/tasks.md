## 1. zlib stream support

- [x] 1.1 Add `GKZlib.inflateZlibStream(_:) -> (data: Data, bytesRead: Int)` that validates the 2-byte zlib header, inflates the body via existing `inflateRaw`, and returns total bytes consumed (2 header + deflate body + 4 Adler-32 trailer)
- [x] 1.2 Add a unit test asserting `inflateZlibStream` round-trips `GKZlib.compress` output and reports the exact compressed byte count

## 2. Packfile reader scaffold

- [x] 2.1 Create `Sources/GitKit/GKPackfileReader.swift` with `enum GKPackfileReader` and the entry point `parse(_:baseLookup:) throws -> [GKRawObject]`
- [x] 2.2 Implement header parsing: validate `PACK` signature, accept version 2/3, read big-endian object count; throw `GKError.packfileError` otherwise
- [x] 2.3 Implement the variable-length entry header decode (3-bit type + size varint) and map type numbers 1–4 to `GKObjectType`

## 3. Entry walking and base objects

- [x] 3.1 Walk all entries using `inflateZlibStream` to advance the cursor precisely, recording each entry's starting pack offset
- [x] 3.2 Materialize non-delta entries (types 1–4) into `GKRawObject`, verifying decompressed length equals the header size
- [x] 3.3 Verify the trailing 20-byte SHA-1 checksum over preceding bytes; throw `GKError.packfileError` on mismatch

## 4. Delta resolution

- [x] 4.1 Decode `OFS_DELTA` (type 6) negative base offset and locate the in-pack base at `entryOffset - offset`
- [x] 4.2 Decode `REF_DELTA` (type 7) 20-byte base OID; resolve from the pack, else from `baseLookup`; throw `GKError.packfileError` if unresolvable
- [x] 4.3 Implement the delta apply engine: base-size/result-size varints, copy and insert instructions, output-length validation
- [x] 4.4 Implement deferred resolution with memoization (keyed by offset and OID) using an iterative work stack to handle chained deltas and out-of-order bases
- [x] 4.5 Ensure materialized delta results inherit the base object's type

## 5. Repository integration

- [x] 5.1 Rewrite `GKRepository+Operations.unpackPackData(_:)` to call `GKPackfileReader.parse`, passing the object database as the thin-pack `baseLookup`, and write each materialized object to the ODB

## 6. Tests

- [x] 6.1 Round-trip test: encode base objects with `GKPackfileWriter`, parse them back, assert OIDs match
- [x] 6.2 `OFS_DELTA` test: parse a pack with an offset-delta entry and assert the reconstructed object and inherited type
- [x] 6.3 `REF_DELTA` test: in-pack base resolution and thin-pack resolution via `baseLookup`; assert unresolvable base throws `GKError.packfileError`
- [x] 6.4 Chained-delta test: delta-on-delta resolves to the correct final object
- [x] 6.5 Trailer test: corrupted trailing checksum throws `GKError.packfileError`
- [x] 6.6 Run `swift build` and `swift test`; fix any failures
