## Why

GitKit can *write* packfiles (`GKPackfileWriter`) but cannot reliably *read* them. The current `unpackPackData(_:)` in `GKRepository+Operations.swift` is a stub that ignores delta entries (`OFS_DELTA`, `REF_DELTA`) and advances by the uncompressed size, so any pack containing deltas or more than a trivial entry desyncs and silently drops objects. Real fetches and clones produce delta-compressed (and often thin) packs, so without a correct parser `fetch`, `pull`, and `clone` cannot materialize history.

## What Changes

- Add a packfile parser that reads the `PACK` header, walks every entry by consuming each zlib stream precisely, and materializes all four base object types.
- Resolve `OFS_DELTA` entries against an earlier in-pack base located by negative offset.
- Resolve `REF_DELTA` entries against a base identified by OID, looked up either inside the pack or — for thin packs — via a caller-supplied object-database lookup.
- Support chained deltas (delta-on-delta) via iterative resolution with memoization, inheriting the materialized object's type from its ultimate base.
- Verify the trailing 20-byte SHA-1 pack checksum.
- Add a `GKZlib` helper that inflates a zlib-wrapped stream and reports total compressed bytes consumed (2-byte header + deflate body + 4-byte Adler-32 trailer) so entries can be walked.
- Rewrite `unpackPackData(_:)` to delegate to the new parser and write each fully-materialized `GKRawObject` to the object database.

## Capabilities

### New Capabilities
- `packfile-parsing`: Parsing a Git packfile into fully-materialized objects, including resolution of `OFS_DELTA` and `REF_DELTA` entries and verification of the pack trailer.

### Modified Capabilities
<!-- No existing spec capabilities change their requirements. -->

## Impact

- **New code**: `Sources/GitKit/GKPackfileReader.swift` (parser + delta engine).
- **Modified code**: `Sources/GitKit/GKZlib.swift` (add a zlib-stream inflate that reports bytes consumed); `Sources/GitKit/GKRepository+Operations.swift` (`unpackPackData(_:)` rewired to the parser).
- **Behavior**: `fetch`, `pull`, and `clone` correctly materialize delta-compressed and thin packs.
- **Errors**: Surfaces `GKError.packfileError` for malformed headers, unresolvable bases, and trailer-checksum mismatches.
- **Dependencies**: None added — remains pure Swift.
- **Tests**: New cases in `Tests/GitKitTests/GitKitTests.swift` (round-trip via `GKPackfileWriter`, OFS/REF delta resolution, thin-pack lookup, trailer verification).
