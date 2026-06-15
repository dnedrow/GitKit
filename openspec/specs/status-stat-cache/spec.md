# Status Stat Cache

## Purpose

Make `status` fast on large working trees by caching filesystem stat metadata in the index and using it to skip content hashing for files whose stat is unchanged, while staying correct for files modified within the same timestamp tick as the index write ("racily clean").

## Requirements

### Requirement: Index entries carry filesystem stat metadata

The system SHALL represent per-entry filesystem stat metadata as a single `Sendable` value type (`GKFileStat`) holding ctime, mtime (seconds and nanoseconds), device, inode, uid, gid, and file size. Each index entry SHALL hold a `GKFileStat`. The index parser and writer SHALL round-trip these fields to and from the on-disk index without format changes.

#### Scenario: Stat round-trips through the index

- **WHEN** an index entry with non-zero stat metadata is written and then parsed back
- **THEN** the parsed entry's `GKFileStat` equals the written one

#### Scenario: Unknown stat defaults to empty

- **WHEN** an entry is created without stat information
- **THEN** its `GKFileStat` is the empty (all-zero) value, and the entry remains valid

### Requirement: Staging records real stat metadata

When staging a file that exists in the working directory, the system SHALL record the file's actual `lstat` metadata into the index entry's `GKFileStat`. This applies to single-file staging and directory staging.

#### Scenario: Staging a working-tree file stores its stat

- **WHEN** a file is staged from the working directory
- **THEN** the resulting index entry's `GKFileStat` reflects the file's current size and modification metadata, not placeholder values

### Requirement: Status skips hashing for stat-unchanged files

`status()` SHALL compare each tracked working-directory file's current stat against the index entry's `GKFileStat`. When the size, mtime, ctime, inode, and device all match, the file SHALL be treated as unmodified without hashing its contents. When the stat differs, the system SHALL hash the file and report it modified only if the recomputed OID differs from the index. Entries whose stored stat is empty SHALL fall back to content hashing.

#### Scenario: Unchanged file is not re-hashed

- **WHEN** a tracked file's stat matches the index entry's stored stat
- **THEN** `status` reports it unmodified without reading or hashing its contents

#### Scenario: Stat differs but content is identical

- **WHEN** a tracked file's stat differs from the index but its recomputed OID equals the index OID
- **THEN** `status` reports the file unmodified

#### Scenario: Modified content is detected

- **WHEN** a tracked file's contents change so its recomputed OID differs from the index
- **THEN** `status` reports the file modified

### Requirement: Racy-clean entries are verified by content

To avoid trusting stale stat for a file modified in the same filesystem-timestamp tick as the index write, the system SHALL treat an entry as "racily clean" when its stored mtime is greater than or equal to the index file's mtime. On writing the index, the system SHALL smudge such entries by storing a zero cached file size. During `status`, a racily-clean entry SHALL be verified by hashing its content regardless of stat match, and reported modified only if the recomputed OID differs.

#### Scenario: Same-tick modification is not missed

- **WHEN** a tracked file is modified in the same timestamp tick as the index write, preserving its size, so its stat still appears to match
- **THEN** `status` hashes the file rather than trusting stat, and reports it modified because its content differs

#### Scenario: Smudged size forces verification

- **WHEN** the index is written and an entry's mtime is greater than or equal to the index file's mtime
- **THEN** that entry's cached file size is stored as zero, forcing the next `status` to verify it by content

#### Scenario: Racily-clean but unmodified file stays clean

- **WHEN** an entry is racily clean but its content still matches the index OID
- **THEN** `status` reports it unmodified after verifying by content

### Requirement: Mixed reset records workdir stat

When `reset --mixed` repopulates the index from a commit tree, the system SHALL, for each entry with a corresponding working-directory file, record that file's current `lstat` metadata into the entry's `GKFileStat`. As a result, a subsequent `status` SHALL report such a file modified only if its content differs from the reset target.

#### Scenario: Mixed reset leaves an identical file clean

- **WHEN** `reset --mixed` targets a commit and a working-directory file's content matches that commit's blob
- **THEN** a subsequent `status` reports that file as unmodified

#### Scenario: Mixed reset surfaces a differing file

- **WHEN** `reset --mixed` targets a commit and a working-directory file's content differs from that commit's blob
- **THEN** a subsequent `status` reports that file as modified

### Requirement: Linear-time index lookup during status

`status()` SHALL resolve tracked entries by path using a single precomputed mapping rather than scanning all entries per file, so the working-tree comparison is linear in the number of files.

#### Scenario: Many tracked files

- **WHEN** `status` runs over a working tree with many tracked files
- **THEN** each file's index entry is resolved without a per-file linear scan of all entries
