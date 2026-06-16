# Changelog

All notable changes to GitKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — 2026-06-16

This release is a comprehensive **security hardening pass** that closes the
attack surface a Git implementation must cope with: parsing untrusted objects,
packs, refs, and config from clones/fetches, plus writing under attacker-
controlled names. Every fix is accompanied by Swift Testing coverage; the suite
grew from 61 to 93 tests with no regressions.

### Security

- **Path & reference-name validation** — Added a `GKPathValidation` helper that
  centralizes traversal defense. Tree-checkout and index population now refuse
  entries named `.`, `..`, `.git` (including filesystem-equivalent spellings
  `.GIT`, `.git.`, `.git ` and `git~1`), entries containing path separators or
  NUL bytes, and any joined path that escapes the working directory. Reference
  writes/deletes enforce `git check-ref-format` rules (no traversal, no `.lock`
  suffix, no leading `/`, no control characters or forbidden bytes such as
  `~ ^ : ? * [ \` and `@{`) and verify containment within `.git/`. Closes the
  remote-tree → arbitrary-file-write and remote-ref → arbitrary-file-write
  vectors used by malicious clones/fetches.
  ([57c9e82](../../commit/57c9e82af65eced90ba11bc1af943540e3b5ef9d))

- **Configuration injection prevention** — `GKConfiguration` now escapes values
  containing newlines, tabs, quotes, backslashes, comment characters (`#`/`;`),
  control bytes, or leading/trailing whitespace by quoting and backslash-
  escaping them; subsection names have their `\` and `"` escaped so they
  cannot close the `[section "sub"]` header early; section, subsection, and
  variable names are validated at `set` time, with `GKError.invalidConfiguration`
  thrown for newline-bearing subsections. The reader was updated symmetrically
  to honor escapes and inline comments. Prevents a remote-supplied URL or
  remote name from injecting `[core] sshCommand = …` into `.git/config`.
  ([1da474c](../../commit/1da474cdbb82bdb081feda0861b331ad5167d2fa))

- **Decompression-bomb caps** — `GKZlib.decompress`/`inflateRaw`/`inflateZlibStream`
  now accept a `maxOutputSize` parameter, enforced before every literal or
  back-reference append; exceeding the cap throws `GKError.zlibError`. Loose
  objects use a 1 GiB default ceiling; pack entries are capped to their declared
  size, neutralizing tiny streams that would expand to gigabytes.
  ([bac0edc](../../commit/bac0edcad46f4c6ea6c567c0a3326b62d56f11f2))

- **Allocation-bomb hardening** — `GKPackfileReader` now clamps every
  attacker-controlled `reserveCapacity` against the available input
  (per-entry storage) or `GKZlib.defaultMaxOutputSize` (delta result buffer),
  so a forged 4-billion object count or a delta header claiming a multi-gigabyte
  result no longer drives a giant up-front allocation.
  ([07718a7](../../commit/07718a7d011478364b8f0dca19818d1c4774ee26))

- **Object integrity verification on read** — `GKLooseObjectDatabase.read`
  now re-hashes every materialized object (loose, indexed-pack, and
  index-less pack paths) and refuses results whose content does not match
  the requested OID, throwing the new `GKError.objectHashMismatch(expected:actual:)`.
  Restores Git's content-addressing guarantee against tampered storage and
  malicious pack indexes. Verification runs before caching, so the cache
  only ever holds verified objects.
  ([6591f89](../../commit/6591f89796d465b1735fdd8375d1cd6284aa6ac0))

- **Pack varint bounds checking** — `decodeEntryHeader`, `decodeOffset`,
  `decodeDeltaSize`, and the `applyDelta` copy-instruction operand reads now
  bounds-check every byte access and throw `GKError.packfileError` on
  truncation rather than trapping. Reachable from the network input path
  during fetch/unpack; eliminates the process-killing crash class for
  malformed packs.
  ([77bd550](../../commit/77bd55032810193fa4980ec084b6d556c13e6e16))

### Changed

- **`GKObjectID(bytes:)` is now a throwing initializer.** Constructing an OID
  from raw bytes of the wrong length throws `GKError.invalidObject` (with the
  actual byte count) instead of trapping on a `precondition`, so parser code
  hitting malformed input fails gracefully. An internal trusted initializer
  is used by call sites that have already validated length (e.g. fresh
  `GKSHA1.hash` output, already bounds-checked slices).

  > **Migration:** callers passing raw bytes must add `try`. The `init(hex:)`
  > failable initializer is unchanged.
  ([56fd4c9](../../commit/56fd4c98989ccb573570297f0c84a27032251cb3))

### Added

- New `GKError` cases — `unsafePath(String)`, `invalidReferenceName(String)`,
  and `objectHashMismatch(expected: GKObjectID, actual: GKObjectID)` —
  surfaced when validation rejects untrusted input.
- `GKSHA1.isCollisionResistant` constant (`false`) so callers/tests can
  branch on the hash function's posture instead of hard-coding the
  assumption.
- Doc comments on `GKSHA1` and `GKObjectID` describing SHA-1's broken
  collision resistance, what the integrity-check protections do and do not
  cover, and the planned SHA-256 object-format remedy.

### Documentation

- `docs/API.md` — Added an **Object IDs** section documenting the throwing
  `GKObjectID(bytes:)` and a **Security & Validation** section with a table
  of validation-related `GKError` cases, practical clone/fetch implications,
  and the SHA-1 caveat.
  ([0c36a42](../../commit/0c36a429eed012242b391777e9ca9763b6871384))

### Tests

Added 32 new Swift Testing cases across seven new suites:

- `GKPathValidation` (8) — tree entry name acceptance/rejection, NUL bytes,
  `.git` spellings, containment accept/reject including the prefix-sibling
  case, and reference-name rules.
- `GKCheckoutSecurity` (3) — checkout of trees with `..` and `.git` entries
  throws and writes nothing outside the work tree; ref-name traversal at
  write time throws.
- `GKConfigurationSecurity` (6) — newline-in-value injection neutralized,
  serialized values stay single-line, quote-in-subsection escaped, newline-
  in-subsection rejected, ordinary values not over-quoted, special
  characters round-trip.
- `GKZlibSecurity` (3) — bomb rejected against a small cap, normal data
  round-trips, output exactly equal to the cap is allowed (inclusive
  boundary).
- `GKPackfileSecurity` (4) — forged object count does not over-allocate,
  empty pack still parses, truncated entry header throws (no trap),
  truncated `OFS_DELTA` offset varint throws (no trap).
- `GKObjectIntegrity` (3) — tampered loose object rejected, untampered
  object reads successfully, mismatch error carries both OIDs.
- `GKObjectIDHardening` (5) — wrong-length input throws, 20-byte input
  succeeds, error message includes the actual length, `.zero` round-trips,
  `GKSHA1.isCollisionResistant == false`.

### Notes

- SHA-1's lost collision resistance is inherent to Git's object format and
  cannot be structurally fixed without SHA-256 object-format support, which
  is planned. Users who need authenticity guarantees should pair OIDs with
  signed commits/tags or other out-of-band integrity.

[Unreleased]: ../../compare/1.0.4...HEAD
