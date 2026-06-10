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
