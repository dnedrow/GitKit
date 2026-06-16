# Public API

## Repository Lifecycle

```swift
// Initialize a new repository
let repo = try GKRepository.GKInitRepository(at: url)
let bareRepo = try GKRepository.GKInitRepository(at: url, bare: true)

// Open an existing repository
let repo = try GKRepository(at: existingURL)

// Clone a remote repository (requires a GKTransport implementation)
let repo = try GKRepository.GKClone(url: "https://...", to: localURL, transport: myTransport)
```

## Staging (Add / Remove)

```swift
// Stage a single file
try repo.GKAdd(path: "src/main.swift")

// Stage multiple files
try repo.GKAdd(paths: ["file1.swift", "file2.swift"])

// Unstage a file
try repo.GKRemove(path: "file1.swift")
```

## Committing

```swift
let author = GKSignature(
    name: "Jane Dev",
    email: "jane@example.com",
    time: Date(),
    timeZoneOffset: -480  // minutes from UTC (PST = -480)
)

let commitOID = try repo.GKCreateCommit(
    message: "Add new feature",
    author: author,
    committer: author  // optional, defaults to author
)
```

## Branches

```swift
// Create a branch
try repo.GKCreateBranch(name: "feature/login")

// Create a branch at a specific commit
try repo.GKCreateBranch(name: "release/1.0", target: someCommitOID)

// Delete a branch
try repo.GKDeleteBranch(name: "feature/login")

// Rename a branch
try repo.GKRenameBranch(from: "old-name", to: "new-name")

// List all branches
let branches = try repo.branches()
for branch in branches {
    print("\(branch.name) -> \(branch.commitOID.hex)")
}
```

## Checkout

```swift
// Checkout a branch
try repo.GKCheckout(branch: "feature/login")

// Checkout a specific commit (detached HEAD)
try repo.GKCheckout(commit: commitOID)
```

## Tags

```swift
// Create a lightweight tag
try repo.GKCreateTag(name: "v1.0.0")

// Create an annotated tag
let tagger = GKSignature(name: "Jane Dev", email: "jane@example.com")
try repo.GKCreateAnnotatedTag(
    name: "v1.0.0",
    tagger: tagger,
    message: "Release version 1.0.0"
)

// Delete a tag
try repo.GKDeleteTag(name: "v1.0.0")

// List all tags
let tags = try repo.tags()
```

## Merge

```swift
let author = GKSignature(name: "Jane Dev", email: "jane@example.com")

do {
    let mergeOID = try repo.GKMerge(branch: "feature/login", author: author)
    print("Merged successfully: \(mergeOID.hex)")
} catch GKError.mergeConflict(let paths) {
    print("Conflicts in: \(paths)")
}
```

## Diff

```swift
// Diff between two commits
let diff = try repo.GKComputeDiff(from: commitA, to: commitB)
print("\(diff.filesChanged) files changed, \(diff.insertions) insertions, \(diff.deletions) deletions")

for delta in diff.deltas {
    print("\(delta.status.rawValue) \(delta.path)")
}

// Diff staged changes vs HEAD
let stagedDiff = try repo.GKDiffStaged()
```

## Status

```swift
let status = try repo.status()

if status.isClean {
    print("Working directory clean")
} else {
    for entry in status.staged {
        print("Staged: \(entry.status.rawValue) \(entry.path)")
    }
    for entry in status.unstaged {
        print("Modified: \(entry.path)")
    }
    for path in status.untracked {
        print("Untracked: \(path)")
    }
}
```

`status()` uses the index's cached filesystem stat metadata (size, mtime, ctime, inode, device) to skip re-hashing files whose stat is unchanged, so it stays fast on large working trees. Files touched within the same timestamp tick as the last index write are treated as "racily clean" and verified by content, so results remain correct even when stat alone cannot be trusted.

Ignored files are excluded from the untracked set using Git's standard ignore sources (the global `core.excludesFile`, `.git/info/exclude`, and per-directory `.gitignore` files). Pattern matching follows Git semantics: a leading or middle `/` anchors a pattern to its `.gitignore`'s directory (so `/build` ignores `build/**` but not `src/build/`), a pattern that names a directory excludes everything beneath it, and `*`, `?`, `[...]`, and `**` are supported. Dotfiles (e.g. `.gitignore`, `.env`) are reported as untracked unless a rule ignores them; the `.git` directory is never reported.

## Log

```swift
// Get commit history from HEAD
let commits = try repo.log()

// Get history from a specific commit, limiting results
let commits = try repo.log(from: someOID, maxCount: 20)

for commit in commits {
    print("\(commit.oid.hex.prefix(7)) \(commit.summary)")
    print("  Author: \(commit.author.name) <\(commit.author.email)>")
}
```

## Reset

```swift
// Soft reset (move HEAD only)
try repo.GKReset(to: commitOID, mode: .soft)

// Mixed reset (move HEAD + reset index)
try repo.GKReset(to: commitOID, mode: .mixed)

// Hard reset (move HEAD + reset index + reset working directory)
try repo.GKReset(to: commitOID, mode: .hard)
```

## Stash

```swift
// Stash current changes
let stashOID = try repo.GKStash(message: "WIP: half-done feature")

// Stash with default message
try repo.GKStash()
```

## Remote Operations

```swift
// Add a remote
try repo.GKAddRemote(name: "origin", url: "https://github.com/user/repo.git")

// Remove a remote
try repo.GKRemoveRemote(name: "origin")

// List remotes
let remotes = repo.GKRemotes()
for remote in remotes {
    print("\(remote.name) -> \(remote.url)")
}

// Fetch, push, pull (require a GKTransport implementation)
try repo.GKFetch(remote: "origin", transport: myTransport)
try repo.GKPush(remote: "origin", branch: "main", transport: myTransport)
let oid = try repo.GKPull(remote: "origin", branch: "main", transport: myTransport, author: author)
```

> **Pack materialization.** Packfiles returned by `GKFetch`/`GKPull`/`GKClone` are parsed and written into the object database, resolving `OFS_DELTA` and `REF_DELTA` entries (with thin-pack bases looked up against existing objects). After a fetch, the received objects are available via normal object lookups.

## Object Lookup

```swift
// Look up objects by OID
let commit = try repo.lookupCommit(oid: commitOID)
let tree = try repo.lookupTree(oid: commit.treeOID)
let blob = try repo.lookupBlob(oid: blobOID)
let tag = try repo.lookupTag(oid: tagOID)
```

> **Loose and packed storage.** Object lookups (and everything built on them — `log`, `status`, `diff`, checkout) resolve objects transparently from either loose files (`.git/objects/xx/…`) or packfiles (`.git/objects/pack/*.pack`). Packed objects are reconstructed on demand, including `OFS_DELTA`/`REF_DELTA` chains and thin-pack bases. When a pack's `.idx` is present, a single object is located via the index and only that object plus its delta base chain is inflated — the whole pack is not parsed. Packs without an index fall back to a full parse.

## HEAD & References

```swift
// Read HEAD
let head = try repo.head()
switch head {
case .branch(let name):
    print("On branch: \(name)")
case .detached(let oid):
    print("Detached at: \(oid.hex)")
}

// Resolve HEAD to a commit OID
let headOID = try repo.GKHeadCommitOID()

// List all references
let refs = try repo.references()
```

## Object IDs

```swift
// From a 40-character hex string (failable)
let oid = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")

// From raw bytes (throws on a wrong length — never traps)
let oid = try GKObjectID(bytes: rawBytes)
```

> **Note.** `GKObjectID(bytes:)` is a throwing initializer. Pass exactly 20 bytes; a wrong length throws `GKError.invalidObject` with the actual byte count for diagnostics. This is intentional so parser code that hits malformed input fails gracefully instead of trapping.

## Security & Validation

GitKit hardens the paths that consume untrusted input (objects parsed from disk, refs and config written during clone/fetch, packs received from the network). The behavior is enforced automatically — callers do not need to opt in — but several `GKError` cases surface specifically for these checks:

| Error                                   | Raised when                                                                                                                                     |
|-----------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| `.unsafePath(String)`                   | A tree entry name (or its joined working-directory path) attempts traversal, names `.git`, contains a path separator, or escapes the work tree. |
| `.invalidReferenceName(String)`         | A reference name fails `git check-ref-format` rules (traversal, `.lock` suffix, control characters, forbidden bytes, …).                        |
| `.objectHashMismatch(expected:actual:)` | A loose or packed object's content does not re-hash to the OID it is filed under (storage tampering or corruption).                             |
| `.invalidConfiguration(String)`         | A configuration key/subsection contains characters that cannot be safely serialized (e.g. a newline in a subsection name).                      |
| `.zlibError(String)`                    | Decompression would exceed the per-call output cap (decompression-bomb defense).                                                                |
| `.packfileError(String)`                | A packfile is truncated, has malformed varints, declares an implausible object count, or references an unresolvable delta base.                 |

Practical implications for callers:

- **Clone/fetch from untrusted remotes is safe by default.** Tree entries that would write outside the work tree, reference names that would escape `.git/`, and configuration values that would inject new sections into `.git/config` are rejected at write time rather than after damage is done.
- **Packs are size-bounded.** Each entry is inflated against its declared size; a forged size or a decompression bomb throws rather than allocating without bound. Forged object counts no longer drive multi-gigabyte `reserveCapacity` allocations.
- **OIDs are content-addressed on read.** Every object returned by `GKLooseObjectDatabase` is verified to re-hash to the requested OID. Tampered storage that swaps content under an existing OID is detected.
- **SHA-1 caveat.** Object IDs are SHA-1 digests, which are no longer collision-resistant. The integrity check above defends against tampered storage but cannot defend against a true SHA-1 collision; pair OIDs with out-of-band integrity (e.g. signed commits/tags) when authenticity matters. SHA-256 object-format support is planned.
