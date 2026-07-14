## ADDED Requirements

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
