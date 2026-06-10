# AGENTS.md — GitKit

## Project Overview

GitKit is a **pure Swift** implementation of Git, inspired by libgit2. It provides a protocol-oriented API for Git operations without any C dependencies.

- **Language:** Swift 5.9+
- **Platforms:** macOS 13+, iOS 16+, tvOS 16+, watchOS 9+
- **Package Manager:** Swift Package Manager
- **Zero external dependencies**

## Architecture

### Naming Conventions

- All public types and functions are prefixed with `GK`.
- Internal/private implementation details omit the prefix or use it sparingly.
- Protocol names end with `Protocol` (e.g., `GKObjectProtocol`, `GKIndexProtocol`).
- The codebase favors `internal` (default) or `private` access over `public` — only the deliberate API surface is public.

### Layer Diagram

```
┌─────────────────────────────────────────────────────┐
│          High-Level Operations (GKRepository)        │
│  init, add, commit, branch, checkout, merge,         │
│  fetch, push, pull, clone, reset, stash, tag, diff   │
├─────────────────────────────────────────────────────┤
│              Mid-Level Services                       │
│  GKIndex · GKDiffEngine · GKMerge · GKRevisionWalker│
│  GKConfiguration · GKIgnore · GKStatus               │
├─────────────────────────────────────────────────────┤
│              Storage Backends                         │
│  GKLooseObjectDatabase · GKFileReferenceStorage      │
│  GKPackfileWriter · GKPackProtocol                   │
├─────────────────────────────────────────────────────┤
│              Core Object Model                        │
│  GKObjectID · GKRawObject · GKBlob · GKTree         │
│  GKCommit · GKTag · GKSignature · GKReference        │
├─────────────────────────────────────────────────────┤
│              Primitives (Pure Swift)                  │
│  GKSHA1 · GKZlib                                     │
└─────────────────────────────────────────────────────┘
```

### Key Protocols

| Protocol                   | Purpose                                                                                       |
|----------------------------|-----------------------------------------------------------------------------------------------|
| `GKObjectProtocol`         | Common interface for all Git objects (blob, tree, commit, tag)                                |
| `GKObjectDatabase`         | Reading + writing objects (composed of `GKObjectDatabaseReading` & `GKObjectDatabaseWriting`) |
| `GKReferenceStorage`       | CRUD for refs (branches, tags, HEAD)                                                          |
| `GKIndexProtocol`          | Staging area manipulation                                                                     |
| `GKTransport`              | Network transport abstraction (fetch/push)                                                    |
| `GKMergeStrategy`          | Pluggable merge algorithms                                                                    |
| `GKConfigurationProtocol`  | Git config file access                                                                        |
| `GKIgnoreProtocol`         | Gitignore pattern matching                                                                    |
| `GKRevisionWalkerProtocol` | Commit graph traversal                                                                        |
| `GKRepositoryProtocol`     | High-level repository interface                                                               |

### File Map

| File                            | Responsibility                                                                                             |
|---------------------------------|------------------------------------------------------------------------------------------------------------|
| `GitKit.swift`                  | Public `GK` namespace and version                                                                          |
| `GKError.swift`                 | All error types (`GKError` enum)                                                                           |
| `GKObjectID.swift`              | 20-byte SHA-1 identifier type                                                                              |
| `GKSHA1.swift`                  | Pure Swift SHA-1 hash (no CommonCrypto)                                                                    |
| `GKZlib.swift`                  | Pure Swift zlib deflate/inflate                                                                            |
| `GKObject.swift`                | `GKObjectProtocol`, `GKRawObject`, `GKObjectType`                                                          |
| `GKBlob.swift`                  | Blob object (file content)                                                                                 |
| `GKTree.swift`                  | Tree object, `GKTreeEntry`, `GKFileMode`                                                                   |
| `GKCommit.swift`                | Commit object, `GKSignature`                                                                               |
| `GKTag.swift`                   | Annotated tag object                                                                                       |
| `GKReference.swift`             | `GKReference`, `GKReferenceTarget`, `GKHead`, `GKBranch`                                                   |
| `GKIndex.swift`                 | Index (staging area) with v2 format support                                                                |
| `GKLooseObjectDatabase.swift`   | `.git/objects/` loose file storage                                                                         |
| `GKFileReferenceStorage.swift`  | `.git/refs/` and packed-refs                                                                               |
| `GKConfiguration.swift`         | INI-style git config parser/writer, `GKRemote`                                                             |
| `GKDiff.swift`                  | Diff engine, delta/hunk types, LCS algorithm                                                               |
| `GKMerge.swift`                 | Recursive 3-way merge strategy                                                                             |
| `GKTransport.swift`             | Transport protocol, pack protocol helpers, packfile writer                                                 |
| `GKStatus.swift`                | Working directory status types                                                                             |
| `GKIgnore.swift`                | Gitignore glob pattern matching                                                                            |
| `GKRevisionWalker.swift`        | Commit graph walker with sorting                                                                           |
| `GKRepository.swift`            | Main `GKRepository` class (open/init, lookups, refs, log, status)                                          |
| `GKRepository+Operations.swift` | High-level Git commands (add, commit, branch, checkout, merge, push, pull, clone, reset, stash, tag, diff) |

## Coding Guidelines

1. **No C or system library dependencies.** All crypto (SHA-1) and compression (zlib) are implemented in pure Swift.
2. **Protocol-first design.** Define a protocol, then provide a concrete implementation. This enables testing with mocks and future alternative backends (e.g., in-memory object DB).
3. **Value types preferred.** Most model types (`GKObjectID`, `GKBlob`, `GKTree`, `GKCommit`, `GKTag`, `GKReference`, `GKIndex`) are structs. `GKRepository` is a reference type (`final class`) because it holds mutable state and file handles.
4. **Sendable conformance.** Public value types conform to `Sendable` for safe concurrency.
5. **Error handling.** All fallible operations throw `GKError` with descriptive associated values.
6. **Access control.** Public API is explicitly marked `public`. Internal helpers are default (`internal`) or `private`. Never expose implementation details.
7. **GK prefix.** Every public symbol uses the `GK` prefix to avoid namespace collisions.

## Testing

- Tests use **Swift Testing** (`import Testing`, `@Test`, `@Suite`, `#expect`).
- Test file: `Tests/GitKitTests/GitKitTests.swift`
- Tests create temporary directories and clean up with `defer`.
- Run tests: `swift test`

## Building

```bash
swift build
swift test
```

## References

- https://libgit2.org
- https://github.com/git/git/tree/master/Documentation/technical
- https://wyag.thb.lt
- https://kausthub.substack.com/p/how-to-build-git-from-scratch
