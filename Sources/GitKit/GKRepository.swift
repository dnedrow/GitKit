import Foundation

// MARK: - Repository Protocol

/// Protocol defining the interface of a Git repository.
public protocol GKRepositoryProtocol {
    /// The path to the repository's working directory.
    var workDir: URL { get }

    /// The path to the .git directory.
    var gitDir: URL { get }

    /// Whether this is a bare repository.
    var isBare: Bool { get }

    // Object access
    func lookupBlob(oid: GKObjectID) throws -> GKBlob
    func lookupTree(oid: GKObjectID) throws -> GKTree
    func lookupCommit(oid: GKObjectID) throws -> GKCommit
    func lookupTag(oid: GKObjectID) throws -> GKTag

    // References
    func head() throws -> GKHead
    func branches() throws -> [GKBranch]
    func tags() throws -> [GKReference]
    func references() throws -> [GKReference]

    // High-level operations
    func status() throws -> GKStatus
    func log(from oid: GKObjectID?, maxCount: Int) throws -> [GKCommit]
}

// MARK: - Repository

/// The main Git repository class providing high-level operations.
public final class GKRepository: GKRepositoryProtocol {
    public let workDir: URL
    public let gitDir: URL
    public let isBare: Bool

    let objectDB: GKLooseObjectDatabase
    let refStorage: GKFileReferenceStorage
    var configuration: GKConfiguration

    // MARK: - Opening / Creating

    /// Opens an existing repository.
    /// - Parameter path: Path to the repository (working directory or .git directory).
    /// - Throws: `GKError.repositoryNotFound` if no valid repository exists at the path.
    public init(at path: URL) throws {
        let fm = FileManager.default

        // Check if path is a .git dir or contains one
        var gitDirCandidate: URL
        var workDirCandidate: URL
        var bare = false

        if fm.fileExists(atPath: path.appendingPathComponent("HEAD").path) &&
           fm.fileExists(atPath: path.appendingPathComponent("objects").path) {
            // This is a bare repo or .git dir itself
            if fm.fileExists(atPath: path.appendingPathComponent("config").path) {
                gitDirCandidate = path
                workDirCandidate = path.deletingLastPathComponent()
                // Check if bare
                let configURL = path.appendingPathComponent("config")
                if let config = try? GKConfiguration(from: configURL),
                   config.getBool("core.bare") == true {
                    bare = true
                    workDirCandidate = path
                }
            } else {
                throw GKError.repositoryNotFound(path: path.path)
            }
        } else if fm.fileExists(atPath: path.appendingPathComponent(".git").path) {
            gitDirCandidate = path.appendingPathComponent(".git")
            workDirCandidate = path
        } else {
            throw GKError.repositoryNotFound(path: path.path)
        }

        self.gitDir = gitDirCandidate
        self.workDir = workDirCandidate
        self.isBare = bare
        self.objectDB = GKLooseObjectDatabase(objectsURL: gitDirCandidate.appendingPathComponent("objects"))
        self.refStorage = GKFileReferenceStorage(gitDir: gitDirCandidate)
        self.configuration = try GKConfiguration(from: gitDirCandidate.appendingPathComponent("config"))
    }

    /// Creates a new repository.
    /// - Parameters:
    ///   - path: Path where the repository should be created.
    ///   - bare: Whether to create a bare repository.
    /// - Returns: The newly created repository.
    @discardableResult
    public static func GKInitRepository(at path: URL, bare: Bool = false) throws -> GKRepository {
        let fm = FileManager.default

        let gitDir = bare ? path : path.appendingPathComponent(".git")

        guard !fm.fileExists(atPath: gitDir.path) else {
            throw GKError.repositoryAlreadyExists(path: path.path)
        }

        // Create directory structure
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("objects/info"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("objects/pack"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/tags"), withIntermediateDirectories: true)

        // Write HEAD
        let headContent = "ref: refs/heads/main\n"
        try headContent.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Write config
        var config = "[core]\n"
        config += "\trepositoryformatversion = 0\n"
        config += "\tfilemode = true\n"
        config += "\tbare = \(bare)\n"
        if !bare {
            config += "\tlogallrefupdates = true\n"
        }
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // Write description
        let description = "Unnamed repository; edit this file 'description' to name the repository.\n"
        try description.write(to: gitDir.appendingPathComponent("description"), atomically: true, encoding: .utf8)

        return try GKRepository(at: path)
    }

    // MARK: - Object Lookup

    public func lookupBlob(oid: GKObjectID) throws -> GKBlob {
        let raw = try objectDB.read(oid: oid)
        guard raw.type == .blob else {
            throw GKError.invalidObjectType("Expected blob, got \(raw.type.rawValue)")
        }
        return GKBlob(oid: oid, data: raw.data)
    }

    public func lookupTree(oid: GKObjectID) throws -> GKTree {
        let raw = try objectDB.read(oid: oid)
        guard raw.type == .tree else {
            throw GKError.invalidObjectType("Expected tree, got \(raw.type.rawValue)")
        }
        return try GKTree(oid: oid, data: raw.data)
    }

    public func lookupCommit(oid: GKObjectID) throws -> GKCommit {
        let raw = try objectDB.read(oid: oid)
        guard raw.type == .commit else {
            throw GKError.invalidObjectType("Expected commit, got \(raw.type.rawValue)")
        }
        return try GKCommit(oid: oid, data: raw.data)
    }

    public func lookupTag(oid: GKObjectID) throws -> GKTag {
        let raw = try objectDB.read(oid: oid)
        guard raw.type == .tag else {
            throw GKError.invalidObjectType("Expected tag, got \(raw.type.rawValue)")
        }
        return try GKTag(oid: oid, data: raw.data)
    }

    // MARK: - References

    public func head() throws -> GKHead {
        try refStorage.readHead()
    }

    /// Resolves HEAD to a commit OID.
    public func GKHeadCommitOID() throws -> GKObjectID {
        let head = try self.head()
        switch head {
        case .branch(let name):
            let target = try refStorage.resolve("refs/heads/\(name)")
            guard let oid = target.oid else {
                throw GKError.invalidHead("Branch \(name) is symbolic")
            }
            return oid
        case .detached(let oid):
            return oid
        }
    }

    public func branches() throws -> [GKBranch] {
        let refs = try refStorage.list(matching: "refs/heads/*")
        return refs.compactMap { ref -> GKBranch? in
            guard let oid = ref.target.oid else { return nil }
            let name = ref.shortName
            let upstream = configuration.branchUpstream(name)
            return GKBranch(
                name: name,
                commitOID: oid,
                isRemote: false,
                upstream: upstream.map { "\($0.remote)/\($0.merge)" }
            )
        }
    }

    public func tags() throws -> [GKReference] {
        try refStorage.list(matching: "refs/tags/*")
    }

    public func references() throws -> [GKReference] {
        try refStorage.list(matching: nil)
    }

    // MARK: - Ignore

    /// Determines whether a working-tree path should be ignored.    ///
    /// Aggregates ignore rules from all of Git's standard sources, in precedence order
    /// (later overrides earlier):
    /// 1. The global excludes file referenced by `core.excludesFile`.
    /// 2. The repository's `.git/info/exclude`.
    /// 3. Per-directory `.gitignore` files, shallow to deep.
    ///
    /// Missing or unreadable sources are treated as empty and never cause an error.
    /// - Parameter relativePath: A path relative to the working directory.
    /// - Returns: `true` if the path matches an active ignore rule.
    public func isIgnored(_ relativePath: String) -> Bool {
        ignoreMatcher().isIgnored(path: relativePath)
    }

    /// Builds the aggregated ignore matcher from all standard sources.
    func ignoreMatcher() -> GKIgnore {        var sources = [URL]()

        // 1. Global excludes file (core.excludesFile)
        if let global = configuration.coreExcludesFile() {
            sources.append(global)
        }

        // 2. Repository-level .git/info/exclude
        sources.append(gitDir.appendingPathComponent("info/exclude"))

        // 3. Per-directory .gitignore files (root first, then nested shallow to deep)
        sources.append(contentsOf: gitignoreFiles())

        return GKIgnore(mergingFiles: sources)
    }

    /// Discovers `.gitignore` files under the working directory, ordered shallow to deep.
    private func gitignoreFiles() -> [URL] {
        guard !isBare else { return [] }
        let fm = FileManager.default
        var results = [URL]()

        // Root .gitignore first.
        let root = workDir.appendingPathComponent(".gitignore")
        if fm.fileExists(atPath: root.path) {
            results.append(root)
        }

        // Nested .gitignore files, excluding the .git directory.
        if let enumerator = fm.enumerator(at: workDir, includingPropertiesForKeys: nil) {
            var nested = [(depth: Int, url: URL)]()
            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath = workTreeRelativePath(fileURL) ?? fileURL.lastPathComponent
                if relativePath.hasPrefix(".git/") || relativePath == ".git" { continue }
                guard fileURL.lastPathComponent == ".gitignore" else { continue }
                if fileURL.path == root.path { continue }
                let depth = relativePath.split(separator: "/").count
                nested.append((depth, fileURL))
            }
            // Shallow to deep so deeper files take precedence (last-match-wins).
            nested.sort { $0.depth < $1.depth }
            results.append(contentsOf: nested.map(\.url))
        }

        return results
    }

    /// Computes a path relative to the working directory, resolving symlinks so that
    /// enumerated file URLs (which may carry a `/private` prefix on macOS) match the
    /// working-directory root. Returns `nil` if the URL is not under the working tree.
    func workTreeRelativePath(_ url: URL) -> String? {
        let base = workDir.resolvingSymlinksInPath().path
        let full = url.resolvingSymlinksInPath().path
        if full == base { return "" }
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(basePrefix) else { return nil }
        return String(full.dropFirst(basePrefix.count))
    }

    // MARK: - Status

    public func status() throws -> GKStatus {
        let index = try readIndex()
        var staged = [GKStatusEntry]()
        var unstaged = [GKStatusEntry]()
        var untracked = [String]()

        // Compare index vs HEAD tree
        let headTree = try headTreeEntries()
        var headMap = [String: GKObjectID]()
        for (path, oid) in headTree { headMap[path] = oid }

        for entry in index.entries {
            if let headOID = headMap[entry.path] {
                if headOID != entry.oid {
                    staged.append(GKStatusEntry(path: entry.path, status: .modified))
                }
            } else {
                staged.append(GKStatusEntry(path: entry.path, status: .added))
            }
        }

        let indexPaths = Set(index.entries.map(\.path))
        for (path, _) in headTree where !indexPaths.contains(path) {
            staged.append(GKStatusEntry(path: path, status: .deleted))
        }

        // Compare workdir vs index (simplified - checks for untracked)
        if !isBare {
            let fm = FileManager.default
            let ignore = ignoreMatcher()
            if let enumerator = fm.enumerator(at: workDir, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let relativePath = workTreeRelativePath(fileURL) ?? fileURL.lastPathComponent
                    if relativePath.hasPrefix(".git") { continue }

                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                    if isDir.boolValue { continue }

                    if !indexPaths.contains(relativePath) {
                        // Exclude ignored, untracked files from the untracked set.
                        if ignore.isIgnored(path: relativePath) { continue }
                        untracked.append(relativePath)
                    } else {
                        // Check if modified
                        if let data = fm.contents(atPath: fileURL.path) {
                            let currentOID = GKRawObject.computeOID(type: .blob, data: data)
                            if let indexEntry = index.entries.first(where: { $0.path == relativePath }),
                               indexEntry.oid != currentOID {
                                unstaged.append(GKStatusEntry(path: relativePath, status: .modified))
                            }
                        }
                    }
                }
            }
        }

        return GKStatus(staged: staged, unstaged: unstaged, untracked: untracked)
    }

    // MARK: - Log

    public func log(from startOID: GKObjectID? = nil, maxCount: Int = 50) throws -> [GKCommit] {
        let startOID = try startOID ?? GKHeadCommitOID()
        var commits = [GKCommit]()
        var queue = [startOID]
        var visited = Set<GKObjectID>()

        while !queue.isEmpty && commits.count < maxCount {
            let oid = queue.removeFirst()
            guard !visited.contains(oid) else { continue }
            visited.insert(oid)

            let commit = try lookupCommit(oid: oid)
            commits.append(commit)

            for parent in commit.parentOIDs {
                if !visited.contains(parent) {
                    queue.append(parent)
                }
            }
        }

        // Sort by commit time (most recent first)
        return commits.sorted { $0.committer.time > $1.committer.time }
    }

    // MARK: - Index

    /// Reads the repository's index file.
    public func readIndex() throws -> GKIndex {
        let indexPath = gitDir.appendingPathComponent("index")
        if FileManager.default.fileExists(atPath: indexPath.path) {
            return try GKIndex(from: indexPath)
        }
        return GKIndex()
    }

    /// Writes the index to disk.
    public func writeIndex(_ index: GKIndex) throws {
        let indexPath = gitDir.appendingPathComponent("index")
        try index.write(to: indexPath)
    }

    // MARK: - Private Helpers

    private func headTreeEntries() throws -> [(String, GKObjectID)] {
        do {
            let headOID = try GKHeadCommitOID()
            let commit = try lookupCommit(oid: headOID)
            let tree = try lookupTree(oid: commit.treeOID)
            return flattenTree(tree, prefix: "")
        } catch GKError.referenceNotFound {
            // No commits yet
            return []
        }
    }

    private func flattenTree(_ tree: GKTree, prefix: String) -> [(String, GKObjectID)] {
        var result = [(String, GKObjectID)]()
        for entry in tree.entries {
            let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
            if entry.isTree {
                if let subtree = try? lookupTree(oid: entry.oid) {
                    result.append(contentsOf: flattenTree(subtree, prefix: path))
                }
            } else {
                result.append((path, entry.oid))
            }
        }
        return result
    }
}
