## Context

`GKRepository.status()` is slow on large repositories with big ignored subtrees (observed: several minutes on a large iOS app containing `Pods/`, `build/`, and `DerivedData/`). The stat cache (`status-stat-cache`) already avoids re-hashing unchanged tracked files, so hashing is not the bottleneck when the index carries valid stat data — confirmed by the fact that repositories checked out by real Git (which populates stat) are still slow.

Current traversal cost, per `status()` call:

- `ignoreMatcher()` → `gitignoreFiles()` performs a **full** `FileManager.enumerator` walk of the working tree to discover `.gitignore` files, descending into ignored directories.
- `status()` then performs a **second** full walk. For every file it calls `workTreeRelativePath()` (two `resolvingSymlinksInPath()` calls) plus a separate `fileExists(isDirectory:)`, and for untracked candidates it calls `GKIgnore.isIgnored`.
- `GKIgnore.isIgnored` iterates every pattern from every source and matches via a recursive algorithm that rebuilds `Array` slices and `[Character]` arrays on each call.
- Neither walk prunes ignored directories, so an ignored `Pods/` with tens of thousands of files is fully enumerated (twice) and each file is matched against every pattern.

## Goals / Non-Goals

**Goals:**

- Prune ignored directory subtrees during the status walk so ignored trees are not enumerated file-by-file.
- Eliminate the separate unpruned full walk used for `.gitignore` discovery.
- Add a correct directory-level ignore check to enable pruning.
- Lower per-file and per-match constant costs (fewer syscalls, precomputed pattern data).
- Preserve `status()` output exactly (same staged/unstaged/untracked sets).

**Non-Goals:**

- Changing untracked reporting semantics (e.g. collapsing an untracked directory to a single entry like Git's default). Deferred to a future change.
- Caching the flattened HEAD tree across calls, or parallelizing the walk.
- Changing the on-disk index or `.gitignore` file formats.

## Decisions

### Decision: Prune ignored directories during enumeration

Use `FileManager.enumerator`'s `skipDescendants()` when a visited **directory** is ignored, mirroring the existing `.git` pruning. This is the dominant win: it removes the enumeration of large ignored subtrees entirely.

- Requires distinguishing directories from files cheaply — read `.isDirectoryKey` from the enumerator's prefetched resource values rather than a separate `fileExists` probe.
- **Alternative considered**: keep visiting every file but short-circuit ignore matching. Rejected — still pays O(files-in-ignored-tree) enumeration and syscall cost, which is exactly what makes the iOS repo slow.

### Decision: Add directory-aware ignore matching with correct precedence

Introduce a directory-oriented evaluation on `GKIgnore` (e.g. `isIgnored(path:isDirectory:)` or a dedicated `isDirectoryIgnored`). Semantics follow Git: a directory matched by a rule is ignored, and once ignored, descendants cannot be re-included by nested negation. Because the walk prunes at the directory, the existing per-file negation logic naturally stops applying beneath a pruned directory — which is the Git-correct outcome.

- **Alternative considered**: infer directory-ignored purely from per-file results. Rejected — a directory has no trailing content to test, and Git's "no re-inclusion under an ignored dir" rule must be explicit to stay correct.

### Decision: Single pruned traversal feeding both ignore discovery and status

Rather than one walk to collect `.gitignore` files and another to compute status, gather ignore sources with the same pruning applied, or fold discovery into the status walk. The simplest correctness-preserving step: apply ignored-directory pruning to `gitignoreFiles()` too, so neither walk descends into ignored trees. A `.gitignore` inside an ignored directory does not affect tracked/untracked results and can be skipped.

- **Alternative considered**: a full single-pass rewrite that lazily loads per-directory `.gitignore` as it descends (closest to Git). Higher value but larger and riskier; captured as an open question / follow-up. This change keeps the two-phase structure but makes both phases pruned and bounded.

### Decision: Precompute pattern data at parse time

Store each `GKIgnorePattern`'s segments as pre-split `[Character]` arrays (and any per-segment metadata) once in the initializer, so `matches(path:)` avoids rebuilding `[Character]` arrays and `Array` slices on every recursive call. Optionally index patterns by `baseDir` to skip scopes that cannot apply to a given path.

- **Alternative considered**: compile patterns to `NSRegularExpression`. Rejected — Git glob semantics (`**`, character classes, anchoring) don't map cleanly and regex adds its own cost; targeted precomputation keeps behavior identical.

### Decision: Cut redundant per-file filesystem work

Compute the working-tree-relative path from the enumerator URL without resolving symlinks twice per file, and reuse the enumerator's resource values for directory/regular-file classification instead of an extra `fileExists`.

## Risks / Trade-offs

- **Directory-ignore semantics diverge from per-file results** → Mitigation: dedicated spec scenarios (including nested negation under an ignored dir) and reuse of the existing anchoring/scoping code path so only the "directory match" entry point is new.
- **Pruning changes output in an edge case** (e.g. a tracked file living under an ignored directory) → Mitigation: only untracked discovery is pruned; tracked entries are enumerated from the index, not the walk, so they are still reported. A parity scenario asserts identical staged/unstaged/untracked sets.
- **Symlinked working-tree root** previously handled by double `resolvingSymlinksInPath()` → Mitigation: resolve the base once up front (already effectively constant) and compare enumerator URLs against the resolved base, preserving the `/private` prefix handling on macOS.
- **`.gitignore` skipped inside an ignored directory** → Acceptable and Git-correct: patterns inside an ignored directory cannot re-include anything, so they don't affect results.

## Migration Plan

Internal, non-breaking. No index/format migration. Ship behind no flag; correctness is guarded by existing `gitignore-exclusion` and `status-stat-cache` scenarios plus new parity scenarios. Rollback is a straight revert.

## Open Questions

- Should a later change adopt a true single-pass, lazily-loaded per-directory `.gitignore` walk (closest to Git) and untracked-directory collapsing? Both are deferred here.
