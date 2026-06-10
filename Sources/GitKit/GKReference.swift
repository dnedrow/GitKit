import Foundation

// MARK: - Reference Protocols

/// Protocol for reference storage backends.
public protocol GKReferenceStorage {
    /// Resolves a reference name to its target.
    func resolve(_ name: String) throws -> GKReferenceTarget

    /// Lists all references matching a glob pattern.
    func list(matching pattern: String?) throws -> [GKReference]

    /// Creates or updates a reference.
    func write(_ reference: GKReference) throws

    /// Deletes a reference.
    func delete(name: String) throws

    /// Checks if a reference exists.
    func exists(_ name: String) -> Bool
}

// MARK: - Reference

/// Represents a Git reference (branch, tag, etc.).
public struct GKReference: Sendable, Equatable {
    public let name: String
    public let target: GKReferenceTarget

    public init(name: String, target: GKReferenceTarget) {
        self.name = name
        self.target = target
    }

    /// Whether this is a branch reference.
    public var isBranch: Bool {
        name.hasPrefix("refs/heads/")
    }

    /// Whether this is a tag reference.
    public var isTag: Bool {
        name.hasPrefix("refs/tags/")
    }

    /// Whether this is a remote tracking reference.
    public var isRemote: Bool {
        name.hasPrefix("refs/remotes/")
    }

    /// The short name (e.g., "main" for "refs/heads/main").
    public var shortName: String {
        if isBranch {
            return String(name.dropFirst("refs/heads/".count))
        } else if isTag {
            return String(name.dropFirst("refs/tags/".count))
        } else if isRemote {
            return String(name.dropFirst("refs/remotes/".count))
        }
        return name
    }
}

// MARK: - Reference Target

/// The target of a reference — either a direct OID or a symbolic reference.
public enum GKReferenceTarget: Sendable, Equatable {
    case direct(GKObjectID)
    case symbolic(String)

    /// The OID if this is a direct reference.
    public var oid: GKObjectID? {
        if case .direct(let id) = self { return id }
        return nil
    }

    /// The symbolic target if this is a symbolic reference.
    public var symbolicTarget: String? {
        if case .symbolic(let name) = self { return name }
        return nil
    }
}

// MARK: - HEAD

/// Represents the HEAD state of a repository.
public enum GKHead: Sendable, Equatable {
    case branch(String) // symbolic ref to a branch
    case detached(GKObjectID) // detached at a specific commit

    /// The branch name if HEAD points to a branch.
    public var branchName: String? {
        if case .branch(let name) = self { return name }
        return nil
    }

    /// Whether HEAD is detached.
    public var isDetached: Bool {
        if case .detached = self { return true }
        return false
    }
}

// MARK: - Branch

/// Represents a Git branch.
public struct GKBranch: Sendable, Equatable {
    public let name: String
    public let commitOID: GKObjectID
    public let isRemote: Bool
    public let upstream: String?

    public init(name: String, commitOID: GKObjectID, isRemote: Bool = false, upstream: String? = nil) {
        self.name = name
        self.commitOID = commitOID
        self.isRemote = isRemote
        self.upstream = upstream
    }

    /// The full reference name.
    public var fullName: String {
        isRemote ? "refs/remotes/\(name)" : "refs/heads/\(name)"
    }
}
