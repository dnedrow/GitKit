# GitIgnore Exclusion

## Purpose

Ensure GitKit honors Git's standard ignore mechanisms so that files excluded by local `.gitignore` files, `.git/info/exclude`, or the global `core.excludesFile` are not acted on by commands that walk the working tree (notably `add` and `status`).

## Requirements

### Requirement: Aggregate ignore rules from all standard sources

The repository SHALL build its ignore rule set from all of Git's standard ignore sources, evaluated with the following precedence (later overrides earlier): the global excludes file referenced by `core.excludesFile`, the repository's `.git/info/exclude`, and per-directory `.gitignore` files (with deeper directories overriding shallower ones). When `core.excludesFile` is unset, no global file is loaded. Missing or unreadable sources SHALL be treated as empty and MUST NOT cause an error.

#### Scenario: Local .gitignore is honored
- **WHEN** a working-tree file matches a pattern in a `.gitignore` at the repository root
- **THEN** the repository reports that path as ignored

#### Scenario: Nested .gitignore overrides parent
- **WHEN** a parent `.gitignore` ignores `*.log` and a subdirectory `.gitignore` contains `!keep.log`
- **THEN** `subdir/keep.log` is reported as not ignored while other `*.log` files remain ignored

#### Scenario: info/exclude is honored
- **WHEN** a pattern exists only in `.git/info/exclude` and a working-tree file matches it
- **THEN** the repository reports that path as ignored

#### Scenario: Global excludesFile is honored
- **WHEN** `core.excludesFile` points to a file containing a matching pattern
- **THEN** the repository reports the matching path as ignored

#### Scenario: Missing sources are tolerated
- **WHEN** no `.gitignore`, `.git/info/exclude`, or `core.excludesFile` exists
- **THEN** the repository reports no paths as ignored and does not throw

### Requirement: Gitignore pattern matching semantics

The system SHALL match `.gitignore` patterns using Git's anchoring and directory semantics over `/`-separated path segments, evaluated relative to the directory of the `.gitignore` that defined each pattern:

- A pattern containing a `/` anywhere other than a trailing position SHALL be anchored to its base directory; a leading `/` SHALL act as an anchor and not as a literal character. A pattern with no internal `/` SHALL match at any directory depth within its base directory's subtree.
- A pattern that matches a directory SHALL exclude everything beneath that directory.
- A trailing `/` SHALL restrict the pattern to directories.
- Within a single segment, `*` SHALL match any run of characters except `/`, `?` SHALL match exactly one character except `/`, and `[...]` / `[!...]` SHALL match a character class. A `**` segment SHALL match zero or more path segments (leading `**/`, trailing `/**`, and interior `/**/`).
- Negation (`!`) SHALL continue to apply with last-match-wins precedence.

#### Scenario: Root-anchored directory pattern excludes contents

- **WHEN** `.gitignore` contains `/build` (or `/build/`) and the working tree has `build/a.o`
- **THEN** `build/a.o` is reported as ignored

#### Scenario: Root-anchored pattern does not match nested directory of the same name

- **WHEN** `.gitignore` contains `/build` and the working tree has `src/build/keep.o`
- **THEN** `src/build/keep.o` is reported as not ignored

#### Scenario: Anchored mid-slash pattern matches by segments

- **WHEN** `.gitignore` contains `src/gen` and the working tree has `src/gen/file.swift`
- **THEN** `src/gen/file.swift` is reported as ignored, while `lib/src/gen/file.swift` is not

#### Scenario: Floating single-token pattern matches at any depth

- **WHEN** `.gitignore` contains `node_modules` and the working tree has both `node_modules/x.js` and `packages/a/node_modules/y.js`
- **THEN** both files are reported as ignored

#### Scenario: Character class and wildcards within a segment

- **WHEN** `.gitignore` contains `*.[oa]` and the working tree has `m.o`, `m.a`, and `m.c`
- **THEN** `m.o` and `m.a` are ignored and `m.c` is not

#### Scenario: Double-star spans directories

- **WHEN** `.gitignore` contains `logs/**/*.txt` and the working tree has `logs/2026/06/x.txt`
- **THEN** `logs/2026/06/x.txt` is reported as ignored

### Requirement: Per-directory ignore scoping

Each pattern SHALL be evaluated relative to the directory of the `.gitignore` that defined it, and SHALL apply only to paths beneath that directory. Anchored patterns SHALL anchor to that directory rather than the repository root. Patterns from `.git/info/exclude` and the global `core.excludesFile` SHALL be scoped to the repository root.

#### Scenario: Nested anchored pattern is relative to its own directory

- **WHEN** `sub/.gitignore` contains `/build` and the working tree has `sub/build/x.o` and `build/y.o`
- **THEN** `sub/build/x.o` is reported as ignored and `build/y.o` is reported as not ignored

#### Scenario: Nested pattern does not affect siblings

- **WHEN** `sub/.gitignore` contains `*.log` and the working tree has `sub/a.log`, `sub/deep/b.log`, and `other/c.log`
- **THEN** `sub/a.log` and `sub/deep/b.log` are ignored while `other/c.log` is not

### Requirement: Untracked dotfiles are reported

The `status` operation SHALL report untracked working-tree files whose names begin with a dot, unless they are ignored. The `.git` directory and its contents SHALL never be reported. Directory `add` SHALL likewise consider dotfiles, staging non-ignored ones.

#### Scenario: Non-ignored dotfile is reported as untracked

- **WHEN** `status` runs and an untracked `.gitignore` (or other dotfile) exists that no ignore rule matches
- **THEN** that dotfile appears in the untracked list

#### Scenario: Ignored dotfile is not reported

- **WHEN** an ignore rule matches a dotfile such as `.env`
- **THEN** `status` does not report that dotfile

#### Scenario: The .git directory is never reported

- **WHEN** `status` runs in a non-bare repository
- **THEN** no path under `.git` appears in any status set

### Requirement: Ignored untracked paths are excluded from add

The `add` operation SHALL NOT stage a path that is ignored and not already tracked. When adding a set of paths or a directory, ignored entries SHALL be skipped while non-ignored entries are staged. A path that is already tracked in the index SHALL still be stageable even if it matches an ignore pattern.

#### Scenario: Adding an ignored file is a no-op
- **WHEN** `add` is called with a path that is ignored and not tracked
- **THEN** the index is unchanged and no blob is created for that path

#### Scenario: Adding a directory skips ignored entries
- **WHEN** `add` stages a directory containing both ignored and non-ignored files
- **THEN** only the non-ignored files are added to the index

#### Scenario: Already-tracked ignored file can still be added
- **WHEN** a path is already tracked and later matches an ignore pattern
- **THEN** `add` still stages the updated content for that path

### Requirement: Ignored files are excluded from status

The `status` operation SHALL exclude ignored, untracked working-tree files from the untracked set, applying anchoring and directory semantics so that files beneath an ignored directory are excluded. Tracked files SHALL continue to be reported regardless of ignore patterns.

#### Scenario: Ignored untracked file is not reported
- **WHEN** `status` runs and an untracked working-tree file matches an ignore pattern
- **THEN** that file does not appear in the untracked list

#### Scenario: Files under a root-anchored ignored directory are not reported
- **WHEN** `.gitignore` contains `/dist` and the working tree has `dist/bundle.js`
- **THEN** `dist/bundle.js` does not appear in the untracked list

#### Scenario: Tracked file matching ignore pattern is still reported
- **WHEN** a tracked file matches an ignore pattern and has working-tree modifications
- **THEN** `status` still reports it as modified

### Requirement: Directory-level ignore evaluation

The ignore matcher SHALL be able to decide whether a *directory* path is ignored, so that a working-tree walk can prune the directory's entire subtree. A directory SHALL be considered ignored when an active ignore rule matches it, applying the same anchoring, per-directory scoping, and last-match-wins negation semantics as file matching. Consistent with Git, once a directory is ignored, its descendants SHALL remain ignored regardless of negation patterns that would otherwise re-include nested paths; re-inclusion of a descendant SHALL require that the directory itself not be ignored.

#### Scenario: An ignored directory is reported as ignored

- **WHEN** an ignore rule matches a directory (e.g. `/build` or `node_modules`) and that directory path is tested
- **THEN** the matcher reports the directory as ignored

#### Scenario: Descendant is not re-included under an ignored directory

- **WHEN** a directory is ignored by `build/` and a nested pattern `!build/keep.txt` also exists
- **THEN** the matcher still reports `build` as ignored, so `build/keep.txt` is not re-included

#### Scenario: A non-ignored directory is not pruned

- **WHEN** a directory path matches no ignore rule
- **THEN** the matcher reports the directory as not ignored, allowing the walk to descend into it
