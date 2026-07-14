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
    func ignoreMatcher() -> GKIgnore {
        var sources = [(baseDir: String, url: URL)]()

        // 1. Global excludes file (core.excludesFile) — scoped to repo root.
        if let global = configuration.coreExcludesFile() {
            sources.append((baseDir: "", url: global))
        }

        // 2. Repository-level .git/info/exclude — scoped to repo root.
        sources.append((baseDir: "", url: gitDir.appendingPathComponent("info/exclude")))

        // 3. Root .gitignore — scoped to repo root, first of the per-directory files.
        if !isBare {
            let root = workDir.appendingPathComponent(".gitignore")
            if FileManager.default.fileExists(atPath: root.path) {
                sources.append((baseDir: "", url: root))
            }
        }

        // A preliminary matcher built from the root-scoped sources is enough to prune
        // ignored subtrees while discovering nested `.gitignore` files: a `.gitignore`
        // living inside an already-ignored directory cannot affect tracked/untracked
        // results, so it is skipped (Git-correct).
        let pruneMatcher = GKIgnore(sources: sources)

        // 4. Nested per-directory .gitignore files (shallow to deep), each scoped to
        //    its own directory, discovered with ignored-directory pruning applied.
        sources.append(contentsOf: nestedGitignoreFiles(pruneMatcher: pruneMatcher))

        return GKIgnore(sources: sources)
    }

    /// Discovers nested `.gitignore` files under the working directory (excluding the
    /// root `.gitignore`), ordered shallow to deep, each paired with the repo-root-
    /// relative directory it applies under. Ignored directory subtrees are pruned via
    /// `skipDescendants()` so discovery never descends into an ignored tree.
    private func nestedGitignoreFiles(pruneMatcher: GKIgnore) -> [(baseDir: String, url: URL)] {
        guard !isBare else { return [] }
        let fm = FileManager.default
        let root = workDir.appendingPathComponent(".gitignore")
        let resolvedBase = workDir.resolvingSymlinksInPath().path

        guard let enumerator = fm.enumerator(at: workDir,
                                             includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var nested = [(depth: Int, baseDir: String, url: URL)]()
        while let fileURL = enumerator.nextObject() as? URL {
            let relativePath = workTreeRelativePath(fileURL, resolvedBase: resolvedBase)
                ?? fileURL.lastPathComponent
            // Never descend into the .git directory.
            if relativePath == ".git" || relativePath.hasPrefix(".git/") {
                enumerator.skipDescendants()
                continue
            }

            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                // Prune ignored subtrees — a nested .gitignore inside them is irrelevant.
                if pruneMatcher.isDirectoryIgnored(path: relativePath) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard fileURL.lastPathComponent == ".gitignore" else { continue }
            if fileURL.path == root.path { continue }
            // The base directory is the .gitignore's parent, relative to the root.
            let baseDir = relativePath.hasSuffix("/.gitignore")
                ? String(relativePath.dropLast("/.gitignore".count))
                : ""
            let depth = relativePath.split(separator: "/").count
            nested.append((depth, baseDir, fileURL))
        }
        // Shallow to deep so deeper files take precedence (last-match-wins).
        nested.sort { $0.depth < $1.depth }
        return nested.map { (baseDir: $0.baseDir, url: $0.url) }
    }

    /// Computes a path relative to the working directory, resolving symlinks so that
    /// enumerated file URLs (which may carry a `/private` prefix on macOS) match the
    /// working-directory root. Returns `nil` if the URL is not under the working tree.
    func workTreeRelativePath(_ url: URL) -> String? {
        workTreeRelativePath(url, resolvedBase: workDir.resolvingSymlinksInPath().path)
    }

    /// Variant of `workTreeRelativePath(_:)` that accepts the already-resolved working
    /// directory root, so a walk resolves the base symlink once instead of per file.
    /// Preserves the macOS `/private` prefix handling by resolving `url` the same way.
    func workTreeRelativePath(_ url: URL, resolvedBase base: String) -> String? {
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
            // Resolve the working-directory root symlink once for the whole walk
            // instead of once per file.
            let resolvedBase = workDir.resolvingSymlinksInPath().path

            // Index entries keyed by path for O(1) lookup, plus the index file's
            // own mtime for racy-clean detection.
            var entryByPath = [String: GKIndexEntry](minimumCapacity: index.entries.count)
            for entry in index.entries { entryByPath[entry.path] = entry }
            let indexMtimeSeconds = GKFileStat.read(at: gitDir.appendingPathComponent("index"))?.mtimeSeconds ?? 0

            // Every ancestor directory that contains a tracked (index) file. An ignored
            // directory is only safe to prune when it holds no tracked files, otherwise
            // pruning would hide a tracked file's working-tree modification.
            var trackedDirs = Set<String>()
            for entry in index.entries {
                var components = entry.path.split(separator: "/").map(String.init)
                guard components.count > 1 else { continue }
                components.removeLast()
                var prefix = ""
                for component in components {
                    prefix = prefix.isEmpty ? component : prefix + "/" + component
                    trackedDirs.insert(prefix)
                }
            }

            if let enumerator = fm.enumerator(at: workDir,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: []) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let relativePath = workTreeRelativePath(fileURL, resolvedBase: resolvedBase)
                        ?? fileURL.lastPathComponent
                    // Never descend into or report the .git directory.
                    if relativePath == ".git" || relativePath.hasPrefix(".git/") {
                        enumerator.skipDescendants()
                        continue
                    }

                    // Use the enumerator's prefetched resource value for the file type
                    // instead of a separate fileExists(isDirectory:) probe.
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir {
                        // Prune an ignored directory's entire subtree, mirroring the
                        // .git pruning above — files beneath it are already excluded.
                        // Skip pruning when the directory holds tracked files so their
                        // modifications are still reported (tracked files aren't ignored).
                        if ignore.isDirectoryIgnored(path: relativePath),
                           !trackedDirs.contains(relativePath) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    guard let indexEntry = entryByPath[relativePath] else {
                        // Exclude ignored, untracked files from the untracked set.
                        if ignore.isIgnored(path: relativePath) { continue }
                        untracked.append(relativePath)
                        continue
                    }

                    // Fast path: if the working file's stat matches the cached
                    // stat and the entry is not racily clean, skip hashing.
                    if !indexEntry.stat.isEmpty,
                       !indexEntry.stat.isRacyClean(indexMtimeSeconds: indexMtimeSeconds),
                       let currentStat = GKFileStat.read(at: fileURL),
                       indexEntry.stat.matchesWorkingFile(currentStat) {
                        continue
                    }

                    // Slow path: stat differs, is empty, or is racily clean —
                    // verify by content and report modified only if the OID differs.
                    if let data = fm.contents(atPath: fileURL.path) {
                        let currentOID = GKRawObject.computeOID(type: .blob, data: data)
                        if indexEntry.oid != currentOID {
                            unstaged.append(GKStatusEntry(path: relativePath, status: .modified))
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
        // Smudge racily-clean entries relative to the index's write time so a
        // file modified within the same timestamp tick is verified by content
        // on the next status rather than trusted by stat.
        var index = index
        index.smudgeRacilyCleanEntries(indexMtimeSeconds: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
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
