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

The `status` operation SHALL exclude ignored, untracked working-tree files from the untracked set. Tracked files SHALL continue to be reported regardless of ignore patterns.

#### Scenario: Ignored untracked file is not reported
- **WHEN** `status` runs and an untracked working-tree file matches an ignore pattern
- **THEN** that file does not appear in the untracked list

#### Scenario: Tracked file matching ignore pattern is still reported
- **WHEN** a tracked file matches an ignore pattern and has working-tree modifications
- **THEN** `status` still reports it as modified
