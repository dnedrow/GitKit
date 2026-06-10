import Foundation

// MARK: - Merge

/// Merge strategy protocol.
public protocol GKMergeStrategy {
    /// Performs a merge between the current tree and another tree.
    func merge(
        base: GKTree?,
        ours: GKTree,
        theirs: GKTree,
        objectDB: GKObjectDatabase
    ) throws -> GKMergeResult
}

/// The result of a merge operation.
public enum GKMergeResult: Sendable {
    case clean(treeOID: GKObjectID)
    case conflict(conflicts: [GKMergeConflict])
}

/// Represents a merge conflict for a single path.
public struct GKMergeConflict: Sendable {
    public let path: String
    public let baseOID: GKObjectID?
    public let oursOID: GKObjectID?
    public let theirsOID: GKObjectID?

    public init(path: String, baseOID: GKObjectID?, oursOID: GKObjectID?, theirsOID: GKObjectID?) {
        self.path = path
        self.baseOID = baseOID
        self.oursOID = oursOID
        self.theirsOID = theirsOID
    }
}

/// Simple recursive merge strategy.
struct GKRecursiveMergeStrategy: GKMergeStrategy {
    func merge(
        base: GKTree?,
        ours: GKTree,
        theirs: GKTree,
        objectDB: GKObjectDatabase
    ) throws -> GKMergeResult {
        let baseEntries = base?.entries ?? []
        let oursEntries = ours.entries
        let theirsEntries = theirs.entries

        var baseMap = [String: GKTreeEntry]()
        for e in baseEntries { baseMap[e.name] = e }

        var oursMap = [String: GKTreeEntry]()
        for e in oursEntries { oursMap[e.name] = e }

        var theirsMap = [String: GKTreeEntry]()
        for e in theirsEntries { theirsMap[e.name] = e }

        var mergedEntries = [GKTreeEntry]()
        var conflicts = [GKMergeConflict]()

        // All paths from all three sides
        var allPaths = Set<String>()
        baseMap.keys.forEach { allPaths.insert($0) }
        oursMap.keys.forEach { allPaths.insert($0) }
        theirsMap.keys.forEach { allPaths.insert($0) }

        for path in allPaths.sorted() {
            let baseEntry = baseMap[path]
            let oursEntry = oursMap[path]
            let theirsEntry = theirsMap[path]

            switch (baseEntry, oursEntry, theirsEntry) {
            case (_, let o?, let t?) where o.oid == t.oid:
                // Both sides agree
                mergedEntries.append(o)

            case (let b?, let o?, let t?) where o.oid == b.oid:
                // Only theirs changed
                mergedEntries.append(t)

            case (let b?, let o?, let t?) where t.oid == b.oid:
                // Only ours changed
                mergedEntries.append(o)

            case (nil, let o?, nil):
                // Added only in ours
                mergedEntries.append(o)

            case (nil, nil, let t?):
                // Added only in theirs
                mergedEntries.append(t)

            case (_?, nil, nil):
                // Deleted in both — no entry
                break

            case (let b?, let o?, nil) where o.oid == b.oid:
                // Deleted in theirs, unchanged in ours — delete
                break

            case (let b?, nil, let t?) where t.oid == b.oid:
                // Deleted in ours, unchanged in theirs — delete
                break

            default:
                // Conflict
                conflicts.append(GKMergeConflict(
                    path: path,
                    baseOID: baseEntry?.oid,
                    oursOID: oursEntry?.oid,
                    theirsOID: theirsEntry?.oid
                ))
                // Keep ours in the merged tree for now
                if let o = oursEntry {
                    mergedEntries.append(o)
                } else if let t = theirsEntry {
                    mergedEntries.append(t)
                }
            }
        }

        if conflicts.isEmpty {
            let tree = GKTree(entries: mergedEntries)
            let raw = GKRawObject(type: .tree, data: tree.serialize())
            try objectDB.write(raw)
            return .clean(treeOID: raw.oid)
        } else {
            return .conflict(conflicts: conflicts)
        }
    }
}
