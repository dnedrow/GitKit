## 1. Configuration: core.excludesFile

- [x] 1.1 Add a `core.excludesFile` resolver to `GKConfiguration.swift` that reads the value via the existing accessor and expands a leading `~`.
- [x] 1.2 Return `nil` when the key is unset or the file is missing/unreadable (no throw).

## 2. Ignore aggregation

- [x] 2.1 Add a method on `GKIgnore` (or a builder) to merge patterns from multiple sources in precedence order: global excludes → `.git/info/exclude` → root `.gitignore` → nested `.gitignore` (deeper last).
- [x] 2.2 Ensure missing/unreadable sources contribute zero patterns and never throw.
- [x] 2.3 Verify negation (`!`), directory-only (`trailing/`), and anchored patterns are preserved through aggregation.

## 3. Repository ignore service

- [x] 3.1 Add a repository-level entry point (e.g. `func isIgnored(_ relativePath: String) -> Bool`) on `GKRepository` that constructs the aggregated matcher from `workDir`, `.git/info/exclude`, and `core.excludesFile`.
- [x] 3.2 Discover and include nested `.gitignore` files under `workDir`.

## 4. Wire into add

- [x] 4.1 In `GKAdd(path:)`, skip the path when it is ignored AND not already tracked in the index.
- [x] 4.2 In `GKAdd(paths:)` / directory adds, filter out ignored entries while staging non-ignored ones.
- [x] 4.3 Confirm already-tracked paths remain stageable even when matching an ignore pattern.

## 5. Wire into status

- [x] 5.1 In `GKRepository.status()`, exclude ignored untracked files from the untracked set.
- [x] 5.2 Confirm tracked files are still reported regardless of ignore patterns.

## 6. Tests

- [x] 6.1 Test local root `.gitignore` causes a file to be ignored.
- [x] 6.2 Test nested `.gitignore` negation (`!keep.log`) overrides a parent `*.log` ignore.
- [x] 6.3 Test `.git/info/exclude` pattern is honored.
- [x] 6.4 Test `core.excludesFile` global pattern is honored.
- [x] 6.5 Test missing sources do not throw and ignore nothing.
- [x] 6.6 Test `add` skips an ignored untracked file (index unchanged, no blob).
- [x] 6.7 Test `add` on a directory stages only non-ignored entries.
- [x] 6.8 Test an already-tracked file matching an ignore pattern can still be added.
- [x] 6.9 Test `status` omits ignored untracked files but still reports modified tracked files.

## 7. Verification

- [x] 7.1 Run `swift build` and `swift test`; fix any failures.
- [x] 7.2 Confirm public symbols use the `GK` prefix and changes follow AGENTS.md guidelines.
