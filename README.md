# GitKit

A **pure Swift** implementation of Git, inspired by [libgit2](https://libgit2.org). GitKit provides a protocol-oriented API for Git operations — no C dependencies, no shelling out to `git`, just Swift.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2013+%20|%20iOS%2016+%20|%20tvOS%2016+%20|%20watchOS%209+-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## Features

- **Pure Swift** — SHA-1 and zlib implemented without CommonCrypto or system libraries
- **Protocol-oriented** — swap out storage backends, merge strategies, or transports
- **Zero dependencies** — only Foundation required
- **Full Git object model** — blobs, trees, commits, annotated tags
- **Repository operations** — init, add, commit, branch, checkout, merge, tag, diff, reset, stash
- **Network-ready** — transport protocol abstraction for fetch, push, pull, and clone
- **Cross-platform** — macOS, iOS, tvOS, watchOS

## Installation

### Swift Package Manager

Add GitKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/GitKit.git", from: "0.1.0")
]
```

Then add `"GitKit"` as a dependency of your target:

```swift
.target(name: "YourApp", dependencies: ["GitKit"])
```

## Quick Start

```swift
import GitKit

// Create a new repository
let repo = try GKRepository.GKInitRepository(at: projectURL)

// Create and stage a file
try "Hello, World!".write(to: projectURL.appendingPathComponent("README.md"),
                          atomically: true, encoding: .utf8)
try repo.GKAdd(path: "README.md")

// Commit
let author = GKSignature(name: "Jane Dev", email: "jane@example.com")
let commitOID = try repo.GKCreateCommit(message: "Initial commit", author: author)
```

## Public API

### Repository Lifecycle

```swift
// Initialize a new repository
let repo = try GKRepository.GKInitRepository(at: url)
let bareRepo = try GKRepository.GKInitRepository(at: url, bare: true)

// Open an existing repository
let repo = try GKRepository(at: existingURL)

// Clone a remote repository (requires a GKTransport implementation)
let repo = try GKRepository.GKClone(url: "https://...", to: localURL, transport: myTransport)
```

### Staging (Add / Remove)

```swift
// Stage a single file
try repo.GKAdd(path: "src/main.swift")

// Stage multiple files
try repo.GKAdd(paths: ["file1.swift", "file2.swift"])

// Unstage a file
try repo.GKRemove(path: "file1.swift")
```

### Committing

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

### Branches

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

### Checkout

```swift
// Checkout a branch
try repo.GKCheckout(branch: "feature/login")

// Checkout a specific commit (detached HEAD)
try repo.GKCheckout(commit: commitOID)
```

### Tags

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

### Merge

```swift
let author = GKSignature(name: "Jane Dev", email: "jane@example.com")

do {
    let mergeOID = try repo.GKMerge(branch: "feature/login", author: author)
    print("Merged successfully: \(mergeOID.hex)")
} catch GKError.mergeConflict(let paths) {
    print("Conflicts in: \(paths)")
}
```

### Diff

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

### Status

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

### Log

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

### Reset

```swift
// Soft reset (move HEAD only)
try repo.GKReset(to: commitOID, mode: .soft)

// Mixed reset (move HEAD + reset index)
try repo.GKReset(to: commitOID, mode: .mixed)

// Hard reset (move HEAD + reset index + reset working directory)
try repo.GKReset(to: commitOID, mode: .hard)
```

### Stash

```swift
// Stash current changes
let stashOID = try repo.GKStash(message: "WIP: half-done feature")

// Stash with default message
try repo.GKStash()
```

### Remote Operations

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

### Object Lookup

```swift
// Look up objects by OID
let commit = try repo.lookupCommit(oid: commitOID)
let tree = try repo.lookupTree(oid: commit.treeOID)
let blob = try repo.lookupBlob(oid: blobOID)
let tag = try repo.lookupTag(oid: tagOID)
```

### HEAD & References

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

## Core Types

| Type           | Description                                            |
|----------------|--------------------------------------------------------|
| `GKRepository` | Main entry point — open, create, or clone repositories |
| `GKObjectID`   | 20-byte SHA-1 hash identifier                          |
| `GKBlob`       | File content object                                    |
| `GKTree`       | Directory listing object                               |
| `GKCommit`     | Commit object with parents, tree, author, message      |
| `GKTag`        | Annotated tag object                                   |
| `GKSignature`  | Author/committer identity with timestamp               |
| `GKReference`  | Named pointer to an object (branch, tag)               |
| `GKBranch`     | Branch information (name, commit, upstream)            |
| `GKHead`       | HEAD state (branch or detached)                        |
| `GKDiff`       | Diff result with deltas and hunks                      |
| `GKStatus`     | Working directory status (staged, unstaged, untracked) |
| `GKIndex`      | Staging area (index file)                              |
| `GKRemote`     | Remote configuration (name, URL, refspec)              |
| `GKError`      | Comprehensive error enum for all failure modes         |

## Protocols

GitKit is protocol-oriented, making it easy to mock for testing or provide alternative implementations:

| Protocol                   | Purpose                            |
|----------------------------|------------------------------------|
| `GKRepositoryProtocol`     | High-level repository interface    |
| `GKObjectProtocol`         | Common interface for git objects   |
| `GKObjectDatabase`         | Object storage (reading + writing) |
| `GKReferenceStorage`       | Reference CRUD                     |
| `GKIndexProtocol`          | Index/staging area                 |
| `GKTransport`              | Network transport (fetch/push)     |
| `GKMergeStrategy`          | Pluggable merge algorithm          |
| `GKConfigurationProtocol`  | Git config access                  |
| `GKIgnoreProtocol`         | Gitignore matching                 |
| `GKRevisionWalkerProtocol` | Commit graph traversal             |

## Implementing a Custom Transport

To enable fetch/push/pull/clone, implement the `GKTransport` protocol:

```swift
struct MyHTTPTransport: GKTransport {
    let url: String

    func connect() throws -> GKRemoteAdvertisement {
        // Discover remote refs via GET /info/refs?service=git-upload-pack
        // Parse pkt-line response
    }

    func fetch(wants: [GKObjectID], haves: [GKObjectID]) throws -> Data {
        // POST to /git-upload-pack with want/have lines
        // Return packfile data
    }

    func push(commands: [GKPushCommand], packData: Data) throws -> [GKPushResult] {
        // POST to /git-receive-pack with ref update commands + pack
    }
}
```

## Building & Testing

```bash
swift build
swift test
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│          High-Level Operations (GKRepository)        │
├─────────────────────────────────────────────────────┤
│              Mid-Level Services                       │
│  GKIndex · GKDiffEngine · GKMerge · GKRevisionWalker│
├─────────────────────────────────────────────────────┤
│              Storage Backends                         │
│  GKLooseObjectDatabase · GKFileReferenceStorage      │
├─────────────────────────────────────────────────────┤
│              Core Object Model                        │
│  GKObjectID · GKBlob · GKTree · GKCommit · GKTag    │
├─────────────────────────────────────────────────────┤
│              Primitives (Pure Swift)                  │
│  GKSHA1 · GKZlib                                     │
└─────────────────────────────────────────────────────┘
```

## References

- [libgit2](https://libgit2.org) — the C library that inspired this project
- [Git Internals](https://github.com/git/git/tree/master/Documentation/technical) — official technical documentation
- [Write Yourself a Git (WYAG)](https://wyag.thb.lt) — educational Git implementation walkthrough
- [Building Git from Scratch](https://kausthub.substack.com/p/how-to-build-git-from-scratch) — step-by-step guide

## License

MIT
