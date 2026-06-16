## 1. Pattern parsing & per-directory sources

- [x] 1.1 In `GKIgnorePattern.init`, compute `isAnchored` (a `/` before the last character; a leading `/` counts) and strip a single leading `/`; keep `isNegation` and `isDirectoryOnly`
- [x] 1.2 Precompute the pattern's `/`-split segments (retaining `**` segments) for matching
- [x] 1.3 Replace `GKIgnore(mergingFiles:)` with a base-dir-aware initializer (e.g. `init(sources: [(baseDir: String, url: URL)])`) that keeps a flat, ordered list of `(baseDir, GKIgnorePattern)`
- [x] 1.4 Update `ignoreMatcher()` in `GKRepository.swift` to pass each source's repo-root-relative base directory (`""` for global excludes, `.git/info/exclude`, and root `.gitignore`; the containing dir for nested `.gitignore` files)

## 2. Segment-aware matching engine

- [x] 2.1 Implement a single-segment matcher `segMatch` supporting literals, `*` (no `/`), `?` (one non-`/`), and `[...]`/`[!...]` character classes
- [x] 2.2 Implement segment-list matching with `**` spanning zero or more segments (leading `**/`, trailing `/**`, interior `/**/`)
- [x] 2.3 Implement the directory-prefix rule: a pattern that consumes a leading run of path segments with deeper segments remaining ⇒ path is under a matched directory ⇒ ignored; honor `isDirectoryOnly` at the leaf
- [x] 2.4 Scope each pattern to its base directory (path must be under `baseDir`; strip the `baseDir/` prefix before matching), then match: anchored ⇒ align at segment 0; floating ⇒ try any start segment
- [x] 2.5 In `GKIgnore.isIgnored`, evaluate all applicable `(baseDir, pattern)` entries in order and return the last match's polarity (last-match-wins negation)

## 3. Dotfile reporting

- [x] 3.1 Remove `.skipsHiddenFiles` from the `status` working-tree enumerator in `GKRepository.swift`; ensure the `.git` directory is pruned (skip traversal, not just the entry)
- [x] 3.2 Remove `.skipsHiddenFiles` from the `addDirectory` enumerator in `GKRepository+Operations.swift`; keep `.git` excluded and ignore rules applied

## 4. Tests

- [x] 4.1 Anchored directory: `/build` and `/build/` ignore `build/a.o`; do not ignore `src/build/keep.o`
- [x] 4.2 Anchored mid-slash: `src/gen` ignores `src/gen/file.swift` but not `lib/src/gen/file.swift`
- [x] 4.3 Floating token: `node_modules` ignores it at any depth
- [x] 4.4 Glob: `*.[oa]` ignores `m.o`/`m.a` not `m.c`; `?` and `*` within a segment; `logs/**/*.txt` spans directories
- [x] 4.5 Negation precedence still works (`*.log` + `!keep.log`)
- [x] 4.6 Nested scoping: `sub/.gitignore` with `/build` ignores `sub/build/x.o` not `build/y.o`; `sub/.gitignore` with `*.log` ignores `sub/a.log` & `sub/deep/b.log` not `other/c.log`
- [x] 4.7 Dotfiles: non-ignored `.env`/`.gitignore` reported untracked; ignored dotfile excluded; nothing under `.git` reported
- [x] 4.8 Status integration: `/dist` excludes `dist/bundle.js` from untracked (the reported bug)
- [x] 4.9 Run `swift build` and `swift test`; fix any failures

## 5. Documentation

- [x] 5.1 If `docs/API.md` or `README.md` describe gitignore/status behavior, note anchored-pattern support and dotfile reporting (skip if not applicable)
