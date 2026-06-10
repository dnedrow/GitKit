import Foundation

// MARK: - High-Level Git Operations

extension GKRepository {

    // MARK: - Add (Stage)

    /// Stages a file for the next commit.
    /// - Parameter path: Relative path to the file in the working directory.
    public func GKAdd(path: String) throws {
        let fileURL = workDir.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GKError.ioError("File not found: \(path)")
        }

        let data = try Data(contentsOf: fileURL)
        let raw = GKRawObject(type: .blob, data: data)
        try objectDB.write(raw)

        var index = try readIndex()
        try index.add(path: path, oid: raw.oid, mode: .regular)
        try writeIndex(index)
    }

    /// Stages multiple files.
    /// - Parameter paths: Relative paths to stage.
    public func GKAdd(paths: [String]) throws {
        for path in paths {
            try GKAdd(path: path)
        }
    }

    // MARK: - Remove (Unstage)

    /// Removes a file from the index.
    /// - Parameter path: Relative path to remove from staging.
    public func GKRemove(path: String) throws {
        var index = try readIndex()
        try index.remove(path: path)
        try writeIndex(index)
    }

    // MARK: - Commit

    /// Creates a new commit from the current index.
    /// - Parameters:
    ///   - message: The commit message.
    ///   - author: The author signature.
    ///   - committer: The committer signature (defaults to author).
    /// - Returns: The OID of the new commit.
    @discardableResult
    public func GKCreateCommit(
        message: String,
        author: GKSignature,
        committer: GKSignature? = nil
    ) throws -> GKObjectID {
        let index = try readIndex()
        let treeOID = try index.writeTree(objectDB: objectDB)

        // Get parent commits
        var parents = [GKObjectID]()
        do {
            let headOID = try GKHeadCommitOID()
            parents.append(headOID)
        } catch {
            // First commit, no parents
        }

        let commit = GKCommit(
            treeOID: treeOID,
            parentOIDs: parents,
            author: author,
            committer: committer ?? author,
            message: message
        )

        let raw = GKRawObject(type: .commit, data: commit.serialize())
        try objectDB.write(raw)

        // Update HEAD
        let head = try self.head()
        switch head {
        case .branch(let name):
            let ref = GKReference(name: "refs/heads/\(name)", target: .direct(raw.oid))
            try refStorage.write(ref)
        case .detached:
            try refStorage.writeHead(.detached(raw.oid))
        }

        return raw.oid
    }

    // MARK: - Branch

    /// Creates a new branch.
    /// - Parameters:
    ///   - name: The branch name.
    ///   - target: The commit OID to point to (defaults to HEAD).
    public func GKCreateBranch(name: String, target: GKObjectID? = nil) throws {
        let refName = "refs/heads/\(name)"
        guard !refStorage.exists(refName) else {
            throw GKError.branchAlreadyExists(name)
        }

        let targetOID = try target ?? GKHeadCommitOID()
        let ref = GKReference(name: refName, target: .direct(targetOID))
        try refStorage.write(ref)
    }

    /// Deletes a branch.
    /// - Parameter name: The branch name to delete.
    public func GKDeleteBranch(name: String) throws {
        let refName = "refs/heads/\(name)"
        guard refStorage.exists(refName) else {
            throw GKError.branchNotFound(name)
        }

        // Don't delete the current branch
        let currentHead = try head()
        if case .branch(let current) = currentHead, current == name {
            throw GKError.invalidReference("Cannot delete the current branch: \(name)")
        }

        try refStorage.delete(name: refName)
    }

    /// Renames a branch.
    /// - Parameters:
    ///   - oldName: Current branch name.
    ///   - newName: New branch name.
    public func GKRenameBranch(from oldName: String, to newName: String) throws {
        let oldRef = "refs/heads/\(oldName)"
        let newRef = "refs/heads/\(newName)"

        guard refStorage.exists(oldRef) else {
            throw GKError.branchNotFound(oldName)
        }
        guard !refStorage.exists(newRef) else {
            throw GKError.branchAlreadyExists(newName)
        }

        let target = try refStorage.resolve(oldRef)
        try refStorage.write(GKReference(name: newRef, target: target))
        try refStorage.delete(name: oldRef)

        // Update HEAD if renaming current branch
        let currentHead = try head()
        if case .branch(let current) = currentHead, current == oldName {
            try refStorage.writeHead(.branch(newName))
        }
    }

    // MARK: - Checkout

    /// Checks out a branch.
    /// - Parameter name: Branch name to check out.
    public func GKCheckout(branch name: String) throws {
        let refName = "refs/heads/\(name)"
        let target = try refStorage.resolve(refName)
        guard let oid = target.oid else {
            throw GKError.invalidReference("Branch \(name) has no direct target")
        }

        try checkoutTree(commitOID: oid)
        try refStorage.writeHead(.branch(name))
    }

    /// Checks out a specific commit (detached HEAD).
    /// - Parameter oid: The commit OID to check out.
    public func GKCheckout(commit oid: GKObjectID) throws {
        try checkoutTree(commitOID: oid)
        try refStorage.writeHead(.detached(oid))
    }

    private func checkoutTree(commitOID: GKObjectID) throws {
        guard !isBare else {
            throw GKError.ioError("Cannot checkout in a bare repository")
        }

        let commit = try lookupCommit(oid: commitOID)
        let tree = try lookupTree(oid: commit.treeOID)

        // Write tree to working directory
        try writeTreeToWorkDir(tree, path: workDir)

        // Update index
        var index = GKIndex()
        try populateIndex(&index, from: tree, prefix: "")
        try writeIndex(index)
    }

    private func writeTreeToWorkDir(_ tree: GKTree, path: URL) throws {
        let fm = FileManager.default

        for entry in tree.entries {
            let entryPath = path.appendingPathComponent(entry.name)

            if entry.isTree {
                let subtree = try lookupTree(oid: entry.oid)
                if !fm.fileExists(atPath: entryPath.path) {
                    try fm.createDirectory(at: entryPath, withIntermediateDirectories: true)
                }
                try writeTreeToWorkDir(subtree, path: entryPath)
            } else {
                let blob = try lookupBlob(oid: entry.oid)
                try blob.content.write(to: entryPath)

                // Set file permissions
                if entry.mode == .executable {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entryPath.path)
                }
            }
        }
    }

    private func populateIndex(_ index: inout GKIndex, from tree: GKTree, prefix: String) throws {
        for entry in tree.entries {
            let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"

            if entry.isTree {
                let subtree = try lookupTree(oid: entry.oid)
                try populateIndex(&index, from: subtree, prefix: path)
            } else {
                try index.add(path: path, oid: entry.oid, mode: entry.mode)
            }
        }
    }

    // MARK: - Tag

    /// Creates a lightweight tag.
    /// - Parameters:
    ///   - name: Tag name.
    ///   - target: The OID to tag (defaults to HEAD).
    public func GKCreateTag(name: String, target: GKObjectID? = nil) throws {
        let targetOID = try target ?? GKHeadCommitOID()
        let ref = GKReference(name: "refs/tags/\(name)", target: .direct(targetOID))
        try refStorage.write(ref)
    }

    /// Creates an annotated tag.
    /// - Parameters:
    ///   - name: Tag name.
    ///   - target: The OID to tag (defaults to HEAD).
    ///   - tagger: The tagger's signature.
    ///   - message: The tag message.
    @discardableResult
    public func GKCreateAnnotatedTag(
        name: String,
        target: GKObjectID? = nil,
        tagger: GKSignature,
        message: String
    ) throws -> GKObjectID {
        let targetOID = try target ?? GKHeadCommitOID()

        let tag = GKTag(
            targetOID: targetOID,
            targetType: .commit,
            tagName: name,
            tagger: tagger,
            message: message
        )

        let raw = GKRawObject(type: .tag, data: tag.serialize())
        try objectDB.write(raw)

        let ref = GKReference(name: "refs/tags/\(name)", target: .direct(raw.oid))
        try refStorage.write(ref)

        return raw.oid
    }

    /// Deletes a tag.
    /// - Parameter name: The tag name to delete.
    public func GKDeleteTag(name: String) throws {
        try refStorage.delete(name: "refs/tags/\(name)")
    }

    // MARK: - Diff

    /// Computes the diff between two commits.
    /// - Parameters:
    ///   - from: The base commit OID.
    ///   - to: The target commit OID.
    /// - Returns: The diff between the two commits.
    public func GKComputeDiff(from: GKObjectID, to: GKObjectID) throws -> GKDiff {
        let fromCommit = try lookupCommit(oid: from)
        let toCommit = try lookupCommit(oid: to)

        let fromTree = try lookupTree(oid: fromCommit.treeOID)
        let toTree = try lookupTree(oid: toCommit.treeOID)

        return try GKDiffEngine.diffTrees(oldTree: fromTree, newTree: toTree, objectDB: objectDB)
    }

    /// Computes the diff between the index and HEAD.
    public func GKDiffStaged() throws -> GKDiff {
        let index = try readIndex()
        let headCommitOID = try? GKHeadCommitOID()
        let headTree: GKTree?

        if let oid = headCommitOID {
            let commit = try lookupCommit(oid: oid)
            headTree = try lookupTree(oid: commit.treeOID)
        } else {
            headTree = nil
        }

        // Build a tree from the index for comparison
        let indexTreeOID = try index.writeTree(objectDB: objectDB)
        let indexTree = try lookupTree(oid: indexTreeOID)

        return try GKDiffEngine.diffTrees(oldTree: headTree, newTree: indexTree, objectDB: objectDB)
    }

    // MARK: - Merge

    /// Merges a branch into the current branch.
    /// - Parameters:
    ///   - branch: The branch name to merge.
    ///   - author: The signature for the merge commit.
    /// - Returns: The OID of the merge commit.
    @discardableResult
    public func GKMerge(branch: String, author: GKSignature) throws -> GKObjectID {
        let refName = "refs/heads/\(branch)"
        let target = try refStorage.resolve(refName)
        guard let theirOID = target.oid else {
            throw GKError.branchNotFound(branch)
        }

        let ourOID = try GKHeadCommitOID()

        // Check if fast-forward is possible
        if try isAncestor(oid: ourOID, of: theirOID) {
            // Fast-forward
            let head = try self.head()
            if case .branch(let name) = head {
                let ref = GKReference(name: "refs/heads/\(name)", target: .direct(theirOID))
                try refStorage.write(ref)
            }
            try checkoutTree(commitOID: theirOID)
            return theirOID
        }

        // Find merge base
        let baseOID = try findMergeBase(a: ourOID, b: theirOID)

        let ourCommit = try lookupCommit(oid: ourOID)
        let theirCommit = try lookupCommit(oid: theirOID)
        let ourTree = try lookupTree(oid: ourCommit.treeOID)
        let theirTree = try lookupTree(oid: theirCommit.treeOID)
        let baseTree: GKTree? = try baseOID.map { try lookupTree(oid: lookupCommit(oid: $0).treeOID) }

        let strategy = GKRecursiveMergeStrategy()
        let result = try strategy.merge(base: baseTree, ours: ourTree, theirs: theirTree, objectDB: objectDB)

        switch result {
        case .clean(let treeOID):
            let mergeCommit = GKCommit(
                treeOID: treeOID,
                parentOIDs: [ourOID, theirOID],
                author: author,
                committer: author,
                message: "Merge branch '\(branch)'"
            )
            let raw = GKRawObject(type: .commit, data: mergeCommit.serialize())
            try objectDB.write(raw)

            let head = try self.head()
            if case .branch(let name) = head {
                let ref = GKReference(name: "refs/heads/\(name)", target: .direct(raw.oid))
                try refStorage.write(ref)
            }

            return raw.oid

        case .conflict(let conflicts):
            throw GKError.mergeConflict(paths: conflicts.map(\.path))
        }
    }

    // MARK: - Remote Operations

    /// Adds a remote to the repository.
    /// - Parameters:
    ///   - name: The remote name (e.g., "origin").
    ///   - url: The remote URL.
    public func GKAddRemote(name: String, url: String) throws {
        try configuration.set("remote.\(name).url", value: url)
        try configuration.set("remote.\(name).fetch", value: "+refs/heads/*:refs/remotes/\(name)/*")
    }

    /// Removes a remote from the repository.
    /// - Parameter name: The remote name to remove.
    public func GKRemoveRemote(name: String) throws {
        try configuration.remove("remote.\(name).url")
        try configuration.remove("remote.\(name).fetch")
    }

    /// Lists configured remotes.
    public func GKRemotes() -> [GKRemote] {
        configuration.remotes()
    }

    /// Fetches objects from a remote (requires transport implementation).
    /// - Parameter remote: The remote name.
    /// - Parameter transport: The transport to use for network communication.
    public func GKFetch(remote: String, transport: GKTransport) throws {
        let advertisement = try transport.connect()

        // Determine what we need
        var wants = [GKObjectID]()
        var haves = [GKObjectID]()

        for ref in advertisement.references {
            guard let oid = ref.target.oid else { continue }
            if !objectDB.exists(oid: oid) {
                wants.append(oid)
            }
        }

        // Collect what we have
        if let headOID = try? GKHeadCommitOID() {
            haves.append(headOID)
        }

        guard !wants.isEmpty else { return }

        let packData = try transport.fetch(wants: wants, haves: haves)

        // Store fetched objects
        try unpackPackData(packData)

        // Update remote tracking refs
        let remoteConfig = configuration.remote(named: remote)
        for ref in advertisement.references where ref.isBranch {
            let trackingRef = "refs/remotes/\(remote)/\(ref.shortName)"
            try refStorage.write(GKReference(name: trackingRef, target: ref.target))
        }
    }

    /// Pushes to a remote (requires transport implementation).
    /// - Parameters:
    ///   - remote: The remote name.
    ///   - branch: The local branch to push.
    ///   - transport: The transport to use for network communication.
    public func GKPush(remote: String, branch: String, transport: GKTransport) throws {
        let refName = "refs/heads/\(branch)"
        let target = try refStorage.resolve(refName)
        guard let localOID = target.oid else {
            throw GKError.branchNotFound(branch)
        }

        let advertisement = try transport.connect()

        // Find the remote ref
        let remoteRefName = "refs/heads/\(branch)"
        let remoteOID = advertisement.references.first(where: { $0.name == remoteRefName })?.target.oid ?? .zero

        // Collect objects to send
        let objects = try collectObjects(from: localOID, excluding: remoteOID == .zero ? nil : remoteOID)
        let packData = try GKPackfileWriter.createPackfile(objects: objects)

        let command = GKPushCommand(refName: remoteRefName, oldOID: remoteOID, newOID: localOID)
        let results = try transport.push(commands: [command], packData: packData)

        for result in results where !result.success {
            throw GKError.networkError("Push failed for \(result.refName): \(result.message ?? "unknown")")
        }
    }

    /// Pulls from a remote (fetch + merge).
    /// - Parameters:
    ///   - remote: The remote name.
    ///   - branch: The branch to pull.
    ///   - transport: The transport to use.
    ///   - author: Signature for merge commit if needed.
    @discardableResult
    public func GKPull(remote: String, branch: String, transport: GKTransport, author: GKSignature) throws -> GKObjectID {
        // Fetch
        try GKFetch(remote: remote, transport: transport)

        // Merge tracking branch
        let trackingRef = "refs/remotes/\(remote)/\(branch)"
        let target = try refStorage.resolve(trackingRef)
        guard let remoteOID = target.oid else {
            throw GKError.referenceNotFound(trackingRef)
        }

        let ourOID = try GKHeadCommitOID()

        // Check if already up to date
        if ourOID == remoteOID {
            return ourOID
        }

        // Check fast-forward
        if try isAncestor(oid: ourOID, of: remoteOID) {
            let head = try self.head()
            if case .branch(let name) = head {
                let ref = GKReference(name: "refs/heads/\(name)", target: .direct(remoteOID))
                try refStorage.write(ref)
            }
            try checkoutTree(commitOID: remoteOID)
            return remoteOID
        }

        // Full merge needed
        return try GKMerge(branch: "\(remote)/\(branch)", author: author)
    }

    // MARK: - Clone

    /// Clones a remote repository.
    /// - Parameters:
    ///   - url: The remote URL.
    ///   - path: Local path to clone into.
    ///   - transport: The transport to use.
    /// - Returns: The newly created repository.
    @discardableResult
    public static func GKClone(url: String, to path: URL, transport: GKTransport) throws -> GKRepository {
        let repo = try GKInitRepository(at: path)
        try repo.GKAddRemote(name: "origin", url: url)

        let advertisement = try transport.connect()

        var wants = [GKObjectID]()
        for ref in advertisement.references {
            if let oid = ref.target.oid {
                wants.append(oid)
            }
        }

        if !wants.isEmpty {
            let packData = try transport.fetch(wants: wants, haves: [])
            try repo.unpackPackData(packData)
        }

        // Set up remote tracking branches
        for ref in advertisement.references where ref.isBranch {
            let trackingRef = "refs/remotes/origin/\(ref.shortName)"
            try repo.refStorage.write(GKReference(name: trackingRef, target: ref.target))
        }

        // Set up default branch
        if let headRef = advertisement.references.first(where: { $0.name == "HEAD" }),
           let headOID = headRef.target.oid {
            // Find which branch HEAD points to
            let defaultBranch = advertisement.references.first(where: {
                $0.isBranch && $0.target.oid == headOID
            })?.shortName ?? "main"

            let branchRef = GKReference(name: "refs/heads/\(defaultBranch)", target: .direct(headOID))
            try repo.refStorage.write(branchRef)
            try repo.refStorage.writeHead(.branch(defaultBranch))

            // Checkout
            try repo.checkoutTree(commitOID: headOID)
        }

        return repo
    }

    // MARK: - Reset

    /// Resets HEAD to a specific commit.
    /// - Parameters:
    ///   - oid: The commit OID to reset to.
    ///   - mode: The reset mode (soft, mixed, hard).
    public func GKReset(to oid: GKObjectID, mode: GKResetMode) throws {
        // Update HEAD
        let head = try self.head()
        switch head {
        case .branch(let name):
            let ref = GKReference(name: "refs/heads/\(name)", target: .direct(oid))
            try refStorage.write(ref)
        case .detached:
            try refStorage.writeHead(.detached(oid))
        }

        switch mode {
        case .soft:
            // Only move HEAD, don't touch index or workdir
            break

        case .mixed:
            // Reset index to match commit tree
            let commit = try lookupCommit(oid: oid)
            let tree = try lookupTree(oid: commit.treeOID)
            var index = GKIndex()
            try populateIndex(&index, from: tree, prefix: "")
            try writeIndex(index)

        case .hard:
            // Reset index and working directory
            let commit = try lookupCommit(oid: oid)
            try checkoutTree(commitOID: oid)
        }
    }

    // MARK: - Stash

    /// Stashes the current working directory changes.
    /// - Parameter message: Optional stash message.
    /// - Returns: The OID of the stash commit.
    @discardableResult
    public func GKStash(message: String? = nil) throws -> GKObjectID {
        let headOID = try GKHeadCommitOID()
        let index = try readIndex()

        // Create a tree from the current index
        let treeOID = try index.writeTree(objectDB: objectDB)

        // Create stash commit
        let currentBranch = (try? head().branchName) ?? "HEAD"
        let stashMessage = message ?? "WIP on \(currentBranch)"
        let author = GKSignature(name: "GitKit Stash", email: "stash@gitkit.local")

        let stashCommit = GKCommit(
            treeOID: treeOID,
            parentOIDs: [headOID],
            author: author,
            committer: author,
            message: stashMessage
        )

        let raw = GKRawObject(type: .commit, data: stashCommit.serialize())
        try objectDB.write(raw)

        // Save stash ref
        let stashRef = GKReference(name: "refs/stash", target: .direct(raw.oid))
        try refStorage.write(stashRef)

        // Reset working directory to HEAD
        try GKReset(to: headOID, mode: .hard)

        return raw.oid
    }

    // MARK: - Internal Helpers

    private func isAncestor(oid ancestor: GKObjectID, of descendant: GKObjectID) throws -> Bool {
        var queue = [descendant]
        var visited = Set<GKObjectID>()

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == ancestor { return true }
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            let commit = try lookupCommit(oid: current)
            queue.append(contentsOf: commit.parentOIDs)
        }
        return false
    }

    private func findMergeBase(a: GKObjectID, b: GKObjectID) throws -> GKObjectID? {
        // Simple merge base: find common ancestor using BFS
        var ancestorsA = Set<GKObjectID>()
        var queueA = [a]

        while !queueA.isEmpty {
            let current = queueA.removeFirst()
            ancestorsA.insert(current)
            if let commit = try? lookupCommit(oid: current) {
                queueA.append(contentsOf: commit.parentOIDs)
            }
        }

        var queueB = [b]
        var visited = Set<GKObjectID>()

        while !queueB.isEmpty {
            let current = queueB.removeFirst()
            if ancestorsA.contains(current) { return current }
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            if let commit = try? lookupCommit(oid: current) {
                queueB.append(contentsOf: commit.parentOIDs)
            }
        }

        return nil
    }

    private func collectObjects(from oid: GKObjectID, excluding: GKObjectID?) throws -> [GKRawObject] {
        var objects = [GKRawObject]()
        var visited = Set<GKObjectID>()
        var excludeSet = Set<GKObjectID>()

        // Build exclude set
        if let exc = excluding {
            var queue = [exc]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !excludeSet.contains(current) else { continue }
                excludeSet.insert(current)
                if let commit = try? lookupCommit(oid: current) {
                    queue.append(contentsOf: commit.parentOIDs)
                }
            }
        }

        // Collect objects reachable from oid but not in exclude set
        var queue = [oid]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !visited.contains(current) && !excludeSet.contains(current) else { continue }
            visited.insert(current)

            let raw = try objectDB.read(oid: current)
            objects.append(raw)

            if raw.type == .commit {
                let commit = try GKCommit(oid: current, data: raw.data)
                queue.append(commit.treeOID)
                queue.append(contentsOf: commit.parentOIDs)
            } else if raw.type == .tree {
                let tree = try GKTree(oid: current, data: raw.data)
                for entry in tree.entries {
                    queue.append(entry.oid)
                }
            }
        }

        return objects
    }

    func unpackPackData(_ data: Data) throws {
        // Simplified: just store raw objects from pack
        // A full implementation would parse the packfile format
        // For now, this handles thin packs by delegating to the object DB
        guard data.count > 12 else { return }

        let bytes = Array(data)

        // Verify PACK header
        guard bytes[0] == 0x50, bytes[1] == 0x41, bytes[2] == 0x43, bytes[3] == 0x4B else {
            throw GKError.packfileError("Invalid packfile header")
        }

        // Version
        let version = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 |
                      UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard version == 2 || version == 3 else {
            throw GKError.packfileError("Unsupported packfile version: \(version)")
        }

        // Object count
        let objectCount = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 |
                              UInt32(bytes[10]) << 8 | UInt32(bytes[11]))

        var offset = 12

        for _ in 0..<objectCount {
            guard offset < bytes.count - 20 else { break }

            // Read object header
            var byte = bytes[offset]
            let typeNum = (byte >> 4) & 0x07
            var size = Int(byte & 0x0F)
            var shift = 4
            offset += 1

            while byte & 0x80 != 0 {
                guard offset < bytes.count else { break }
                byte = bytes[offset]
                size |= Int(byte & 0x7F) << shift
                shift += 7
                offset += 1
            }

            let objectType: GKObjectType?
            switch typeNum {
            case 1: objectType = .commit
            case 2: objectType = .tree
            case 3: objectType = .blob
            case 4: objectType = .tag
            default: objectType = nil
            }

            // Decompress the object data
            if let type = objectType {
                let remaining = Data(bytes[offset...])
                if let decompressed = try? GKZlib.decompress(Data([0x78, 0x01]) + remaining) {
                    let objectData = decompressed.prefix(size)
                    let raw = GKRawObject(type: type, data: Data(objectData))
                    try objectDB.write(raw)
                }
            }

            // Skip to next object (approximate - full impl would track compressed size)
            offset += size
        }
    }
}

// MARK: - Reset Mode

/// The mode for a reset operation.
public enum GKResetMode: Sendable {
    /// Move HEAD only.
    case soft
    /// Move HEAD and reset index.
    case mixed
    /// Move HEAD, reset index, and reset working directory.
    case hard
}
