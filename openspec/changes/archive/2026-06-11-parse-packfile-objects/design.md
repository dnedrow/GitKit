## Context

GitKit ships `GKPackfileWriter` (in `GKTransport.swift`) but has no working reader. `GKRepository+Operations.unpackPackData(_:)` is a stub that: only handles base types 1–4, ignores `OFS_DELTA` (6) and `REF_DELTA` (7), advances the read cursor by the *uncompressed* size (`offset += size`), and reconstructs a zlib header with a `[0x78, 0x01]` prefix passed through `try?`. As a result, any pack with deltas or multiple entries desyncs and silently drops objects, leaving `fetch`/`pull`/`clone` unable to materialize real (delta-compressed, often thin) packs.

Relevant existing primitives:
- `GKZlib.inflateRaw(_:) -> (data: Data, bytesRead: Int)` already inflates a raw deflate stream and reports compressed bytes consumed — the missing piece for walking concatenated entries.
- `GKRawObject(type:data:)` computes the OID; `GKObjectType` enumerates the four base types.
- `GKSHA1.hash(_:)` is available for trailer verification.
- `GKError.packfileError(String)` already exists for error reporting.

## Goals / Non-Goals

**Goals:**
- Parse a v2/v3 packfile into fully-materialized `[GKRawObject]`.
- Resolve `OFS_DELTA` and `REF_DELTA`, including chained deltas.
- Support thin packs via a caller-supplied base lookup.
- Verify the trailing SHA-1 checksum.
- Rewire `unpackPackData(_:)` onto the new parser.
- Stay pure Swift; follow the `GK` prefix and protocol-first conventions.

**Non-Goals:**
- Writing or reading `.idx` pack index files.
- Streaming/incremental parsing of partial packs.
- Packfile generation changes (`GKPackfileWriter` is unchanged).
- Performance tuning beyond avoiding stack-unbounded recursion.

## Decisions

### New file `GKPackfileReader.swift`
A dedicated `enum GKPackfileReader` mirrors `GKPackfileWriter` and keeps the parser/delta engine in one place, matching the project's one-responsibility-per-file map.

- *Alternative:* extend `GKTransport.swift` (where the writer lives). Rejected — the file would grow two unrelated concerns and the file map favors focused files.

### Entry API takes a base-lookup closure
```swift
static func parse(
    _ data: Data,
    baseLookup: (GKObjectID) throws -> GKRawObject? = { _ in nil }
) throws -> [GKRawObject]
```
The closure resolves `REF_DELTA` bases that live outside the pack (thin packs). `unpackPackData` passes `objectDB.read` (wrapped to return `nil` on `objectNotFound`).

- *Alternative:* require all bases in-pack. Rejected — real fetch responses are thin packs.

### zlib-stream helper in `GKZlib`
Add `inflateZlibStream(_:) -> (data: Data, bytesRead: Int)` that validates the 2-byte zlib header, calls existing `inflateRaw` on the body, and reports `2 + deflateBytes + 4` (header + deflate + Adler-32 trailer) so the parser lands exactly on the next entry. Centralizes the byte math next to the existing inflate code.

- *Alternative:* do the +2/+4 accounting inline in the parser. Rejected — spreads zlib framing knowledge into the parser.

### Deferred resolution with memoization, keyed by offset and OID
Single forward pass records each entry by its **pack offset** and, once materialized, by **OID**. Delta entries whose base is not yet materialized are resolved on demand by recursively materializing the base (offset for `OFS_DELTA`, OID for `REF_DELTA`), with results memoized. Resolution is implemented iteratively (explicit work stack) to avoid unbounded recursion on deep delta chains.

- *Alternative:* assume bases always precede deltas in a single linear pass. Rejected — not guaranteed, and chained deltas need on-demand resolution.

### Delta application
Decode base-size and result-size varints, then loop instructions: high-bit-set = copy (decode offset/size from the selector bitfield, copy run from base), high-bit-clear = insert (append next N literal bytes). Validate that output length equals the decoded result size. Materialized type is inherited from the resolved base.

### Trailer verification
Compute `GKSHA1.hash` over all bytes preceding the final 20 and compare to the trailing 20 bytes; mismatch throws `GKError.packfileError`.

## Risks / Trade-offs

- **Adler-32 trailer offset miscount** → The zlib helper centralizes `+2/+4` accounting and is covered by a writer→reader round-trip test.
- **Wrong type for delta results** → Spec + tests assert the materialized type equals the base's type.
- **Deep delta chains causing stack overflow** → Iterative resolution with an explicit work stack instead of recursion.
- **Thin-pack base missing at apply time** → Parser throws `GKError.packfileError` with the unresolved OID rather than silently dropping the object.
- **Overlapping copies / large runs in delta apply** → Append-based copy loop (same approach as existing deflate back-references); covered by a delta unit test.
