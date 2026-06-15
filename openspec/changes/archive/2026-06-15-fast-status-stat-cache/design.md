## Context

`status()` currently establishes file modification by hashing content. The index file format already reserves per-entry stat fields, and `GKIndexEntry` exposes them, but the only constructor of live entries — `GKIndex.add(path:oid:mode:)` — writes `Date()`-now for ctime/mtime and `0` for dev/ino/uid/gid/size. The parser (`GKIndex(data:)`) preserves whatever is on disk, so the round-trip is faithful; the corruption is entirely at the `add` boundary.

`add` is reached from three logical sites (`GKRepository+Operations.swift`):

- `GKAdd(path:)` (~41) and `addDirectory` (~72): the file is on disk and its bytes were just read — stat is essentially free.
- `populateIndex` (~277), serving `checkoutTree` (~241), `reset --mixed` (~644), and `reset --hard` (via checkout). Entries originate from a tree, so stat must come from the workdir file after it is materialized (checkout) or from the existing workdir file (reset --mixed).

The stat-cache shortcut in `status` is only correct when the stat stored at staging time matches what `status` later `lstat`s on the same file.

## Goals / Non-Goals

**Goals**
- A clean, testable, `Sendable` `GKFileStat` value type that both `add` and the index parser populate.
- Record real `lstat` data at every staging site.
- `status` skips content hashing when stat is unchanged; still detects genuine modifications.
- `reset --mixed` stats existing workdir files so identical-content files read as clean.
- Remove the `O(n²)` per-file index scan in `status`.

**Non-Goals**
- Index format/version changes — the on-disk layout is unchanged.
- Touching the object-read path (already covered by `pack-random-access`).

## Decisions

### `GKFileStat` shape

```swift
public struct GKFileStat: Sendable, Equatable {
    public var ctimeSeconds: UInt32
    public var ctimeNanoseconds: UInt32
    public var mtimeSeconds: UInt32
    public var mtimeNanoseconds: UInt32
    public var dev: UInt32
    public var ino: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var fileSize: UInt32

    public static let empty = GKFileStat(/* all zero */)
}
```

- A repository-layer helper reads a `GKFileStat` from a file URL via `lstat` (truncating 64-bit fields to the index's `UInt32` slots, mirroring Git).
- `GKIndexEntry` replaces its nine loose stat properties with a single `stat: GKFileStat` (the parser/writer map the same bytes; `init` keeps a defaulted `stat: .empty` for source compatibility where stat is unknown).

**Why a value type, not lstat-inside-add:** keeps `GKIndex` filesystem-agnostic (AGENTS.md §3 value-type/protocol-first conventions). The repository layer, which already touches the filesystem, owns the `lstat`; `add` just stores the supplied `GKFileStat`.

### `add` signature

```swift
mutating func add(path: String, oid: GKObjectID, mode: GKFileMode, stat: GKFileStat = .empty) throws
```

Default keeps existing call sites and tests compiling; staging sites pass a real stat.

### `status` comparison

For each tracked working file, build a `[path: GKIndexEntry]` map once, then:

```
current = lstat(file)
if current.fileSize == entry.stat.fileSize
   && current.mtime == entry.stat.mtime
   && current.ctime == entry.stat.ctime
   && current.ino == entry.stat.ino
   && current.dev == entry.stat.dev      →  treat as UNCHANGED, skip hashing
else                                       →  hash; report .modified iff OID differs
```

Entries whose stat is `.empty` (e.g. legacy indexes) fall through to hashing — correct, just not accelerated.

### Racy index handling

A file modified in the *same* filesystem-timestamp tick as the index write can have a matching mtime yet stale content — the "racy clean" problem. Git solves this in two halves, and we mirror both:

**On write** — smudge: when serializing the index, record the index file's own mtime as the reference. Any entry whose `stat.mtime` is greater than or equal to the index mtime is "racily clean"; its cached `fileSize` is written as `0`. A zero size never matches a real file, so the next `status` is forced to hash that entry.

```
write index:
   indexMtime = mtime the index file will have
   for entry in entries:
       if entry.stat.mtime >= indexMtime:    # could have changed this same tick
           entry.stat.fileSize = 0           # "smudge" → forces future content check
```

**On read/status** — distrust: when comparing, treat an entry as racily clean if its `stat.mtime >= indexMtime` (the index file's current mtime). For such entries, a stat match is *not* trusted; the file is hashed and reported `modified` only if the OID differs. The smudged size makes this automatic, but the explicit mtime check also covers entries written by other Git implementations.

```
status:
   indexMtime = lstat(.git/index).mtime
   ...
   racyClean = entry.stat.mtime >= indexMtime
   if !racyClean && stat fully matches:  skip hashing
   else:                                 hash; .modified iff OID differs
```

The repository layer supplies `indexMtime`; `GKIndex` exposes a smudging step on write that takes the reference mtime. `GKIndex` stays filesystem-agnostic — it never calls `stat` itself.

### `reset --mixed`

`populateIndex` gains an optional "stat from workdir" behavior: for each entry, if the corresponding workdir file exists, read its `GKFileStat` and store it; otherwise store `.empty`. This makes a subsequent `status` mark content-identical files clean and content-differing files modified (matching Git).

## Risks / Trade-offs

- **Index mtime granularity**: the racy-clean check relies on reading the index file's mtime; on filesystems with coarse timestamp resolution more entries are conservatively treated as racy (hashed), which is safe — never incorrect, only less accelerated.
- **Cross-platform stat widths**: Linux vs Darwin `timespec` field names differ; the helper isolates the platform `stat` read in one place.

## Migration

Backward compatible. Existing on-disk indexes parse unchanged; entries simply carry whatever stat bytes already exist. The first `add`/`checkout`/`reset` after upgrade writes real stat. No format/version bump.
