## Context

GitKit defines `GKIgnore` / `GKIgnoreProtocol` in `GKIgnore.swift`, but research confirms it is never invoked: `GKAdd(path:)` stages any path, and `GKRepository.status()` enumerates the working tree (skipping only `.git/`) and reports every non-indexed file as untracked. Configuration (`GKConfiguration.swift`) has generic `getString`/`getBool`/`getInt` accessors but no `core.excludesFile` resolution, and there is no handling of `.git/info/exclude`. The repository exposes its working-tree root via `GKRepository.workDir: URL`.

The project constraints (AGENTS.md) require pure Swift, protocol-first design, value types where possible, `GK`-prefixed public symbols, and `GKError` for failures.

## Goals / Non-Goals

**Goals:**
- Aggregate ignore rules from per-directory `.gitignore`, `.git/info/exclude`, and the global `core.excludesFile`.
- Apply ignore evaluation in `add` (skip ignored, untracked paths) and `status` (exclude ignored untracked files).
- Preserve Git semantics: negation (`!`), directory-only (`trailing/`), anchored patterns, nested precedence, and the "already-tracked files are not ignored" rule.
- Keep everything pure Swift with no new dependencies.

**Non-Goals:**
- Re-implementing the full Git pathspec/wildmatch engine; we extend the existing glob matcher only as needed for these requirements.
- Per-user attributes/`.gitattributes` handling.
- Performance optimization beyond avoiding redundant file reads (no caching layer mandated).

## Decisions

**1. Add a repository-level ignore service rather than scattering checks.**
Introduce a single entry point on `GKRepository` (e.g. `func isIgnored(_ relativePath: String) -> Bool`) backed by an aggregated `GKIgnore`. Rationale: `add` and `status` (and future commands like `clean`) share one source of truth. Alternative — inlining file reads in each command — was rejected as duplicative and inconsistent.

**2. Build the aggregated matcher from ordered sources.**
Collect patterns in precedence order: global `core.excludesFile` → `.git/info/exclude` → root `.gitignore` → nested `.gitignore` (deeper last). Because `GKIgnore.isIgnored` already applies last-match-wins with negation support, ordering the patterns correctly yields correct precedence without changing the matching core. Alternative — a tree of per-directory matchers — is closer to Git internals but heavier; deferred as a non-goal.

**3. Resolve `core.excludesFile` in configuration.**
Add a helper that reads the `core.excludesFile` value via the existing config accessor and expands a leading `~`. Missing key or file → no global patterns. Keeps config parsing centralized.

**4. Tracked-file exemption lives at the call site.**
`add` checks "is this path already in the index?" before applying the ignore filter, mirroring Git's rule that tracked files are never auto-ignored. `status` only filters the untracked set, so tracked files are unaffected by construction.

**5. Tolerate missing/unreadable sources.**
All source loads are best-effort: absent files contribute zero patterns and never throw, satisfying the "missing sources tolerated" requirement.

## Risks / Trade-offs

- **Pattern-ordering approximates true nested precedence** → For the targeted scenarios (root + one nested level with negation) ordered last-match-wins is sufficient; document the limitation and cover with tests. Full per-directory semantics remain a future enhancement.
- **Directory enumeration cost in `status`/`add`** → Reuse the existing enumerator and apply the cheap ignore check inline; no extra full-tree walks introduced.
- **`~` / relative `core.excludesFile` expansion edge cases** → Constrain to `~` expansion and absolute/relative-to-home resolution; unreadable paths fall back to empty rather than erroring.
- **Behavior change for existing callers** → `add`/`status` now skip ignored untracked files; this is the intended Git-compatible behavior and is covered by new tests, but is technically a behavioral change.
