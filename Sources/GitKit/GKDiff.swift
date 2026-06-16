import Foundation

// MARK: - Diff

/// Represents a diff between two trees or blobs.
public struct GKDiff: Sendable {
    public let deltas: [GKDiffDelta]

    public init(deltas: [GKDiffDelta]) {
        self.deltas = deltas
    }

    /// The number of files changed.
    public var filesChanged: Int { deltas.count }

    /// The total number of insertions.
    public var insertions: Int { deltas.reduce(0) { $0 + $1.insertions } }

    /// The total number of deletions.
    public var deletions: Int { deltas.reduce(0) { $0 + $1.deletions } }
}

/// Represents a change to a single file.
public struct GKDiffDelta: Sendable {
    public let status: GKDiffStatus
    public let oldPath: String?
    public let newPath: String?
    public let oldOID: GKObjectID?
    public let newOID: GKObjectID?
    public let hunks: [GKDiffHunk]

    public var insertions: Int { hunks.reduce(0) { $0 + $1.insertions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }

    public init(
        status: GKDiffStatus,
        oldPath: String? = nil,
        newPath: String? = nil,
        oldOID: GKObjectID? = nil,
        newOID: GKObjectID? = nil,
        hunks: [GKDiffHunk] = []
    ) {
        self.status = status
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldOID = oldOID
        self.newOID = newOID
        self.hunks = hunks
    }

    /// The primary path for this delta.
    public var path: String {
        newPath ?? oldPath ?? ""
    }
}

/// The status of a diff delta.
public enum GKDiffStatus: String, Sendable {
    case added = "A"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case copied = "C"
    case typeChange = "T"
    case untracked = "?"
}

/// A contiguous set of changes within a file.
public struct GKDiffHunk: Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [GKDiffLine]

    public var insertions: Int { lines.filter { $0.origin == .addition }.count }
    public var deletions: Int { lines.filter { $0.origin == .deletion }.count }

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [GKDiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    /// The hunk header string.
    public var header: String {
        "@@ -\(oldStart),\(oldLines) +\(newStart),\(newLines) @@"
    }
}

/// A single line in a diff hunk.
public struct GKDiffLine: Sendable {
    public let origin: GKDiffLineOrigin
    public let content: String

    public init(origin: GKDiffLineOrigin, content: String) {
        self.origin = origin
        self.content = content
    }
}

/// The origin of a diff line.
public enum GKDiffLineOrigin: Character, Sendable {
    case context = " "
    case addition = "+"
    case deletion = "-"
}

// MARK: - Diff Engine

/// Engine for computing diffs between trees and blobs.
enum GKDiffEngine {
    /// Computes a diff between two trees.
    static func diffTrees(
        oldTree: GKTree?,
        newTree: GKTree?,
        objectDB: GKObjectDatabaseReading
    ) throws -> GKDiff {
        let oldEntries = oldTree?.entries ?? []
        let newEntries = newTree?.entries ?? []

        var oldMap = [String: GKTreeEntry]()
        for entry in oldEntries { oldMap[entry.name] = entry }

        var newMap = [String: GKTreeEntry]()
        for entry in newEntries { newMap[entry.name] = entry }

        var deltas = [GKDiffDelta]()

        // Find modifications and deletions
        for (name, oldEntry) in oldMap {
            if let newEntry = newMap[name] {
                if oldEntry.oid != newEntry.oid {
                    let hunks = try diffBlobs(
                        oldOID: oldEntry.oid,
                        newOID: newEntry.oid,
                        objectDB: objectDB
                    )
                    deltas.append(GKDiffDelta(
                        status: .modified,
                        oldPath: name,
                        newPath: name,
                        oldOID: oldEntry.oid,
                        newOID: newEntry.oid,
                        hunks: hunks
                    ))
                }
            } else {
                deltas.append(GKDiffDelta(
                    status: .deleted,
                    oldPath: name,
                    oldOID: oldEntry.oid
                ))
            }
        }

        // Find additions
        for (name, newEntry) in newMap where oldMap[name] == nil {
            deltas.append(GKDiffDelta(
                status: .added,
                newPath: name,
                newOID: newEntry.oid
            ))
        }

        return GKDiff(deltas: deltas.sorted { $0.path < $1.path })
    }

    /// Computes diff hunks between two blobs.
    static func diffBlobs(
        oldOID: GKObjectID,
        newOID: GKObjectID,
        objectDB: GKObjectDatabaseReading
    ) throws -> [GKDiffHunk] {
        let oldRaw = try objectDB.read(oid: oldOID)
        let newRaw = try objectDB.read(oid: newOID)

        let oldLines = String(data: oldRaw.data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        let newLines = String(data: newRaw.data, encoding: .utf8)?.components(separatedBy: "\n") ?? []

        return computeHunks(oldLines: oldLines, newLines: newLines)
    }

    /// Simple Myers-like diff algorithm producing hunks.
    static func computeHunks(oldLines: [String], newLines: [String]) -> [GKDiffHunk] {
        let lcs = longestCommonSubsequence(oldLines, newLines)
        var diffLines = [GKDiffLine]()

        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if lcsIdx < lcs.count && oldIdx < oldLines.count && newIdx < newLines.count &&
                oldLines[oldIdx] == lcs[lcsIdx] && newLines[newIdx] == lcs[lcsIdx] {
                diffLines.append(GKDiffLine(origin: .context, content: oldLines[oldIdx]))
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            } else if newIdx < newLines.count &&
                        (lcsIdx >= lcs.count || newLines[newIdx] != lcs[lcsIdx]) {
                diffLines.append(GKDiffLine(origin: .addition, content: newLines[newIdx]))
                newIdx += 1
            } else if oldIdx < oldLines.count &&
                        (lcsIdx >= lcs.count || oldLines[oldIdx] != lcs[lcsIdx]) {
                diffLines.append(GKDiffLine(origin: .deletion, content: oldLines[oldIdx]))
                oldIdx += 1
            }
        }

        guard !diffLines.isEmpty else { return [] }

        // Group into hunks (with 3 lines of context)
        return groupIntoHunks(diffLines: diffLines, contextLines: 3)
    }

    private static func groupIntoHunks(diffLines: [GKDiffLine], contextLines: Int) -> [GKDiffHunk] {
        // Simple: one big hunk for now
        let oldStart = 1
        var oldCount = 0
        let newStart = 1
        var newCount = 0

        for line in diffLines {
            switch line.origin {
            case .context:
                oldCount += 1
                newCount += 1
            case .deletion:
                oldCount += 1
            case .addition:
                newCount += 1
            }
        }

        return [GKDiffHunk(
            oldStart: oldStart,
            oldLines: oldCount,
            newStart: newStart,
            newLines: newCount,
            lines: diffLines
        )]
    }

    /// Longest Common Subsequence using dynamic programming.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 1...max(m, 1) {
            for j in 1...max(n, 1) {
                if i <= m && j <= n && a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var result = [String]()
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return result.reversed()
    }
}
