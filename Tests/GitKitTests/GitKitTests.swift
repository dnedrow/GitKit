import Testing
import Foundation
@testable import GitKit

// MARK: - Object ID Tests

@Suite("GKObjectID")
struct GKObjectIDTests {
    @Test func createFromHex() {
        let hex = "abc1234567890abcdef1234567890abcdef12345"
        let oid = GKObjectID(hex: hex)
        #expect(oid != nil)
        #expect(oid?.hex == hex)
    }

    @Test func invalidHex() {
        #expect(GKObjectID(hex: "not-a-valid-hex") == nil)
        #expect(GKObjectID(hex: "abc") == nil)
    }

    @Test func zeroOID() {
        let zero = GKObjectID.zero
        #expect(zero.hex == "0000000000000000000000000000000000000000")
    }

    @Test func equality() {
        let oid1 = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        let oid2 = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        #expect(oid1 == oid2)
    }

    @Test func comparison() {
        let oid1 = GKObjectID(hex: "0000000000000000000000000000000000000001")!
        let oid2 = GKObjectID(hex: "0000000000000000000000000000000000000002")!
        #expect(oid1 < oid2)
    }
}

// MARK: - SHA-1 Tests

@Suite("GKSHA1")
struct GKSHA1Tests {
    @Test func emptyString() {
        let hash = GKSHA1.hash(Data())
        let oid = GKObjectID(bytes: hash)
        #expect(oid.hex == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test func helloWorld() {
        let hash = GKSHA1.hash(Data("hello world".utf8))
        let oid = GKObjectID(bytes: hash)
        // Known SHA-1 of "hello world"
        #expect(oid.hex == "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed")
    }
}

// MARK: - Blob Tests

@Suite("GKBlob")
struct GKBlobTests {
    @Test func createBlob() {
        let content = Data("Hello, World!".utf8)
        let blob = GKBlob(content: content)
        #expect(blob.type == .blob)
        #expect(blob.content == content)
        #expect(blob.text == "Hello, World!")
        #expect(blob.size == 13)
        #expect(!blob.isBinary)
    }

    @Test func binaryBlob() {
        let content = Data([0x00, 0x01, 0x02, 0x03])
        let blob = GKBlob(content: content)
        #expect(blob.isBinary)
    }
}

// MARK: - Signature Tests

@Suite("GKSignature")
struct GKSignatureTests {
    @Test func parseSignature() {
        let sig = GKSignature.parse("John Doe <john@example.com> 1234567890 +0200")
        #expect(sig?.name == "John Doe")
        #expect(sig?.email == "john@example.com")
        #expect(sig?.timeZoneOffset == 120)
    }

    @Test func formatSignature() {
        let sig = GKSignature(
            name: "Jane Doe",
            email: "jane@example.com",
            time: Date(timeIntervalSince1970: 1000000000),
            timeZoneOffset: -300
        )
        #expect(sig.formatted.contains("Jane Doe <jane@example.com>"))
        #expect(sig.formatted.contains("-0500"))
    }
}

// MARK: - Repository Tests

@Suite("GKRepository")
struct GKRepositoryTests {
    @Test func initRepository() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-test-\(UUID().uuidString)")

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)
        #expect(repo.workDir == tempDir)
        #expect(!repo.isBare)

        let head = try repo.head()
        #expect(head == .branch("main"))
    }

    @Test func initBareRepository() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-bare-test-\(UUID().uuidString)")

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir, bare: true)
        #expect(repo.isBare)
    }

    @Test func addAndCommit() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-commit-test-\(UUID().uuidString)")

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)

        // Create a file
        let filePath = tempDir.appendingPathComponent("hello.txt")
        try "Hello, GitKit!".write(to: filePath, atomically: true, encoding: .utf8)

        // Add and commit
        try repo.GKAdd(path: "hello.txt")

        let author = GKSignature(name: "Test User", email: "test@example.com")
        let commitOID = try repo.GKCreateCommit(message: "Initial commit", author: author)

        // Verify
        let commit = try repo.lookupCommit(oid: commitOID)
        #expect(commit.message == "Initial commit")
        #expect(commit.author.name == "Test User")
        #expect(commit.isRoot)
    }

    @Test func createAndDeleteBranch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-branch-test-\(UUID().uuidString)")

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)

        // Need at least one commit
        let filePath = tempDir.appendingPathComponent("file.txt")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)
        try repo.GKAdd(path: "file.txt")
        let author = GKSignature(name: "Test", email: "test@test.com")
        try repo.GKCreateCommit(message: "Initial", author: author)

        // Create branch
        try repo.GKCreateBranch(name: "feature")
        let branches = try repo.branches()
        #expect(branches.contains(where: { $0.name == "feature" }))

        // Delete branch
        try repo.GKDeleteBranch(name: "feature")
        let branchesAfter = try repo.branches()
        #expect(!branchesAfter.contains(where: { $0.name == "feature" }))
    }

    @Test func createTag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-tag-test-\(UUID().uuidString)")

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)

        let filePath = tempDir.appendingPathComponent("file.txt")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)
        try repo.GKAdd(path: "file.txt")
        let author = GKSignature(name: "Test", email: "test@test.com")
        try repo.GKCreateCommit(message: "Initial", author: author)

        try repo.GKCreateTag(name: "v1.0.0")
        let tags = try repo.tags()
        #expect(tags.contains(where: { $0.shortName == "v1.0.0" }))
    }
}

// MARK: - Ignore Tests

@Suite("GKIgnore")
struct GKIgnoreTests {
    @Test func basicPatterns() {
        let ignore = GKIgnore(patterns: GKIgnore.parse("*.o\n*.a\nbuild/\n!important.o"))
        #expect(ignore.isIgnored(path: "test.o"))
        #expect(ignore.isIgnored(path: "lib.a"))
        #expect(!ignore.isIgnored(path: "important.o"))
        #expect(!ignore.isIgnored(path: "test.c"))
    }

    // 4.1 Anchored directory patterns
    @Test func anchoredDirectoryPattern() {
        let ignore = GKIgnore(patterns: GKIgnore.parse("/build"))
        #expect(ignore.isIgnored(path: "build/a.o"))
        #expect(!ignore.isIgnored(path: "src/build/keep.o"))

        let slash = GKIgnore(patterns: GKIgnore.parse("/build/"))
        #expect(slash.isIgnored(path: "build/a.o"))
        #expect(!slash.isIgnored(path: "src/build/keep.o"))
    }

    // 4.2 Anchored mid-slash pattern
    @Test func anchoredMidSlashPattern() {
        let ignore = GKIgnore(patterns: GKIgnore.parse("src/gen"))
        #expect(ignore.isIgnored(path: "src/gen/file.swift"))
        #expect(!ignore.isIgnored(path: "lib/src/gen/file.swift"))
    }

    // 4.3 Floating single token matches at any depth
    @Test func floatingTokenMatchesAnyDepth() {
        let ignore = GKIgnore(patterns: GKIgnore.parse("node_modules"))
        #expect(ignore.isIgnored(path: "node_modules/x.js"))
        #expect(ignore.isIgnored(path: "packages/a/node_modules/y.js"))
    }

    // 4.4 Glob: character classes, ?, *, and ** spanning directories
    @Test func globAndDoubleStar() {
        let cls = GKIgnore(patterns: GKIgnore.parse("*.[oa]"))
        #expect(cls.isIgnored(path: "m.o"))
        #expect(cls.isIgnored(path: "m.a"))
        #expect(!cls.isIgnored(path: "m.c"))

        let q = GKIgnore(patterns: GKIgnore.parse("file?.txt"))
        #expect(q.isIgnored(path: "file1.txt"))
        #expect(!q.isIgnored(path: "file10.txt"))

        let ds = GKIgnore(patterns: GKIgnore.parse("logs/**/*.txt"))
        #expect(ds.isIgnored(path: "logs/2026/06/x.txt"))
        #expect(ds.isIgnored(path: "logs/a.txt"))
        #expect(!ds.isIgnored(path: "logs/a.csv"))

        let neg = GKIgnore(patterns: GKIgnore.parse("[!a].txt"))
        #expect(neg.isIgnored(path: "b.txt"))
        #expect(!neg.isIgnored(path: "a.txt"))
    }
}

// MARK: - Gitignore Exclusion Tests

@Suite("GKGitignoreExclusion")
struct GKGitignoreExclusionTests {
    /// Creates a fresh repository in a unique temporary directory.
    private func makeRepo() throws -> (GKRepository, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-ignore-test-\(UUID().uuidString)")
        let repo = try GKRepository.GKInitRepository(at: tempDir)
        return (repo, tempDir)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func localGitignoreIsHonored() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("noise", to: dir.appendingPathComponent("debug.log"))

        #expect(repo.isIgnored("debug.log"))
        #expect(!repo.isIgnored("main.swift"))
    }

    @Test func nestedGitignoreNegationOverridesParent() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("!keep.log\n", to: dir.appendingPathComponent("subdir/.gitignore"))
        try write("x", to: dir.appendingPathComponent("subdir/keep.log"))
        try write("x", to: dir.appendingPathComponent("subdir/other.log"))

        #expect(!repo.isIgnored("subdir/keep.log"))
        #expect(repo.isIgnored("subdir/other.log"))
    }

    @Test func infoExcludeIsHonored() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("secret.txt\n", to: dir.appendingPathComponent(".git/info/exclude"))

        #expect(repo.isIgnored("secret.txt"))
        #expect(!repo.isIgnored("public.txt"))
    }

    @Test func globalExcludesFileIsHonored() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let globalIgnore = dir.appendingPathComponent("global_ignore")
        try write("*.tmp\n", to: globalIgnore)
        try repo.configuration.set("core.excludesFile", value: globalIgnore.path)

        #expect(repo.isIgnored("scratch.tmp"))
        #expect(!repo.isIgnored("scratch.txt"))
    }

    @Test func missingSourcesDoNotThrowAndIgnoreNothing() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!repo.isIgnored("anything.txt"))
        #expect(!repo.isIgnored("nested/file.bin"))
    }

    @Test func addSkipsIgnoredUntrackedFile() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("noise", to: dir.appendingPathComponent("debug.log"))

        try repo.GKAdd(path: "debug.log")

        let index = try repo.readIndex()
        #expect(!index.entries.contains { $0.path == "debug.log" })
    }

    @Test func addDirectoryStagesOnlyNonIgnoredEntries() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("a", to: dir.appendingPathComponent("src/keep.swift"))
        try write("b", to: dir.appendingPathComponent("src/skip.log"))

        try repo.GKAdd(path: "src")

        let index = try repo.readIndex()
        #expect(index.entries.contains { $0.path == "src/keep.swift" })
        #expect(!index.entries.contains { $0.path == "src/skip.log" })
    }

    @Test func alreadyTrackedIgnoredFileCanStillBeAdded() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Track the file first, before any ignore rule exists.
        let fileURL = dir.appendingPathComponent("tracked.log")
        try write("v1", to: fileURL)
        try repo.GKAdd(path: "tracked.log")

        // Now ignore *.log and modify the tracked file.
        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("v2", to: fileURL)
        try repo.GKAdd(path: "tracked.log")

        let index = try repo.readIndex()
        let entry = index.entries.first { $0.path == "tracked.log" }
        #expect(entry != nil)
        let blob = try repo.lookupBlob(oid: entry!.oid)
        #expect(blob.text == "v2")
    }

    @Test func statusOmitsIgnoredUntrackedButReportsTrackedModifications() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Track and commit a file.
        let tracked = dir.appendingPathComponent("tracked.txt")
        try write("v1", to: tracked)
        try repo.GKAdd(path: "tracked.txt")
        let author = GKSignature(name: "Test", email: "test@test.com")
        try repo.GKCreateCommit(message: "Initial", author: author)

        // Add an ignore rule and an ignored untracked file, then modify the tracked file.
        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try write("noise", to: dir.appendingPathComponent("debug.log"))
        try write("v2", to: tracked)

        let status = try repo.status()
        #expect(!status.untracked.contains("debug.log"))
        #expect(status.unstaged.contains { $0.path == "tracked.txt" })
    }

    // 4.8 The reported bug: root-anchored directory excludes its contents from status.
    @Test func statusExcludesRootAnchoredIgnoredDirectory() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("/dist\n", to: dir.appendingPathComponent(".gitignore"))
        try write("x", to: dir.appendingPathComponent("dist/bundle.js"))
        try write("y", to: dir.appendingPathComponent("keep.txt"))

        let status = try repo.status()
        #expect(!status.untracked.contains("dist/bundle.js"))
        #expect(status.untracked.contains("keep.txt"))
    }

    // 4.6 Nested .gitignore is scoped to its own directory.
    @Test func nestedGitignoreIsScopedToItsDirectory() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("/build\n", to: dir.appendingPathComponent("sub/.gitignore"))
        #expect(repo.isIgnored("sub/build/x.o"))
        #expect(!repo.isIgnored("build/y.o"))

        try write("*.log\n", to: dir.appendingPathComponent("sub2/.gitignore"))
        #expect(repo.isIgnored("sub2/a.log"))
        #expect(repo.isIgnored("sub2/deep/b.log"))
        #expect(!repo.isIgnored("other/c.log"))
    }

    // 4.7 Dotfiles: non-ignored reported untracked; ignored excluded; .git never reported.
    @Test func statusReportsNonIgnoredDotfilesButNotGitOrIgnored() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(".env\n", to: dir.appendingPathComponent(".gitignore"))
        try write("secret", to: dir.appendingPathComponent(".env"))
        try write("x", to: dir.appendingPathComponent(".keepme"))

        let status = try repo.status()
        // Non-ignored dotfiles (.gitignore itself and .keepme) are reported.
        #expect(status.untracked.contains(".gitignore"))
        #expect(status.untracked.contains(".keepme"))
        // The ignored dotfile is not reported.
        #expect(!status.untracked.contains(".env"))
        // Nothing under .git is ever reported.
        #expect(!status.untracked.contains { $0.hasPrefix(".git/") })
    }
}


// MARK: - Diff Tests

@Suite("GKDiffEngine")
struct GKDiffEngineTests {
    @Test func computeHunks() {
        let oldLines = ["line1", "line2", "line3"]
        let newLines = ["line1", "modified", "line3", "added"]
        let hunks = GKDiffEngine.computeHunks(oldLines: oldLines, newLines: newLines)
        #expect(!hunks.isEmpty)
        #expect(hunks[0].insertions > 0 || hunks[0].deletions > 0)
    }
}

// MARK: - Index Tests

@Suite("GKIndex")
struct GKIndexTests {
    @Test func addEntry() throws {
        var index = GKIndex()
        let oid = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        try index.add(path: "test.txt", oid: oid, mode: .regular)
        #expect(index.entries.count == 1)
        #expect(index.entries[0].path == "test.txt")
    }

    @Test func removeEntry() throws {
        var index = GKIndex()
        let oid = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        try index.add(path: "test.txt", oid: oid, mode: .regular)
        try index.remove(path: "test.txt")
        #expect(index.entries.isEmpty)
    }
}

// MARK: - Status Stat Cache Tests

@Suite("GKStatusStatCache")
struct GKStatusStatCacheTests {
    private func makeRepo() throws -> (GKRepository, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-statcache-test-\(UUID().uuidString)")
        let repo = try GKRepository.GKInitRepository(at: tempDir)
        return (repo, tempDir)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Backdates a file's modification time so it predates the next index write,
    /// taking it out of the "racily clean" window for deterministic fast-path tests.
    private func backdate(_ url: URL, secondsAgo: TimeInterval = 10) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-secondsAgo)],
            ofItemAtPath: url.path)
    }

    private func commitAll(_ repo: GKRepository) throws -> GKObjectID {
        let author = GKSignature(name: "Test", email: "test@test.com")
        return try repo.GKCreateCommit(message: "c", author: author)
    }

    // 5.1
    @Test func statRoundTripsThroughIndex() throws {
        var index = GKIndex()
        let oid = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        let stat = GKFileStat(
            ctimeSeconds: 111, ctimeNanoseconds: 222,
            mtimeSeconds: 333, mtimeNanoseconds: 444,
            dev: 5, ino: 6, uid: 7, gid: 8, fileSize: 99)
        try index.add(path: "test.txt", oid: oid, mode: .regular, stat: stat)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let indexURL = tempDir.appendingPathComponent("index")
        try index.write(to: indexURL)

        let parsed = try GKIndex(from: indexURL)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries[0].stat == stat)
    }

    // 5.2
    @Test func statusSkipsUnchangedFile() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try write("hello", to: file)
        try backdate(file)
        try repo.GKAdd(path: "a.txt")
        _ = try commitAll(repo)

        let status = try repo.status()
        #expect(!status.unstaged.contains { $0.path == "a.txt" })
        #expect(status.isClean)
    }

    // 5.3
    @Test func statusDetectsModifiedContent() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try write("hello", to: file)
        try backdate(file)
        try repo.GKAdd(path: "a.txt")
        _ = try commitAll(repo)

        try write("changed", to: file)
        let status = try repo.status()
        #expect(status.unstaged.contains { $0.path == "a.txt" })
    }

    // 5.4
    @Test func statusUnmodifiedWhenStatDiffersButContentIdentical() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try write("hello", to: file)
        try backdate(file)
        try repo.GKAdd(path: "a.txt")
        _ = try commitAll(repo)

        // Rewrite identical content — changes mtime so stat no longer matches,
        // forcing a content check that must conclude "unmodified".
        try write("hello", to: file)
        let status = try repo.status()
        #expect(!status.unstaged.contains { $0.path == "a.txt" })
    }

    // 5.5
    @Test func mixedResetMarksCleanOrModifiedByContent() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try write("v1", to: file)
        try backdate(file)
        try repo.GKAdd(path: "a.txt")
        let commitOID = try commitAll(repo)

        // Identical content: reset --mixed leaves the file clean.
        try backdate(file)
        try repo.GKReset(to: commitOID, mode: .mixed)
        #expect(try repo.status().unstaged.contains { $0.path == "a.txt" } == false)

        // Differing content: reset --mixed to the same commit surfaces the change.
        try write("v2", to: file)
        try repo.GKReset(to: commitOID, mode: .mixed)
        #expect(try repo.status().unstaged.contains { $0.path == "a.txt" })
    }

    // 5.6
    @Test func racilyCleanEntriesAreSmudgedAndVerified() throws {
        // Unit: an entry whose mtime is at/after the index mtime is smudged to size 0.
        var index = GKIndex()
        let oid = GKObjectID(hex: "abc1234567890abcdef1234567890abcdef12345")!
        try index.add(path: "a.txt", oid: oid, mode: .regular,
                      stat: GKFileStat(mtimeSeconds: 1000, fileSize: 42))
        index.smudgeRacilyCleanEntries(indexMtimeSeconds: 1000)
        #expect(index.entries[0].stat.fileSize == 0)

        // An older entry is left untouched.
        var index2 = GKIndex()
        try index2.add(path: "b.txt", oid: oid, mode: .regular,
                       stat: GKFileStat(mtimeSeconds: 500, fileSize: 42))
        index2.smudgeRacilyCleanEntries(indexMtimeSeconds: 1000)
        #expect(index2.entries[0].stat.fileSize == 42)

        // Integration: a same-tick modification (file not backdated, so racy) is
        // still detected, and an unmodified racy file stays clean.
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try write("aaaa", to: file)
        try repo.GKAdd(path: "a.txt") // staged "now" → racily clean
        _ = try commitAll(repo)

        // Equal-length content change; only content verification can catch it.
        try write("bbbb", to: file)
        #expect(try repo.status().unstaged.contains { $0.path == "a.txt" })
    }
}

// MARK: - Packfile Test Helpers

/// Builders for constructing packfiles (including delta entries) used by the
/// packfile-parsing tests.
enum PackTestHelper {
    /// Encodes a pack entry header: 3-bit type + little-endian size.
    static func entryHeader(type: UInt8, size: Int) -> [UInt8] {
        var bytes = [UInt8]()
        var s = size
        var first = (type << 4) | UInt8(s & 0x0F)
        s >>= 4
        if s > 0 { first |= 0x80 }
        bytes.append(first)
        while s > 0 {
            var b = UInt8(s & 0x7F)
            s >>= 7
            if s > 0 { b |= 0x80 }
            bytes.append(b)
        }
        return bytes
    }

    /// Encodes an OFS_DELTA negative base offset (big-endian, +1 carry).
    static func encodeOffset(_ value: Int) -> [UInt8] {
        var n = value
        var bytes = [UInt8(n & 0x7F)]
        n >>= 7
        while n > 0 {
            n -= 1
            bytes.insert(UInt8((n & 0x7F) | 0x80), at: 0)
            n >>= 7
        }
        return bytes
    }

    /// Encodes a delta size field (little-endian, 7-bits-per-byte varint).
    static func encodeDeltaSize(_ size: Int) -> [UInt8] {
        var s = size
        var bytes = [UInt8]()
        repeat {
            var b = UInt8(s & 0x7F)
            s >>= 7
            if s > 0 { b |= 0x80 }
            bytes.append(b)
        } while s > 0
        return bytes
    }

    /// Builds a copy instruction (copy `size` bytes from base at `offset`).
    static func copyInstruction(offset: Int, size: Int) -> [UInt8] {
        var opcode: UInt8 = 0x80
        var rest = [UInt8]()
        for i in 0..<4 {
            let byte = UInt8((offset >> (8 * i)) & 0xFF)
            if byte != 0 { opcode |= UInt8(1 << i); rest.append(byte) }
        }
        for i in 0..<3 {
            let byte = UInt8((size >> (8 * i)) & 0xFF)
            if byte != 0 { opcode |= UInt8(1 << (4 + i)); rest.append(byte) }
        }
        return [opcode] + rest
    }

    /// Builds an insert instruction appending `data` literally (< 128 bytes).
    static func insertInstruction(_ data: [UInt8]) -> [UInt8] {
        [UInt8(data.count)] + data
    }

    /// Assembles a delta payload from base/result sizes and instructions.
    static func delta(baseSize: Int, resultSize: Int, instructions: [[UInt8]]) -> Data {
        var bytes = encodeDeltaSize(baseSize) + encodeDeltaSize(resultSize)
        for ins in instructions { bytes += ins }
        return Data(bytes)
    }

    /// Builds a complete pack entry, compressing the payload.
    static func entry(type: UInt8, payload: Data, baseRef: [UInt8] = []) throws -> [UInt8] {
        var bytes = entryHeader(type: type, size: payload.count)
        bytes += baseRef
        bytes += [UInt8](try GKZlib.compress(payload))
        return bytes
    }

    /// Assembles a v2 packfile from raw entry byte arrays, appending the trailer.
    static func pack(entries: [[UInt8]]) -> Data {
        var bytes: [UInt8] = [0x50, 0x41, 0x43, 0x4B, 0, 0, 0, 2]
        let count = UInt32(entries.count)
        bytes += [UInt8(count >> 24), UInt8(count >> 16), UInt8(count >> 8), UInt8(count & 0xFF)]
        for e in entries { bytes += e }
        bytes += GKSHA1.hash(Data(bytes))
        return Data(bytes)
    }

    /// Big-endian 4-byte encoding.
    static func beUInt32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Builds a v2 pack index (`.idx`) mapping each OID to its pack offset.
    /// Offsets ≥ 2^31 are emitted via the 8-byte large-offset table.
    static func index(_ entries: [(oid: GKObjectID, offset: Int)]) -> Data {
        let sorted = entries.sorted { $0.oid < $1.oid }

        var bytes: [UInt8] = [0xFF, 0x74, 0x4F, 0x63, 0, 0, 0, 2]

        // Fanout: cumulative counts by first OID byte.
        var fanout = [UInt32](repeating: 0, count: 256)
        for entry in sorted {
            let b = Int(entry.oid.bytes[0])
            for i in b..<256 { fanout[i] += 1 }
        }
        for f in fanout { bytes += beUInt32(f) }

        // Sorted OID table.
        for entry in sorted { bytes += entry.oid.bytes }

        // CRC table (zeros — not validated by the reader).
        for _ in sorted { bytes += [0, 0, 0, 0] }

        // Offset table, spilling to the large-offset table when needed.
        var largeOffsets = [UInt64]()
        for entry in sorted {
            if entry.offset < 0x8000_0000 {
                bytes += beUInt32(UInt32(entry.offset))
            } else {
                bytes += beUInt32(0x8000_0000 | UInt32(largeOffsets.count))
                largeOffsets.append(UInt64(entry.offset))
            }
        }
        for large in largeOffsets {
            for i in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((large >> UInt64(i)) & 0xFF))
            }
        }

        // Packfile checksum + index checksum (zeros — not validated by the reader).
        bytes += [UInt8](repeating: 0, count: 40)
        return Data(bytes)
    }
}

// MARK: - Zlib Stream Tests

@Suite("GKZlib stream")
struct GKZlibStreamTests {
    @Test func inflateZlibStreamRoundTrip() throws {
        let original = Data("the quick brown fox jumps over the lazy dog".utf8)
        let compressed = try GKZlib.compress(original)
        // Append trailing bytes to ensure the stream length is reported, not the buffer length.
        let buffer = [UInt8](compressed) + [0xDE, 0xAD, 0xBE, 0xEF]

        let (data, bytesRead) = try GKZlib.inflateZlibStream(buffer)
        #expect(data == original)
        #expect(bytesRead == compressed.count)
    }
}

// MARK: - Packfile Reader Tests

@Suite("GKPackfileReader")
struct GKPackfileReaderTests {
    @Test func roundTripBaseObjects() throws {
        let blob = GKRawObject(type: .blob, data: Data("hello world".utf8))
        let tree = GKRawObject(type: .tree, data: Data("tree contents".utf8))
        let commit = GKRawObject(type: .commit, data: Data("commit body".utf8))

        let packData = try GKPackfileWriter.createPackfile(objects: [blob, tree, commit])
        let parsed = try GKPackfileReader.parse(packData)

        let parsedOIDs = Set(parsed.map { $0.oid })
        #expect(parsedOIDs == Set([blob.oid, tree.oid, commit.oid]))
    }

    @Test func resolveOfsDelta() throws {
        let baseData = Data("hello world".utf8)
        let expected = Data("hello world!!".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: baseData) // blob
        let baseStart = 12

        let deltaPayload = PackTestHelper.delta(
            baseSize: baseData.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseData.count),
                PackTestHelper.insertInstruction(Array("!!".utf8))
            ]
        )
        let deltaStart = baseStart + baseEntry.count
        let negOffset = deltaStart - baseStart
        let deltaEntry = try PackTestHelper.entry(
            type: 6, // OFS_DELTA
            payload: deltaPayload,
            baseRef: PackTestHelper.encodeOffset(negOffset)
        )

        let packData = PackTestHelper.pack(entries: [baseEntry, deltaEntry])
        let parsed = try GKPackfileReader.parse(packData)

        let resolved = parsed.first { GKRawObject(type: .blob, data: expected).oid == $0.oid }
        #expect(resolved != nil)
        #expect(resolved?.type == .blob)
        #expect(resolved?.data == expected)
    }

    @Test func resolveRefDeltaInPack() throws {
        let baseObject = GKRawObject(type: .blob, data: Data("base content".utf8))
        let expected = Data("base content!".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: baseObject.data)
        let deltaPayload = PackTestHelper.delta(
            baseSize: baseObject.data.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseObject.data.count),
                PackTestHelper.insertInstruction(Array("!".utf8))
            ]
        )
        let deltaEntry = try PackTestHelper.entry(
            type: 7, // REF_DELTA
            payload: deltaPayload,
            baseRef: baseObject.oid.bytes
        )

        let packData = PackTestHelper.pack(entries: [baseEntry, deltaEntry])
        let parsed = try GKPackfileReader.parse(packData)

        let resolved = parsed.first { $0.data == expected }
        #expect(resolved != nil)
        #expect(resolved?.type == .blob)
    }

    @Test func resolveRefDeltaThinPack() throws {
        let baseObject = GKRawObject(type: .blob, data: Data("external base".utf8))
        let expected = Data("external base?".utf8)

        let deltaPayload = PackTestHelper.delta(
            baseSize: baseObject.data.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseObject.data.count),
                PackTestHelper.insertInstruction(Array("?".utf8))
            ]
        )
        let deltaEntry = try PackTestHelper.entry(
            type: 7,
            payload: deltaPayload,
            baseRef: baseObject.oid.bytes
        )

        let packData = PackTestHelper.pack(entries: [deltaEntry])
        let parsed = try GKPackfileReader.parse(packData) { oid in
            oid == baseObject.oid ? baseObject : nil
        }

        #expect(parsed.count == 1)
        #expect(parsed.first?.data == expected)
        #expect(parsed.first?.type == .blob)
    }

    @Test func unresolvableRefDeltaThrows() throws {
        let missingOID = GKObjectID(hex: "1111111111111111111111111111111111111111")!
        let deltaPayload = PackTestHelper.delta(
            baseSize: 4,
            resultSize: 4,
            instructions: [PackTestHelper.insertInstruction(Array("data".utf8))]
        )
        let deltaEntry = try PackTestHelper.entry(type: 7, payload: deltaPayload, baseRef: missingOID.bytes)
        let packData = PackTestHelper.pack(entries: [deltaEntry])

        #expect(throws: GKError.self) {
            _ = try GKPackfileReader.parse(packData)
        }
    }

    @Test func resolveChainedDeltas() throws {
        let baseData = Data("abc".utf8)
        let level1 = Data("abcd".utf8)
        let level2 = Data("abcde".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: baseData)
        let baseStart = 12

        // Delta 1: base -> level1
        let delta1 = PackTestHelper.delta(
            baseSize: baseData.count,
            resultSize: level1.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseData.count),
                PackTestHelper.insertInstruction(Array("d".utf8))
            ]
        )
        let delta1Start = baseStart + baseEntry.count
        let delta1Entry = try PackTestHelper.entry(
            type: 6,
            payload: delta1,
            baseRef: PackTestHelper.encodeOffset(delta1Start - baseStart)
        )

        // Delta 2: level1 -> level2 (base is delta1)
        let delta2 = PackTestHelper.delta(
            baseSize: level1.count,
            resultSize: level2.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: level1.count),
                PackTestHelper.insertInstruction(Array("e".utf8))
            ]
        )
        let delta2Start = delta1Start + delta1Entry.count
        let delta2Entry = try PackTestHelper.entry(
            type: 6,
            payload: delta2,
            baseRef: PackTestHelper.encodeOffset(delta2Start - delta1Start)
        )

        let packData = PackTestHelper.pack(entries: [baseEntry, delta1Entry, delta2Entry])
        let parsed = try GKPackfileReader.parse(packData)

        #expect(parsed.contains { $0.data == level2 })
    }

    @Test func corruptedTrailerThrows() throws {
        let blob = GKRawObject(type: .blob, data: Data("trailer test".utf8))
        var packData = try GKPackfileWriter.createPackfile(objects: [blob])
        // Corrupt the final checksum byte.
        let lastIndex = packData.count - 1
        packData[lastIndex] = packData[lastIndex] ^ 0xFF

        #expect(throws: GKError.self) {
            _ = try GKPackfileReader.parse(packData)
        }
    }
}

// MARK: - Pack Index Tests

@Suite("GKPackIndex")
struct GKPackIndexTests {
    @Test func lookupAndContains() throws {
        let a = GKObjectID(hex: "0011223344556677889900112233445566778899")!
        let b = GKObjectID(hex: "aabbccddeeff00112233445566778899aabbccdd")!
        let missing = GKObjectID(hex: "ffffffffffffffffffffffffffffffffffffffff")!

        let idxData = PackTestHelper.index([(a, 12), (b, 4096)])
        let index = try GKPackIndex(data: idxData)

        #expect(index.objectCount == 2)
        #expect(index.offset(for: a) == 12)
        #expect(index.offset(for: b) == 4096)
        #expect(index.offset(for: missing) == nil)
        #expect(index.contains(a))
        #expect(!index.contains(missing))
    }

    @Test func resolvesLargeOffsets() throws {
        let oid = GKObjectID(hex: "1234567890abcdef1234567890abcdef12345678")!
        let bigOffset = 0x1_0000_0000 // 4 GiB, requires the large-offset table

        let idxData = PackTestHelper.index([(oid, bigOffset)])
        let index = try GKPackIndex(data: idxData)

        #expect(index.offset(for: oid) == UInt64(bigOffset))
    }

    @Test func invalidIndexThrows() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03] + [UInt8](repeating: 0, count: 2048))
        #expect(throws: GKError.self) {
            _ = try GKPackIndex(data: bogus)
        }
    }
}

// MARK: - Pack Random-Access Tests

@Suite("GKPackRandomAccess")
struct GKPackRandomAccessTests {
    /// Builds a pack from payload entries and returns the pack bytes plus the
    /// byte offset of each entry.
    private func buildPack(_ entries: [[UInt8]]) -> (bytes: [UInt8], offsets: [Int]) {
        var offsets = [Int]()
        var running = 12 // header
        for e in entries {
            offsets.append(running)
            running += e.count
        }
        let packData = PackTestHelper.pack(entries: entries)
        return ([UInt8](packData), offsets)
    }

    @Test func readsNonDeltaObject() throws {
        let blob = GKRawObject(type: .blob, data: Data("a base blob".utf8))
        let entry = try PackTestHelper.entry(type: 3, payload: blob.data)
        let (bytes, offsets) = buildPack([entry])

        let read = try GKPackfileReader.readObject(at: offsets[0], in: bytes)
        #expect(read.oid == blob.oid)
        #expect(read.type == .blob)
        #expect(read.data == blob.data)
    }

    @Test func readsOfsDelta() throws {
        let baseData = Data("hello world".utf8)
        let expected = Data("hello world!!".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: baseData)
        let deltaPayload = PackTestHelper.delta(
            baseSize: baseData.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseData.count),
                PackTestHelper.insertInstruction(Array("!!".utf8))
            ]
        )
        // Offsets: base at 12, delta right after.
        let deltaStart = 12 + baseEntry.count
        let deltaEntry = try PackTestHelper.entry(
            type: 6,
            payload: deltaPayload,
            baseRef: PackTestHelper.encodeOffset(deltaStart - 12)
        )
        let (bytes, offsets) = buildPack([baseEntry, deltaEntry])

        let read = try GKPackfileReader.readObject(at: offsets[1], in: bytes)
        #expect(read.type == .blob)
        #expect(read.data == expected)
    }

    @Test func readsRefDeltaWithinPack() throws {
        let base = GKRawObject(type: .blob, data: Data("base content".utf8))
        let expected = Data("base content!".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: base.data)
        let deltaPayload = PackTestHelper.delta(
            baseSize: base.data.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: base.data.count),
                PackTestHelper.insertInstruction(Array("!".utf8))
            ]
        )
        let deltaEntry = try PackTestHelper.entry(type: 7, payload: deltaPayload, baseRef: base.oid.bytes)
        let (bytes, offsets) = buildPack([baseEntry, deltaEntry])

        let idx = try GKPackIndex(data: PackTestHelper.index([(base.oid, offsets[0])]))
        let read = try GKPackfileReader.readObject(
            at: offsets[1],
            in: bytes,
            offsetForOID: { idx.offset(for: $0).map(Int.init) }
        )
        #expect(read.type == .blob)
        #expect(read.data == expected)
    }

    @Test func readsRefDeltaViaBaseLookup() throws {
        let base = GKRawObject(type: .blob, data: Data("external base".utf8))
        let expected = Data("external base?".utf8)

        let deltaPayload = PackTestHelper.delta(
            baseSize: base.data.count,
            resultSize: expected.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: base.data.count),
                PackTestHelper.insertInstruction(Array("?".utf8))
            ]
        )
        let deltaEntry = try PackTestHelper.entry(type: 7, payload: deltaPayload, baseRef: base.oid.bytes)
        let (bytes, offsets) = buildPack([deltaEntry])

        let read = try GKPackfileReader.readObject(
            at: offsets[0],
            in: bytes,
            baseLookup: { $0 == base.oid ? base : nil }
        )
        #expect(read.data == expected)
        #expect(read.type == .blob)
    }

    @Test func readsChainedDelta() throws {
        let baseData = Data("abc".utf8)
        let level1 = Data("abcd".utf8)
        let level2 = Data("abcde".utf8)

        let baseEntry = try PackTestHelper.entry(type: 3, payload: baseData)
        let delta1 = PackTestHelper.delta(
            baseSize: baseData.count, resultSize: level1.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: baseData.count),
                PackTestHelper.insertInstruction(Array("d".utf8))
            ])
        let delta1Start = 12 + baseEntry.count
        let delta1Entry = try PackTestHelper.entry(
            type: 6, payload: delta1, baseRef: PackTestHelper.encodeOffset(delta1Start - 12))

        let delta2 = PackTestHelper.delta(
            baseSize: level1.count, resultSize: level2.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: level1.count),
                PackTestHelper.insertInstruction(Array("e".utf8))
            ])
        let delta2Start = delta1Start + delta1Entry.count
        let delta2Entry = try PackTestHelper.entry(
            type: 6, payload: delta2, baseRef: PackTestHelper.encodeOffset(delta2Start - delta1Start))

        let (bytes, offsets) = buildPack([baseEntry, delta1Entry, delta2Entry])
        let read = try GKPackfileReader.readObject(at: offsets[2], in: bytes)
        #expect(read.data == level2)
    }

    @Test func parityWithWholePackParse() throws {
        let b1 = GKRawObject(type: .blob, data: Data("first blob".utf8))
        let b2 = GKRawObject(type: .blob, data: Data("second blob, a bit longer".utf8))
        let expectedDelta = Data("second blob, a bit longer!!!".utf8)

        let e1 = try PackTestHelper.entry(type: 3, payload: b1.data)
        let e2 = try PackTestHelper.entry(type: 3, payload: b2.data)
        let deltaPayload = PackTestHelper.delta(
            baseSize: b2.data.count, resultSize: expectedDelta.count,
            instructions: [
                PackTestHelper.copyInstruction(offset: 0, size: b2.data.count),
                PackTestHelper.insertInstruction(Array("!!!".utf8))
            ])
        let e2Start = 12 + e1.count
        let e3Start = e2Start + e2.count
        let e3 = try PackTestHelper.entry(
            type: 6, payload: deltaPayload, baseRef: PackTestHelper.encodeOffset(e3Start - e2Start))

        let (bytes, offsets) = buildPack([e1, e2, e3])
        let packData = Data(bytes)

        // Whole-pack parse returns objects in entry order.
        let parsed = try GKPackfileReader.parse(packData)
        let idxEntries = zip(parsed, offsets).map { ($0.oid, $1) }
        let idx = try GKPackIndex(data: PackTestHelper.index(idxEntries))

        for (object, offset) in zip(parsed, offsets) {
            let read = try GKPackfileReader.readObject(
                at: offset, in: bytes,
                offsetForOID: { idx.offset(for: $0).map(Int.init) })
            #expect(read.oid == object.oid)
            #expect(read.data == object.data)
        }
    }
}

// MARK: - Object Integrity Verification Tests

@Suite("GKObjectIntegrity")
struct GKObjectIntegrityTests {
    private func makeObjectsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gkintegrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pack"), withIntermediateDirectories: true)
        return dir
    }

    private func loosePath(for oid: GKObjectID, in objectsDir: URL) -> URL {
        let hex = oid.hex
        return objectsDir
            .appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(String(hex.dropFirst(2)))
    }

    /// A loose object whose stored content does not hash to the OID it is filed
    /// under must be rejected on read rather than silently returned.
    @Test func tamperedLooseObjectIsRejected() throws {
        let objectsDir = try makeObjectsDir()
        defer { try? FileManager.default.removeItem(at: objectsDir) }

        let real = GKRawObject(type: .blob, data: Data("authentic content".utf8))
        let forged = GKRawObject(type: .blob, data: Data("tampered content".utf8))

        // Place the forged object's bytes at the *real* object's loose path, so
        // the filename claims one OID while the content hashes to another.
        let path = loosePath(for: real.oid, in: objectsDir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GKZlib.compress(forged.serialized).write(to: path)

        let db = GKLooseObjectDatabase(objectsURL: objectsDir)
        #expect(throws: GKError.self) {
            _ = try db.read(oid: real.oid)
        }
    }

    /// A faithfully stored object still reads back successfully.
    @Test func untamperedObjectReadsSuccessfully() throws {
        let objectsDir = try makeObjectsDir()
        defer { try? FileManager.default.removeItem(at: objectsDir) }

        let db = GKLooseObjectDatabase(objectsURL: objectsDir)
        let blob = GKRawObject(type: .blob, data: Data("genuine".utf8))
        try db.write(blob)

        let read = try db.read(oid: blob.oid)
        #expect(read.oid == blob.oid)
        #expect(read.data == blob.data)
    }

    /// The error reports the expected and actual OIDs for diagnosis.
    @Test func mismatchErrorCarriesBothOIDs() throws {
        let objectsDir = try makeObjectsDir()
        defer { try? FileManager.default.removeItem(at: objectsDir) }

        let real = GKRawObject(type: .blob, data: Data("aaaa".utf8))
        let forged = GKRawObject(type: .blob, data: Data("bbbb".utf8))
        let path = loosePath(for: real.oid, in: objectsDir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GKZlib.compress(forged.serialized).write(to: path)

        let db = GKLooseObjectDatabase(objectsURL: objectsDir)
        do {
            _ = try db.read(oid: real.oid)
            Issue.record("Expected a hash-mismatch error")
        } catch let GKError.objectHashMismatch(expected, actual) {
            #expect(expected == real.oid)
            #expect(actual == forged.oid)
        }
    }
}

// MARK: - Object Database Pack Tests

@Suite("GKLooseObjectDatabase packs")
struct GKLooseObjectDatabasePackTests {
    private func makeObjectsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gkdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("pack"), withIntermediateDirectories: true)
        return dir
    }

    @Test func resolvesPackedObjectWithoutIndex() throws {
        let objectsDir = try makeObjectsDir()
        defer { try? FileManager.default.removeItem(at: objectsDir) }

        let blob = GKRawObject(type: .blob, data: Data("packed but unindexed".utf8))
        let packData = try GKPackfileWriter.createPackfile(objects: [blob])
        // Write a .pack with NO accompanying .idx.
        try packData.write(to: objectsDir.appendingPathComponent("pack/pack-test.pack"))

        let db = GKLooseObjectDatabase(objectsURL: objectsDir)
        #expect(db.exists(oid: blob.oid))
        let read = try db.read(oid: blob.oid)
        #expect(read.oid == blob.oid)
        #expect(read.data == blob.data)
    }

    @Test func repeatedReadServedFromCache() throws {
        let objectsDir = try makeObjectsDir()
        defer { try? FileManager.default.removeItem(at: objectsDir) }

        let db = GKLooseObjectDatabase(objectsURL: objectsDir)
        let blob = GKRawObject(type: .blob, data: Data("cache me".utf8))
        try db.write(blob)

        // First read populates the cache.
        let first = try db.read(oid: blob.oid)
        #expect(first.oid == blob.oid)

        // Remove the backing loose file; a cached read must still succeed.
        let hex = blob.oid.hex
        let loosePath = objectsDir
            .appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(String(hex.dropFirst(2)))
        try FileManager.default.removeItem(at: loosePath)

        let second = try db.read(oid: blob.oid)
        #expect(second.oid == blob.oid)
        #expect(second.data == blob.data)
    }
}

// MARK: - Path & Reference Name Validation Tests

@Suite("GKPathValidation")
struct GKPathValidationTests {
    // MARK: Tree entry names

    @Test func acceptsOrdinaryNames() throws {
        try GKPathValidation.validateTreeEntryName("README.md")
        try GKPathValidation.validateTreeEntryName("src")
        try GKPathValidation.validateTreeEntryName(".gitignore")
        try GKPathValidation.validateTreeEntryName("file with spaces.txt")
    }

    @Test func rejectsTraversalNames() {
        for name in ["..", ".", "", "../etc", "a/b", "a\\b"] {
            #expect(throws: GKError.self) {
                try GKPathValidation.validateTreeEntryName(name)
            }
        }
    }

    @Test func rejectsNulByte() {
        #expect(throws: GKError.self) {
            try GKPathValidation.validateTreeEntryName("a\0b")
        }
    }

    @Test func rejectsDotGitSpellings() {
        for name in [".git", ".GIT", ".Git", ".git.", ".git ", "git~1", "GIT~1"] {
            #expect(throws: GKError.self) {
                try GKPathValidation.validateTreeEntryName(name)
            }
        }
    }

    // MARK: Containment

    @Test func containmentAcceptsInsidePaths() throws {
        let base = URL(fileURLWithPath: "/tmp/repo")
        try GKPathValidation.ensureContained(base.appendingPathComponent("a/b.txt"), within: base)
        try GKPathValidation.ensureContained(base, within: base)
    }

    @Test func containmentRejectsEscapingPaths() {
        let base = URL(fileURLWithPath: "/tmp/repo")
        #expect(throws: GKError.self) {
            try GKPathValidation.ensureContained(
                base.appendingPathComponent("../evil.txt"), within: base)
        }
        // A sibling directory sharing a prefix must not be considered inside.
        #expect(throws: GKError.self) {
            try GKPathValidation.ensureContained(
                URL(fileURLWithPath: "/tmp/repo-evil/x"), within: base)
        }
    }

    // MARK: Reference names

    @Test func acceptsValidReferenceNames() throws {
        try GKPathValidation.validateReferenceName("refs/heads/main")
        try GKPathValidation.validateReferenceName("refs/remotes/origin/feature/login")
        try GKPathValidation.validateReferenceName("refs/tags/v1.0.0")
        try GKPathValidation.validateReferenceName("refs/stash")
    }

    @Test func rejectsTraversalReferenceNames() {
        for name in [
            "refs/heads/../../evil",
            "../escape",
            "refs/heads/main.lock",
            "refs/heads/.hidden",
            "refs//heads/main",
            "/refs/heads/main",
            "refs/heads/main/",
            "refs/heads/foo^bar",
            "refs/heads/foo bar",
            "refs/heads/foo~1",
            "refs/heads/foo:bar",
            "",
            "@",
        ] {
            #expect(throws: GKError.self) {
                try GKPathValidation.validateReferenceName(name)
            }
        }
    }
}

// MARK: - Checkout Security Tests

@Suite("GKCheckoutSecurity")
struct GKCheckoutSecurityTests {
    /// A malicious tree whose entry name is `..` must be refused on checkout
    /// rather than writing a blob outside the working directory.
    @Test func checkoutRejectsTraversalTreeEntry() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-traversal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)

        // A blob whose content we would attempt to write outside the work tree.
        let blob = GKRawObject(type: .blob, data: Data("pwned".utf8))
        try repo.objectDB.write(blob)

        // Hand-craft a tree entry named ".." pointing at the blob.
        let evilTree = GKTree(entries: [
            GKTreeEntry(mode: .regular, name: "..", oid: blob.oid)
        ])
        let rawTree = GKRawObject(type: .tree, data: evilTree.serialize())
        try repo.objectDB.write(rawTree)

        let author = GKSignature(name: "A", email: "a@b.c")
        let commit = GKCommit(
            treeOID: rawTree.oid,
            parentOIDs: [],
            author: author,
            committer: author,
            message: "evil"
        )
        let rawCommit = GKRawObject(type: .commit, data: commit.serialize())
        try repo.objectDB.write(rawCommit)

        #expect(throws: GKError.self) {
            try repo.GKCheckout(commit: rawCommit.oid)
        }

        // Ensure nothing was written to the parent directory.
        let escaped = tempDir.deletingLastPathComponent().appendingPathComponent("..")
        _ = escaped // path traversal target would have been the parent dir
        #expect(!FileManager.default.fileExists(
            atPath: tempDir.deletingLastPathComponent().path + "/pwned"))
    }

    /// A tree entry named `.git` must be refused so the repository metadata
    /// cannot be overwritten during checkout.
    @Test func checkoutRejectsDotGitTreeEntry() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-dotgit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)

        let blob = GKRawObject(type: .blob, data: Data("hook".utf8))
        try repo.objectDB.write(blob)
        let evilTree = GKTree(entries: [
            GKTreeEntry(mode: .regular, name: ".git", oid: blob.oid)
        ])
        let rawTree = GKRawObject(type: .tree, data: evilTree.serialize())
        try repo.objectDB.write(rawTree)

        let author = GKSignature(name: "A", email: "a@b.c")
        let commit = GKCommit(
            treeOID: rawTree.oid, parentOIDs: [], author: author,
            committer: author, message: "evil")
        let rawCommit = GKRawObject(type: .commit, data: commit.serialize())
        try repo.objectDB.write(rawCommit)

        #expect(throws: GKError.self) {
            try repo.GKCheckout(commit: rawCommit.oid)
        }
    }

    /// Writing a reference whose name escapes `.git` must be refused.
    @Test func referenceWriteRejectsTraversalName() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-refname-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = try GKRepository.GKInitRepository(at: tempDir)
        let evilRef = GKReference(
            name: "../../../../tmp/gitkit-escaped-\(UUID().uuidString)",
            target: .direct(.zero))

        #expect(throws: GKError.self) {
            try repo.refStorage.write(evilRef)
        }
    }
}

// MARK: - Configuration Injection Tests

@Suite("GKConfigurationSecurity")
struct GKConfigurationSecurityTests {
    private func makeConfig() throws -> (GKConfiguration, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitkit-config-\(UUID().uuidString)")
        try Data().write(to: url)
        let config = try GKConfiguration(from: url)
        return (config, url)
    }

    /// A value containing a newline + forged section must not introduce new
    /// keys when the file is re-parsed.
    @Test func newlineInValueDoesNotInjectSections() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        let malicious = "https://example.com/repo.git\n[core]\n\tsshCommand = touch /tmp/pwned"
        try config.set("remote.origin.url", value: malicious)

        // Re-read from disk and confirm no injected section/key appeared.
        let reread = try GKConfiguration(from: url)
        #expect(reread.getString("core.sshCommand") == nil)
        // The original value round-trips intact.
        #expect(reread.getString("remote.origin.url") == malicious)
    }

    /// The serialized form must keep a newline-bearing value on a single
    /// physical line (quoted + escaped).
    @Test func serializedValueIsSingleLine() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        try config.set("core.pager", value: "less\ninjected = 1")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("\\n"))
        #expect(!contents.contains("injected = 1\n") || contents.contains("\\ninjected"))
        // Exactly one section header should be present.
        let headerCount = contents.components(separatedBy: "[core]").count - 1
        #expect(headerCount == 1)
    }

    /// A quote in a subsection name (e.g. a remote name) cannot break out of
    /// the quoted header; it is escaped and round-trips intact.
    @Test func quoteInSubsectionDoesNotInjectHeader() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        // Remote name attempts to close the quoted subsection and open [core].
        try config.set("remote.x\"] [core.url", value: "ok")

        let contents = try String(contentsOf: url, encoding: .utf8)
        // The quote must be escaped in the header, not left raw.
        #expect(contents.contains("\\\""))
        // No second section header may have been forged.
        #expect(!contents.contains("[core]"))

        let reread = try GKConfiguration(from: url)
        #expect(reread.getString("core.url") == nil)
    }

    /// Newlines in a subsection are rejected outright.
    @Test func newlineInSubsectionThrows() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: GKError.self) {
            try config.set("remote.evil\nname.url", value: "x")
        }
    }

    /// Ordinary values round-trip without spurious quoting.
    @Test func ordinaryValuesRoundTrip() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        try config.set("user.name", value: "Jane Dev")
        try config.set("user.email", value: "jane@example.com")
        let reread = try GKConfiguration(from: url)
        #expect(reread.getString("user.name") == "Jane Dev")
        #expect(reread.getString("user.email") == "jane@example.com")
    }

    /// Values with quotes, tabs, and comment characters survive a round-trip.
    @Test func specialCharactersRoundTrip() throws {
        var (config, url) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: url) }

        let value = "a\tb \"quoted\" # not-a-comment \\ end"
        try config.set("core.special", value: value)
        let reread = try GKConfiguration(from: url)
        #expect(reread.getString("core.special") == value)
    }
}

// MARK: - Zlib Decompression-Bomb Tests

@Suite("GKZlibSecurity")
struct GKZlibSecurityTests {
    /// Decompression must stop and throw once the output would exceed the
    /// supplied maximum, rather than expanding without bound.
    @Test func decompressRejectsOutputBeyondCap() throws {
        // 100 KiB of zeros compresses to a tiny stream but expands hugely —
        // a classic decompression bomb in miniature.
        let original = Data(repeating: 0, count: 100 * 1024)
        let compressed = try GKZlib.compress(original)

        #expect(throws: GKError.self) {
            _ = try GKZlib.decompress(compressed, maxOutputSize: 1024)
        }
    }

    /// Decompression within the cap succeeds and round-trips exactly.
    @Test func decompressWithinCapSucceeds() throws {
        let original = Data("the quick brown fox".utf8)
        let compressed = try GKZlib.compress(original)

        let result = try GKZlib.decompress(compressed, maxOutputSize: 1024)
        #expect(result == original)
    }

    /// The cap boundary is inclusive: output exactly equal to the cap is allowed.
    @Test func decompressAtExactCapSucceeds() throws {
        let original = Data(repeating: 0x41, count: 256)
        let compressed = try GKZlib.compress(original)

        let result = try GKZlib.decompress(compressed, maxOutputSize: 256)
        #expect(result == original)
    }
}

// MARK: - Packfile Allocation-Bomb Tests

@Suite("GKPackfileSecurity")
struct GKPackfileSecurityTests {
    /// A pack header that claims a huge object count but carries no body must
    /// fail gracefully (throwing) rather than attempting a multi-gigabyte
    /// `reserveCapacity` allocation.
    @Test func forgedObjectCountDoesNotOverAllocate() throws {
        var bytes: [UInt8] = []
        bytes += [0x50, 0x41, 0x43, 0x4B]       // "PACK"
        bytes += [0x00, 0x00, 0x00, 0x02]       // version 2
        bytes += [0xFF, 0xFF, 0xFF, 0xFF]       // object count = 4,294,967,295
        // No entry body.
        let trailer = GKSHA1.hash(Data(bytes))  // valid trailing checksum
        bytes += trailer

        #expect(throws: GKError.self) {
            _ = try GKPackfileReader.parse(Data(bytes))
        }
    }

    /// The clamp must not break a legitimate, well-formed empty pack
    /// (object count of zero parses to no objects).
    @Test func emptyPackParsesToNoObjects() throws {
        var bytes: [UInt8] = []
        bytes += [0x50, 0x41, 0x43, 0x4B]       // "PACK"
        bytes += [0x00, 0x00, 0x00, 0x02]       // version 2
        bytes += [0x00, 0x00, 0x00, 0x00]       // object count = 0
        let trailer = GKSHA1.hash(Data(bytes))
        bytes += trailer

        let objects = try GKPackfileReader.parse(Data(bytes))
        #expect(objects.isEmpty)
    }
}
