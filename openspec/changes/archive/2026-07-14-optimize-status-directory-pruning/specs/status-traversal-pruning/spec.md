## ADDED Requirements

### Requirement: Status prunes ignored directory subtrees

During the `status` working-tree walk, when an enumerated directory is itself ignored, the system SHALL skip its entire subtree rather than visiting each descendant file. Pruning SHALL NOT change which paths are reported: files beneath an ignored directory remain excluded from the untracked set, and tracked files continue to be reported. The `.git` directory SHALL continue to be pruned unconditionally.

#### Scenario: Files under an ignored directory are not visited

- **WHEN** `status` runs and an ignored directory (e.g. matched by `/build`) contains many files
- **THEN** none of the files beneath it appear in the untracked list, and the walk does not descend into the ignored directory

#### Scenario: Tracked file inside an otherwise-ignored directory is still reported

- **WHEN** a directory is ignored but contains a tracked, modified file
- **THEN** `status` still reports that tracked file as modified

#### Scenario: Non-ignored sibling directories are still traversed

- **WHEN** one top-level directory is ignored and another is not
- **THEN** untracked files in the non-ignored directory are reported while the ignored directory's contents are not

### Requirement: Status traverses the working tree at most once

Computing `status` SHALL traverse the working tree a bounded number of times independent of the number of `.gitignore` files, and SHALL NOT perform a separate unpruned full-tree walk solely to discover `.gitignore` files. Any traversal used to gather ignore sources SHALL apply the same ignored-directory pruning as the status walk.

#### Scenario: Gitignore discovery does not add an unpruned full walk

- **WHEN** `status` runs in a repository with nested `.gitignore` files and a large ignored subtree
- **THEN** the ignored subtree is not enumerated by a separate `.gitignore` discovery pass

### Requirement: Bounded per-file filesystem work during status

For each visited working-tree file, the `status` walk SHALL perform a bounded amount of filesystem work and SHALL avoid redundant path resolution. It SHALL NOT resolve symlinks for the working-directory root more than once per file, and SHALL NOT issue an additional `fileExists` probe when the enumerator already provides the file's type.

#### Scenario: A visited file is not stat-probed redundantly

- **WHEN** `status` visits a regular file during the walk
- **THEN** the file's type and relative path are determined without repeating the same symlink resolution or existence probe multiple times

#### Scenario: Result parity with the previous walk

- **WHEN** `status` runs over a working tree containing staged, unstaged, untracked, and ignored files
- **THEN** the staged, unstaged, and untracked sets are identical to those produced without the traversal optimizations
