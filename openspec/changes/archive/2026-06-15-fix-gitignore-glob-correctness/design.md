## Context

`GKIgnore` merges patterns from all sources into one flat list and evaluates them last-match-wins. `GKIgnorePattern` parses `!` (negation) and a trailing `/` (directory-only), then matches with a custom recursive `globMatch` over whole strings. It lacks anchoring and directory-prefix semantics, treats a leading `/` as literal, and discards which `.gitignore` directory each pattern came from — so nested patterns cannot be scoped or anchored to their own directory.

The status and `addDirectory` working-tree walks pass `.skipsHiddenFiles`, which removes all dotfiles from consideration before ignore rules are even consulted.

## Goals / Non-Goals

**Goals**
- Root- and nested-anchored patterns (`/build`, `/build/`, `src/gen`) match correctly, each relative to the directory of the `.gitignore` that defined them.
- Per-directory scoping: a pattern only applies to paths beneath its `.gitignore`'s directory.
- A pattern that names a directory ignores everything beneath it.
- Fuller single-segment globbing: `*`, `?`, `[...]`/`[!...]`; `**` as a path-spanning segment.
- `status` (and directory `add`) report non-ignored dotfiles while still excluding `.git`.

**Non-Goals**
- Negation that re-includes a file under an excluded parent directory.

## Decisions

### Patterns carry a base directory

`GKIgnore` SHALL associate each pattern with the repo-root-relative directory of the `.gitignore` (or exclude file) that defined it:

```
sources, shallow → deep:
  global core.excludesFile   baseDir = ""   (repo root)
  .git/info/exclude          baseDir = ""
  <root>/.gitignore          baseDir = ""
  <sub>/.gitignore           baseDir = "sub"
  <sub/deep>/.gitignore      baseDir = "sub/deep"
```

The internal `init(mergingFiles:)` is replaced by one taking `(baseDir, url)` sources (e.g. `init(sources:)`), producing a flat list of `(baseDir, GKIgnorePattern)` evaluated in order (last-match-wins preserved; deeper files come later so they override).

### Pattern parsing (`GKIgnorePattern`)

```
raw → trim
isNegation     = hasPrefix("!")           (strip "!")
isDirectoryOnly = hasSuffix("/")          (strip trailing "/")
anchored       = pattern contains "/" before its last character
                 (a leading "/" counts; strip one leading "/")
segments       = remaining pattern split on "/"   (may contain "**")
```

Git rule encoded: "a separator at the beginning or middle ⇒ pattern is anchored to the base dir; otherwise it may match at any level below the base dir."

### Matching a path

For each `(baseDir, pattern)` in order, against a repo-root-relative path `P`:

```
1. Scope to baseDir:
     if baseDir != "" :
         require P == baseDir/...  → else this pattern does not apply
         R = P with the "baseDir/" prefix removed
     else R = P
2. Split R into segments R[0…n-1]; pattern segments G[0…m-1].
   if anchored:  align G starting at R[0]
   else:         try G anchored at any start index k in R
3. Directory-prefix rule: if G fully consumes R[k…k+m-1] and k+m < n
   (deeper segments remain) ⇒ path is under a matched directory ⇒ match.
   If k+m == n it matched the leaf; honor isDirectoryOnly.
```

- **`**` segments:** a `**` segment matches zero or more path segments (`/**/` interior, `**/` leading, `/**` trailing).
- **Single-segment glob (`segMatch`):** `*` matches any run of non-`/` chars, `?` one non-`/` char, `[...]`/`[!...]` a character class; literals otherwise.
- `GKIgnore.isIgnored` SHALL apply all applicable `(baseDir, pattern)` entries in order and return the last match's polarity (negation re-includes).

### Dotfiles

- Remove `.skipsHiddenFiles` from the `status` working-tree enumerator (`GKRepository.swift`) and the `addDirectory` enumerator (`GKRepository+Operations.swift`).
- Keep excluding the `.git` directory via the existing `relativePath.hasPrefix(".git")` guard (verify it prunes traversal, not just the entry).
- Ignore rules still apply, so a dotfile listed in `.gitignore` stays excluded; a non-ignored dotfile (e.g. `.env` with no rule) is reported untracked.

## Risks / Trade-offs

- **Behavior change:** dotfiles now surface in `status`. This matches Git but will change output for repos relying on the old blanket skip. Acceptable — it is the correct behavior.
- **Matcher complexity:** base-dir scoping plus segment and `**` matching is more code; mitigated by a focused unit-test matrix on `GKIgnorePattern`/`GKIgnore`.
- **Internal API change:** `GKIgnore(mergingFiles:)` is replaced by a base-dir-aware initializer; `ignoreMatcher()` is the only caller and updates with it.

## Migration

No public API changes. `GKIgnore`'s internal initializer changes shape (patterns gain a base directory). Existing patterns that already worked keep working; anchored and nested patterns start working correctly. Negation precedence is unchanged.
