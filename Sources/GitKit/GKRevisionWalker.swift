import Foundation

// MARK: - Revision Walker

/// Protocol for walking commit history.
public protocol GKRevisionWalkerProtocol {
    /// Pushes a starting point for the walk.
    mutating func push(oid: GKObjectID) throws

    /// Hides a commit and its ancestors from the walk.
    mutating func hide(oid: GKObjectID) throws

    /// Returns the next commit in the walk, or nil if exhausted.
    mutating func next() throws -> GKCommit?

    /// Resets the walker.
    mutating func reset()
}

/// Sorting options for the revision walker.
public struct GKSortOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Topological sort (children before parents).
    public static let topological = GKSortOptions(rawValue: 1 << 0)
    /// Sort by time (most recent first).
    public static let time = GKSortOptions(rawValue: 1 << 1)
    /// Reverse the sort order.
    public static let reverse = GKSortOptions(rawValue: 1 << 2)
}

/// Walks the commit graph.
public struct GKRevisionWalker: GKRevisionWalkerProtocol {
    private let objectDB: GKObjectDatabaseReading
    private var startOIDs: [GKObjectID] = []
    private var hideOIDs: Set<GKObjectID> = []
    private var queue: [GKObjectID] = []
    private var visited: Set<GKObjectID> = []
    private var sortOptions: GKSortOptions

    public init(objectDB: GKObjectDatabaseReading, sorting: GKSortOptions = .time) {
        self.objectDB = objectDB
        self.sortOptions = sorting
    }

    public mutating func push(oid: GKObjectID) throws {
        startOIDs.append(oid)
        queue.append(oid)
    }

    public mutating func hide(oid: GKObjectID) throws {
        hideOIDs.insert(oid)
        // Also hide all ancestors
        var ancestorQueue = [oid]
        while !ancestorQueue.isEmpty {
            let current = ancestorQueue.removeFirst()
            hideOIDs.insert(current)
            let raw = try objectDB.read(oid: current)
            if raw.type == .commit, let commit = try? GKCommit(oid: current, data: raw.data) {
                ancestorQueue.append(contentsOf: commit.parentOIDs)
            }
        }
    }

    public mutating func next() throws -> GKCommit? {
        while !queue.isEmpty {
            let oid = queue.removeFirst()

            guard !visited.contains(oid) && !hideOIDs.contains(oid) else { continue }
            visited.insert(oid)

            let raw = try objectDB.read(oid: oid)
            guard raw.type == .commit else { continue }

            let commit = try GKCommit(oid: oid, data: raw.data)

            // Add parents to queue
            for parent in commit.parentOIDs {
                if !visited.contains(parent) && !hideOIDs.contains(parent) {
                    queue.append(parent)
                }
            }

            // Sort queue if needed
            if sortOptions.contains(.time) {
                var sortable = queue
                sortable.sort { a, b in
                    let commitA = try? GKCommit(oid: a, data: objectDB.read(oid: a).data)
                    let commitB = try? GKCommit(oid: b, data: objectDB.read(oid: b).data)
                    let timeA = commitA?.committer.time ?? .distantPast
                    let timeB = commitB?.committer.time ?? .distantPast
                    return timeA > timeB
                }
                queue = sortable
            }

            return commit
        }

        return nil
    }

    public mutating func reset() {
        queue = startOIDs
        visited.removeAll()
    }
}
