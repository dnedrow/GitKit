## Why

Reading any packed object currently forces `GKLooseObjectDatabase` to parse the **entire** packfile via `GKPackfileReader.parse` — inflating every blob/tree/commit, resolving every delta chain, and hashing the whole file for trailer verification — then caching all of it in memory. On a large repository this is `O(entire history)` work triggered by the *first* packed read, so even `sgit log -n 5` pays the full-history cost. Real Git avoids this by using the `.idx` to seek directly to a single object and inflate only it (plus its delta base chain).

## What Changes

- Add a `.idx` v2 pack index reader that maps an object's OID to its byte offset in the `.pack` (fanout table + binary search over the sorted OID table).
- Add on-demand single-object reading from a `.pack`: decode the entry header at a given offset, inflate just that entry, and resolve only its delta base chain (`OFS_DELTA` by offset, `REF_DELTA` by OID).
- Wire `GKLooseObjectDatabase` reads to use index-based random access (loose → packed-by-index), replacing the eager whole-pack materialization on the read path.
- Add a small in-memory object cache so repeated reads (and shared delta bases) are not re-inflated.
- Keep the existing whole-pack `GKPackfileReader.parse` for bulk ingestion (`unpackPackData`); it is no longer used to satisfy individual reads.

## Capabilities

### New Capabilities
- `pack-random-access`: Index-based random access to packfile objects — resolving an OID to a pack offset via the `.idx`, and materializing a single object (with its delta base chain) without parsing the whole pack.

### Modified Capabilities
<!-- No existing spec capabilities change their requirements; packfile-parsing (bulk parse) is unchanged. -->

## Impact

- **New code**: `Sources/GitKit/GKPackIndex.swift` (`.idx` v2 reader) and a single-object pack reader (new type or extension of the pack reader).
- **Modified code**: `Sources/GitKit/GKLooseObjectDatabase.swift` (read/exists use the index + object cache instead of eager full-pack parse).
- **Behavior**: `lookupCommit`/`lookupTree`/`lookupBlob` and therefore `log`, `status`, `diff` become fast on large packed repositories; first-read latency drops from `O(whole pack)` to `O(one object + its delta chain)`.
- **Performance**: removes the full-pack inflate + whole-file SHA-1 trailer hashing from the read path.
- **Dependencies**: none added — remains pure Swift.
- **Tests**: `.idx` parsing and OID→offset lookup; single-object reads for non-delta, `OFS_DELTA`, and `REF_DELTA` entries; parity between index-based reads and `GKPackfileReader.parse`; graceful fallback when no `.idx` is present.
