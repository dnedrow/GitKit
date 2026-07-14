## Why

`status()` can take several minutes on large real-world repositories (e.g. a big iOS app with `Pods/`, `build/`, and `DerivedData/`). The stat cache already prevents unnecessary content hashing, so the remaining cost is structural in the working-tree walk: the enumerator descends into fully-ignored directories that can hold tens of thousands of files, tests every one of them against every ignore pattern, and does so across **two** full filesystem walks. Real Git avoids this by pruning an ignored directory and never recursing into it.

## What Changes

- **Prune ignored directories during the `status` working-tree walk.** When an enumerated directory is itself ignored, skip its entire subtree instead of visiting every descendant file. This matches Git's behavior and preserves output (files under an ignored directory were already excluded).
- **Collapse the two full filesystem walks into one.** Discovering per-directory `.gitignore` files and computing status currently each walk the whole tree; unify them (or at least apply the same pruning to the discovery walk) so ignored subtrees are traversed at most once.
- **Add directory-aware ignore matching** so the walk can decide a directory is ignored (and prune) without inspecting its children, including correct handling of Git's rule that a file cannot be re-included once its parent directory is ignored.
- **Make ignore matching cheaper per call**: precompute pattern segments / character arrays once at parse time instead of re-slicing and rebuilding `[Character]` arrays on every recursive match, and skip pattern scopes whose `baseDir` cannot apply to the path.
- **Reduce per-file syscalls** in the walk: reuse the enumerator's resource values and avoid the redundant double `resolvingSymlinksInPath()` and extra `fileExists(isDirectory:)` per file.
- Non-goal: changing which files are reported. Untracked-directory *collapsing* (reporting a directory instead of its files) is deferred; observable status output is unchanged.

## Capabilities

### New Capabilities

- `status-traversal-pruning`: Bounds the cost of the `status` working-tree walk by pruning ignored directory subtrees, traversing the tree at most once, and keeping per-file filesystem work bounded — without changing which paths are reported.

### Modified Capabilities

- `gitignore-exclusion`: Adds the ability to evaluate whether a *directory* path is ignored so the working-tree walk can prune its subtree, with Git-correct semantics that descendants of an ignored directory stay ignored regardless of nested negation.

## Impact

- **Code**: `GKRepository.status()` and `workTreeRelativePath` (`GKRepository.swift`); the `.gitignore` discovery walk in `gitignoreFiles()`/`ignoreMatcher()`; `GKIgnore`/`GKIgnorePattern` matching (`GKIgnore.swift`).
- **APIs**: Internal traversal only. `status()`'s public result shape and the set of reported paths are unchanged. `GKIgnore` may gain a directory-matching entry point.
- **Performance**: Turns multi-minute `status` into seconds on repositories with large ignored subtrees; no behavior change for correctness-covered scenarios.
- **Tests**: New coverage for ignored-directory pruning, single-walk behavior, and directory-level ignore matching; existing `gitignore-exclusion` and `status-stat-cache` scenarios must continue to pass.
