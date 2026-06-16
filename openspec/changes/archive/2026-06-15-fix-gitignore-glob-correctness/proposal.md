## Why

`sgit status` (and `add`) report files that `.gitignore` clearly excludes. The root cause is in `GKIgnorePattern` (`GKIgnore.swift`): it has no notion of **anchoring** or **directory-prefix matching**, so the most common real-world pattern form — a root-anchored `/build`, `/node_modules`, `/dist` — never matches.

Reproduced live against GitKit:

```
.gitignore: /dist  secret.txt  logs   → UNTRACKED includes "dist/bundle.js"   (should be ignored)
.gitignore: /build/  /node_modules    → UNTRACKED includes "build/a.o",
                                                          "node_modules/lib.js"  (should be ignored)
```

Two compounding defects:
1. A leading `/` is treated as a literal character instead of a root anchor (and stripped).
2. Even without the slash, `globMatch` requires a whole-string match, so a pattern that names a directory (`build`) does not ignore the files beneath it (`build/a.o`).

Separately, `status` passes `.skipsHiddenFiles` to its working-tree enumerator, so GitKit never reports dotfiles (e.g. `.gitignore`, `.env`) as untracked — a divergence from Git, which reports any non-ignored dotfile.

## What Changes

- **Anchoring:** a pattern with a `/` anywhere except a trailing slash is anchored to its `.gitignore`'s directory; a leading `/` is an anchor and is stripped. A pattern with no internal slash continues to match at any depth ("floating") within its directory's subtree.
- **Per-directory scoping:** each pattern is evaluated relative to the directory of the `.gitignore` that defined it. A pattern only applies to paths beneath that directory; anchored patterns anchor to it (not the repo root), and floating patterns match at any depth within its subtree. `.git/info/exclude` and the global `core.excludesFile` are scoped to the repository root.
- **Segment-aware matching:** match a pattern against a path's `/`-separated segments. A pattern that matches a directory segment ignores everything beneath it (so `/build` and `build/` both exclude `build/**`). Apply the same segment logic to anchored patterns that contain a non-trailing slash (e.g. `src/gen`).
- **Broader glob correctness:** within a segment support `*` (does not cross `/`), `?`, and character classes `[...]` / `[!...]`; support `**` as a full segment (leading `**/`, trailing `/**`, and embedded `/**/`). Keep negation as last-match-wins.
- **Dotfiles:** `status` reports untracked dotfiles that are not ignored; the `.git` directory remains excluded. Apply the same to directory `add` for consistency.

## Capabilities

### Modified Capabilities
- `gitignore-exclusion`: pattern matching gains anchoring, directory-prefix/segment semantics, and fuller glob support; `status` (and directory `add`) no longer blanket-skip dotfiles.

## Impact

- **Modified code:** `Sources/GitKit/GKIgnore.swift` (patterns carry their base directory; matching gains anchoring, directory-prefix/segment semantics, and fuller glob support), `Sources/GitKit/GKRepository.swift` (`ignoreMatcher` supplies each source's base directory; `status` enumerator drops `.skipsHiddenFiles`, keeps `.git` exclusion), `Sources/GitKit/GKRepository+Operations.swift` (`addDirectory` enumerator likewise).
- **Behavior:** root- and nested-anchored ignores work, each relative to its own `.gitignore`; ignored directories fully excluded; non-ignored dotfiles surface as untracked. The `GKIgnore(mergingFiles:)` initializer is replaced/augmented by one that associates patterns with base directories (internal API).
- **Dependencies:** none — pure Swift.
- **Tests:** anchored `/dir` and `/dir/`, anchored mid-slash `a/b`, directory-prefix exclusion, floating single-token, nested-`.gitignore` anchoring and subtree scoping, `*`/`?`/`[...]`/`**` cases, negation precedence, dotfile reported vs ignored, `.git` still excluded.

## Non-Goals

- Git's "cannot re-include a file if a parent directory is excluded" negation subtlety.
