## Why

`GKRepository.status()` re-reads and SHA-1 hashes **every tracked file** on every call (`GKRepository.swift` ~336–341), then does an `index.entries.first(where:)` linear scan per file — an `O(total bytes)` + `O(n²)` cost on each status. Real Git avoids this with the index's cached `lstat` metadata: it compares each working file's stat (mtime, ctime, size, ino, dev) against the index and only hashes when stat differs.

GitKit already declares the stat fields on `GKIndexEntry` and round-trips them through the index parser/writer, but `GKIndex.add()` fills them with `Date()`-now and zeros. Because the stored stat never matches the real file, a stat-based shortcut is impossible today. This change records **real** stat data when staging so `status` can skip unchanged files.

The object-read path is already fast (see archived `pack-random-access`); this proposal targets the working-tree scan, which the pack fix does not address.

## What Changes

- Add a small, `Sendable` `GKFileStat` value type holding the cached stat fields (ctime, mtime, dev, ino, uid, gid, size).
- Populate `GKFileStat` from real `lstat` data at every staging site, and from on-disk bytes in the index parser — unifying the round-trip so both producers agree.
- `status()` compares each tracked working file's current stat against the index entry's `GKFileStat`; it re-hashes content **only** when stat differs (size/mtime/ctime/ino/dev), reporting `modified` only if the recomputed OID differs.
- Handle the "racy clean" case: on index write, smudge the cached size of entries whose mtime is at/after the index file's mtime; during `status`, verify such entries by content so a same-tick modification is never missed.
- For `reset --mixed`, stat the existing working-directory files when repopulating the index, so files left on disk are reported `modified` only if their content actually differs.
- Replace the per-file `index.entries.first(where:)` scan with a one-time `[path: entry]` dictionary (`O(n²)` → `O(n)`).

## Capabilities

### New Capabilities
- `status-stat-cache`: Index entries carry real filesystem stat metadata, and `status` uses it to skip content hashing for files whose stat is unchanged.

### Modified Capabilities
<!-- No existing spec capability changes its requirements; object reading (pack-random-access) is unchanged. -->

## Impact

- **New code**: `Sources/GitKit/GKFileStat.swift` (value type + a helper to read stat from a file URL).
- **Modified code**: `GKIndex.swift` (entry stores `GKFileStat`; `add` accepts/records it; parser/writer use it), `GKRepository.swift` (`status()` stat-shortcut + dictionary lookup), `GKRepository+Operations.swift` (staging and `populateIndex`/`reset --mixed` supply real stat).
- **Behavior**: `status` on a clean or mostly-clean working tree drops from hashing all files to a stat compare per file; correctness is preserved (content is still hashed whenever stat differs).
- **Docs**: `docs/API.md` `## Status` gains a brief note that `status` skips hashing unchanged files via cached stat and verifies racy-clean (same-tick) files by content.
- **Dependencies**: none added — remains pure Swift (`FileManager`/`stat` only).
- **Tests**: stat round-trip through the index; status skips unchanged files (no re-hash) yet detects real modifications; `reset --mixed` marks content-identical files clean and content-differing files modified.
