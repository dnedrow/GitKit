## 1. Directory-level ignore matching (`GKIgnore.swift`)

- [x] 1.1 Add a directory-aware evaluation entry point to `GKIgnore` (e.g. `isIgnored(path:isDirectory:)` or `isDirectoryIgnored(path:)`) that reuses the existing anchoring, per-directory scoping, and last-match-wins negation logic.
- [x] 1.2 Ensure a directory matched by a rule is reported ignored, and that descendants of an ignored directory are not re-included by nested negation (Git semantics).
- [x] 1.3 Precompute pattern data in `GKIgnorePattern.init` (pre-split segments as `[Character]` arrays / per-segment metadata) so `matches(path:)` no longer rebuilds arrays or slices on each recursive call.
- [x] 1.4 (Optional) Index patterns by `baseDir` so scopes that cannot apply to a path are skipped.

## 2. Prune ignored directories in the status walk (`GKRepository.swift`)

- [x] 2.1 In `status()`, read `.isDirectoryKey` from the enumerator's prefetched resource values instead of a separate `fileExists(isDirectory:)` probe.
- [x] 2.2 When a visited directory is ignored, call `enumerator.skipDescendants()` (mirroring the existing `.git` pruning) so its subtree is not enumerated.
- [x] 2.3 Simplify `workTreeRelativePath` usage so the working-directory root symlink is resolved once (not twice per file), preserving macOS `/private` prefix handling.

## 3. Bound the gitignore-discovery walk (`GKRepository.swift`)

- [x] 3.1 Apply the same ignored-directory pruning in `gitignoreFiles()` so `.gitignore` discovery does not descend into ignored subtrees.
- [x] 3.2 Confirm `ignoreMatcher()` is still built once per `status()` call and that discovery no longer performs an unpruned full-tree walk.

## 4. Tests (`Tests/GitKitTests/GitKitTests.swift`)

- [x] 4.1 Add a test that files under an ignored directory are excluded and the ignored subtree is not enumerated (e.g. assert via observable output / large-tree fixture).
- [x] 4.2 Add a test that a tracked, modified file inside an otherwise-ignored directory is still reported as modified.
- [x] 4.3 Add a test that a non-ignored sibling directory is still traversed and its untracked files reported.
- [x] 4.4 Add directory-level ignore matching tests, including "no re-inclusion under an ignored directory" and a non-ignored directory returning not-ignored.
- [x] 4.5 Add a parity test asserting staged/unstaged/untracked sets are identical for a tree containing staged, unstaged, untracked, and ignored files.

## 5. Verification

- [x] 5.1 Run `swift build` and `swift test`; ensure existing `gitignore-exclusion` and `status-stat-cache` scenarios still pass.
- [x] 5.2 Sanity-check performance on a repository with a large ignored subtree (status completes in seconds, not minutes).
