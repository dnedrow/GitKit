## 1. GKFileStat value type

- [x] 1.1 Create `Sources/GitKit/GKFileStat.swift` with a `public struct GKFileStat: Sendable, Equatable` holding `ctimeSeconds/Nanoseconds`, `mtimeSeconds/Nanoseconds`, `dev`, `ino`, `uid`, `gid`, `fileSize` (all `UInt32`) and a `static let empty`
- [x] 1.2 Add a repository-layer helper that reads a `GKFileStat` from a file `URL` via `lstat`, truncating 64-bit fields to `UInt32` (isolate the Darwin/Linux `timespec` field access in this one place)

## 2. Index integration

- [x] 2.1 Replace the nine loose stat properties on `GKIndexEntry` with a single `stat: GKFileStat`; keep `init` accepting `stat: GKFileStat = .empty` for source compatibility
- [x] 2.2 Update `GKIndex(data:)` to build `GKFileStat` from the parsed bytes, and `write(to:)` to serialize from `entry.stat` (no on-disk format change)
- [x] 2.3 Extend `GKIndexProtocol.add` and `GKIndex.add` to `add(path:oid:mode:stat: GKFileStat = .empty)`, storing the supplied stat instead of `Date()`-now/zeros
- [x] 2.4 Add a smudging step used on write: given the index file's reference mtime, zero the cached `fileSize` of any entry whose `stat.mtime >= indexMtime` ("racily clean"); the repository write path supplies the reference mtime after the index is on disk (or uses the intended write time)

## 3. Staging sites record real stat

- [x] 3.1 `GKAdd(path:)` (`GKRepository+Operations.swift` ~41): read the staged file's `GKFileStat` and pass it to `add`
- [x] 3.2 `addDirectory` (~72): read each staged file's `GKFileStat` and pass it to `add`
- [x] 3.3 `populateIndex` (~269): add an option to stat from the working directory; for each entry, store the workdir file's `GKFileStat` when the file exists, else `.empty`
- [x] 3.4 `checkoutTree` (~241) and `reset --hard`: populate stat from the just-written workdir files
- [x] 3.5 `reset --mixed` (~644): call `populateIndex` with workdir-stat enabled so existing files are statted

## 4. Fast status

- [x] 4.1 In `status()` build a `[String: GKIndexEntry]` map once and use it for per-file lookups (replace `index.entries.first(where:)`)
- [x] 4.2 For each tracked working file, compare current `lstat` against `entry.stat`; when size/mtime/ctime/ino/dev all match, treat as unchanged and skip hashing
- [x] 4.3 When stat differs, hash and report `.modified` only if the recomputed OID differs; treat `.empty` stored stat as "always hash"
- [x] 4.4 Read the index file's mtime; treat any entry with `stat.mtime >= indexMtime` as racily clean and verify it by content regardless of stat match (covers smudged and externally-written entries)

## 5. Tests

- [x] 5.1 Stat round-trip: write an entry with non-zero stat, parse it back, assert `GKFileStat` equality
- [x] 5.2 Status skip: stage a file, then assert `status` reports it clean without modification (and is unaffected by an unrelated touch that preserves stat)
- [x] 5.3 Status detect: modify a tracked file's content and assert `status` reports it modified
- [x] 5.4 Stat-differs-but-identical: rewrite identical content (changing mtime) and assert `status` reports unmodified after re-hash
- [x] 5.5 `reset --mixed`: identical-content file reports clean; differing-content file reports modified
- [x] 5.6 Racy-clean smudge: an entry whose mtime equals the index mtime is written with zero cached size, and a same-tick content change of equal size is still reported modified; a racily-clean but unmodified file stays clean after content verification
- [x] 5.7 Run `swift build` and `swift test`; fix any failures

## 6. Documentation

- [x] 6.1 In `docs/API.md` under `## Status`, add a short note that `status()` uses the index's cached stat metadata to skip hashing unchanged files, and that files touched in the same tick as the index write are verified by content (racy-clean) — so results stay correct
- [x] 6.2 If `README.md` mentions status/performance characteristics, add a one-line pointer to the stat-cache behavior (skip if not applicable) — N/A: README has no status/performance section, only a type-summary table entry
