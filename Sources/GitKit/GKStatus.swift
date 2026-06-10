import Foundation

// MARK: - Status

/// Represents the working directory and index status.
public struct GKStatus: Sendable {
    /// Files staged for commit (index vs HEAD).
    public let staged: [GKStatusEntry]

    /// Files modified in the working directory (workdir vs index).
    public let unstaged: [GKStatusEntry]

    /// Untracked files.
    public let untracked: [String]

    public init(staged: [GKStatusEntry], unstaged: [GKStatusEntry], untracked: [String]) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    /// Whether the working directory is clean.
    public var isClean: Bool {
        staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
    }
}

/// A single status entry.
public struct GKStatusEntry: Sendable {
    public let path: String
    public let status: GKDiffStatus

    public init(path: String, status: GKDiffStatus) {
        self.path = path
        self.status = status
    }
}
