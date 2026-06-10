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

For the full API reference with code examples, see [docs/API.md](docs/API.md).

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

> **Note:** GitKit does not ship with a built-in network transport. Your application **must** provide its own implementation of the `GKTransport` protocol to use any remote operations (fetch, push, pull, clone). This keeps GitKit free of platform-specific networking dependencies and gives you full control over authentication, caching, and request handling.

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
