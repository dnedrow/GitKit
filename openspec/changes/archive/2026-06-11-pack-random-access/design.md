## Context

`GKLooseObjectDatabase` was recently extended to read packed objects, but it does so by calling `GKPackfileReader.parse` on the **entire** `.pack` the first time any packed object is missed from loose storage. That parse inflates every entry, resolves every delta chain, hashes the whole file for trailer verification, and caches all objects in memory. Confirmed cost profile:

- `sgit log` calls `repo.log(from: nil, maxCount: 50)` — a bounded BFS — and never uses `GKRevisionWalker`. So the walk is not the bottleneck.
- The first packed-object read inside that BFS triggers full-pack materialization, making `log` (even `-n 5`) pay `O(entire history)` on large repos.

Git solves this with the pack index (`.idx`): a sorted OID table with a 256-entry fanout, enabling `OID → offset` lookups, then inflating only the requested object and its delta base chain.

Relevant existing primitives:
- `GKZlib.inflateZlibStream(_:) -> (data, bytesRead)` — inflate one entry, report bytes consumed.
- `GKPackfileReader` — whole-pack parser and delta-apply engine (to be retained for bulk ingestion).
- `GKRawObject`, `GKObjectType`, `GKObjectID`, `GKError.packfileError`.

## Goals / Non-Goals

**Goals:**
- `.idx` v2 reader exposing `OID → pack offset`.
- Single-object reads from a `.pack` by offset, resolving only the delta base chain.
- Make `GKLooseObjectDatabase` reads index-based (loose → packed-by-index), removing the eager whole-pack parse from the read path.
- Add an in-memory object cache.
- Remain pure Swift; preserve the `GK` prefix and protocol-first conventions.

**Non-Goals:**
- Writing `.idx` files or `.idx` v1 support.
- Using the `.rev` reverse-index file.
- mmap/partial file I/O optimization (read the `.pack` into memory is acceptable; the win is avoiding full inflate/delta work).
- Changing `GKRevisionWalker` (not on the `sgit log` path).

## Decisions

### New `GKPackIndex.swift` (`.idx` v2 reader)
Parses magic (`\377tOc`) + version 2, the 256-entry fanout, the sorted 20-byte OID table, CRCs, 4-byte offsets, and the 8-byte large-offset table. Exposes `offset(for: GKObjectID) -> UInt64?` via fanout-bounded binary search and `contains(_:)`.

- *Alternative:* scan the `.pack` linearly to build an offset map. Rejected — that is the very full-pass cost we are removing.

### Single-object pack reader
A reader bound to a `.pack`'s bytes that, given an offset, decodes the entry header, inflates one zlib stream, and for deltas resolves the base by recursing to `entryOffset - negOffset` (`OFS_DELTA`) or by OID through the owning `GKPackIndex`/`baseLookup` (`REF_DELTA`). Reuses `GKPackfileReader`'s delta-apply logic (extracted/shared rather than duplicated). Delta results inherit the base type.

- *Alternative:* keep delta-apply private to `GKPackfileReader` and duplicate it. Rejected — share one implementation.

### `GKLooseObjectDatabase` becomes index-first
On a loose miss, enumerate `objects/pack/*.idx`, find the pack whose index contains the OID, and read that single object by offset. Bases for `REF_DELTA` resolve via that pack's index, then via loose storage, then via other packs. A `.pack` lacking an `.idx` falls back to the existing whole-pack parse so correctness is preserved.

### In-memory object cache
A dictionary cache (`[GKObjectID: GKRawObject]`) on the database instance, populated by loose, indexed, and fallback reads, so repeated reads and shared delta bases are served without re-inflation. Unbounded for now (repository instances are short-lived); an LRU bound is a possible later refinement.

## Risks / Trade-offs

- **`.idx` v2 binary layout errors (fanout/large offsets)** → Mitigated by unit tests using a real `.idx` and parity checks against `GKPackfileReader.parse` output.
- **Reading the whole `.pack` into memory** → Acceptable; the eliminated cost is the full inflate + delta resolution + whole-file hashing, not the raw file read. mmap is a future optimization.
- **Delta base recursion depth** → Resolve iteratively (as in `GKPackfileReader`) to avoid stack growth on long chains.
- **Missing/mismatched `.idx`** → Fall back to whole-pack parsing; never silently drop objects.
- **Cache staleness within an instance** → Objects are content-addressed and immutable, so caching by OID is safe for a repository instance's lifetime.
