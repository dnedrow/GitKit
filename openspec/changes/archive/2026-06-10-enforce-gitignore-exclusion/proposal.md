## Why

GitKit ships a `GKIgnore` pattern matcher, but it is never invoked: `add` stages any path it is given, and `status` reports every non-tracked working-tree file as untracked. This diverges from Git's contract — files matched by `.gitignore` (and the global/core excludes) must be skipped — and risks committing build artifacts, secrets, and other intentionally excluded files.

## What Changes

- Introduce a repository-level ignore service that aggregates ignore rules from all of Git's standard sources: per-directory `.gitignore` files, the repository's `.git/info/exclude`, and the global excludes file referenced by `core.excludesFile`.
- Wire ignore evaluation into `add` so staging an ignored path is a no-op (unless the path is already tracked, matching Git's behavior). Directory/glob adds skip ignored entries.
- Wire ignore evaluation into `status` so ignored working-tree files are excluded from the untracked set rather than reported.
- Honor negation (`!pattern`), directory-only (`trailing/`), anchored (`leading/`), and nested per-directory precedence rules so deeper `.gitignore` files override shallower ones.
- Add `core.excludesFile` resolution to configuration so the global ignore file participates in matching.

## Capabilities

### New Capabilities
- `gitignore-exclusion`: Aggregation of ignore rules from local `.gitignore` files, `.git/info/exclude`, and the global `core.excludesFile`, and the guarantee that ignored, untracked paths are excluded from every command that walks the working tree (notably `add` and `status`).

### Modified Capabilities
<!-- No existing specs in openspec/specs/; nothing to modify. -->

## Impact

- **Code:** `GKIgnore.swift` (matching semantics + multi-source aggregation), `GKRepository.swift` (ignore service construction, `status` filtering), `GKRepository+Operations.swift` (`add` filtering), `GKConfiguration.swift` (`core.excludesFile` resolution).
- **APIs:** New repository-level ignore-check entry point; `add`/`status` behavior changes (ignored untracked paths are now skipped). Already-tracked files remain unaffected.
- **Tests:** New coverage in `Tests/GitKitTests/GitKitTests.swift` for local, nested, info/exclude, global, negation, and tracked-file cases.
- **Dependencies:** None (pure Swift, consistent with project constraints).
