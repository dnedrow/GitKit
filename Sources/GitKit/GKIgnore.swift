import Foundation

// MARK: - Ignore

/// Protocol for gitignore pattern matching.
public protocol GKIgnoreProtocol {
    /// Checks if a path should be ignored.
    func isIgnored(path: String) -> Bool
}

/// Implements gitignore pattern matching.
///
/// Patterns are evaluated relative to the directory of the `.gitignore` (or
/// exclude file) that defined them. Each pattern is paired with that directory's
/// repository-root-relative path (`baseDir`, empty for the root, `.git/info/exclude`,
/// and the global excludes file). Matching follows Git's anchoring and directory
/// semantics over `/`-separated path segments.
public struct GKIgnore: GKIgnoreProtocol {
    /// A pattern together with the repo-root-relative directory it applies under.
    struct ScopedPattern {
        let baseDir: String
        /// Precomputed `baseDir + "/"` so scoping can skip non-matching paths cheaply
        /// without rebuilding the prefix string on every evaluation.
        let basePrefix: String
        let pattern: GKIgnorePattern

        init(baseDir: String, pattern: GKIgnorePattern) {
            self.baseDir = baseDir
            self.basePrefix = baseDir.isEmpty ? "" : baseDir + "/"
            self.pattern = pattern
        }
    }

    let entries: [ScopedPattern]

    /// Creates a matcher from a flat list of patterns scoped to the repository root.
    public init(patterns: [GKIgnorePattern] = []) {
        self.entries = patterns.map { ScopedPattern(baseDir: "", pattern: $0) }
    }

    /// Creates an ignore matcher from a single `.gitignore` file (scoped to root).
    public init(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        self.entries = GKIgnore.parse(content).map { ScopedPattern(baseDir: "", pattern: $0) }
    }

    /// Parses gitignore file content into patterns.
    public static func parse(_ content: String) -> [GKIgnorePattern] {
        content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { GKIgnorePattern(pattern: $0) }
    }

    /// Builds an ignore matcher by merging patterns from multiple source files,
    /// each scoped to a repository-root-relative base directory.
    ///
    /// Sources are read in the given order and their patterns concatenated, so later
    /// sources take precedence (last-match-wins, including negation). This is used to
    /// combine the global `core.excludesFile` and `.git/info/exclude` (base `""`) with
    /// per-directory `.gitignore` files (base = the file's directory, shallow to deep).
    ///
    /// Missing or unreadable files contribute zero patterns and never throw.
    public init(sources: [(baseDir: String, url: URL)]) {
        var merged = [ScopedPattern]()
        for source in sources {
            guard let content = try? String(contentsOf: source.url, encoding: .utf8) else { continue }
            for pattern in GKIgnore.parse(content) {
                merged.append(ScopedPattern(baseDir: source.baseDir, pattern: pattern))
            }
        }
        self.entries = merged
    }

    public func isIgnored(path: String) -> Bool {
        isIgnored(path: path, isDirectory: false)
    }

    /// Checks whether a path is ignored, taking into account whether the path refers
    /// to a directory. Directory-only patterns (e.g. `build/`) match directories but
    /// never files, so `isDirectory` selects the correct Git semantics for the leaf.
    ///
    /// This is the entry point a working-tree walk uses to decide it may prune an
    /// ignored directory's entire subtree. Consistent with Git, once a directory is
    /// ignored the walk stops descending, so a nested negation such as
    /// `!build/keep.txt` cannot re-include anything beneath an ignored `build/`.
    public func isIgnored(path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for entry in entries {
            guard let relative = GKIgnore.relativePath(of: path,
                                                       basePrefix: entry.basePrefix,
                                                       baseDir: entry.baseDir) else { continue }
            if entry.pattern.matches(path: relative, isDirectory: isDirectory) {
                ignored = !entry.pattern.isNegation
            }
        }
        return ignored
    }

    /// Convenience wrapper that reports whether a *directory* path is ignored, so a
    /// working-tree walk can prune the directory's subtree without inspecting children.
    public func isDirectoryIgnored(path: String) -> Bool {
        isIgnored(path: path, isDirectory: true)
    }

    /// Returns `path` relative to `baseDir`, or `nil` if `path` is not beneath it.
    /// An empty `baseDir` means the repository root and returns the path unchanged.
    static func relativePath(of path: String, under baseDir: String) -> String? {
        relativePath(of: path, basePrefix: baseDir.isEmpty ? "" : baseDir + "/", baseDir: baseDir)
    }

    /// Scoping check using a precomputed `basePrefix` (`baseDir + "/"`) to avoid
    /// rebuilding the prefix string for every pattern on every evaluation.
    static func relativePath(of path: String, basePrefix: String, baseDir: String) -> String? {
        if baseDir.isEmpty { return path }
        if path == baseDir { return nil } // the directory itself, not a child
        guard path.hasPrefix(basePrefix) else { return nil }
        return String(path.dropFirst(basePrefix.count))
    }
}

/// A single gitignore pattern.
public struct GKIgnorePattern: Sendable {
    public let rawPattern: String
    public let isNegation: Bool
    public let isDirectoryOnly: Bool
    /// Whether the pattern is anchored to its base directory (a `/` appears at the
    /// start or middle of the pattern). Non-anchored patterns match at any depth.
    public let isAnchored: Bool
    /// The pattern split into `/`-separated segments (may contain `**`).
    let segments: [String]
    /// Each segment pre-split into a `[Character]` array so recursive matching never
    /// rebuilds character arrays or `Array` slices on a hot path.
    let segmentChars: [[Character]]

    /// The `**` segment, precomputed once for cheap identity comparison.
    private static let doubleStar: [Character] = ["*", "*"]

    public init(pattern: String) {
        var p = pattern
        self.isNegation = p.hasPrefix("!")
        if isNegation { p = String(p.dropFirst()) }

        self.isDirectoryOnly = p.hasSuffix("/")
        if isDirectoryOnly { p = String(p.dropLast()) }

        // A separator at the start or middle anchors the pattern to its base dir.
        self.isAnchored = p.contains("/")
        if p.hasPrefix("/") { p = String(p.dropFirst()) }

        self.rawPattern = pattern
        let segs = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        self.segments = segs
        self.segmentChars = segs.map(Array.init)
    }

    /// Checks if this pattern matches the given path (already made relative to the
    /// pattern's base directory).
    public func matches(path: String) -> Bool {
        matches(path: path, isDirectory: false)
    }

    /// Checks if this pattern matches the given path, honoring whether the leaf is a
    /// directory. A directory-only pattern (`foo/`) matches a directory leaf but not
    /// a file leaf; paths *beneath* a matched directory always match either way.
    public func matches(path: String, isDirectory: Bool) -> Bool {
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true).map(Array.init)
        guard !segmentChars.isEmpty, !pathSegments.isEmpty else { return false }

        if isAnchored {
            return matchesPrefix(pathSegments, startingAt: 0, isDirectory: isDirectory)
        }
        // Floating: the pattern may match starting at any path segment.
        for start in 0..<pathSegments.count {
            if matchesPrefix(pathSegments, startingAt: start, isDirectory: isDirectory) { return true }
        }
        return false
    }

    /// Whether `segments` matches a prefix of `pathSegments[start...]`. If the match
    /// stops before the end of the path, the path is inside a matched directory and
    /// is ignored. If it matches exactly to the leaf, a directory-only pattern matches
    /// only when the leaf is itself a directory.
    private func matchesPrefix(_ pathSegments: [[Character]], startingAt start: Int, isDirectory: Bool) -> Bool {
        for end in start...pathSegments.count {
            if Self.matchSegments(segmentChars, 0, pathSegments, start, end) {
                if end < pathSegments.count {
                    return true // path is beneath a matched directory
                }
                // Exact leaf match: a directory-only pattern needs a directory leaf.
                return !isDirectoryOnly || isDirectory
            }
        }
        return false
    }

    /// Whether the pattern segments `pat[pi...]` match the path segments
    /// `path[xi..<end]`, with `**` spanning zero or more segments. Indices are used
    /// instead of slicing so no intermediate arrays are allocated during recursion.
    static func matchSegments(_ pat: [[Character]], _ pi: Int, _ path: [[Character]], _ xi: Int, _ end: Int) -> Bool {
        if pi == pat.count { return xi == end }
        let head = pat[pi]
        if head == doubleStar {
            // Match zero or more leading path segments.
            for split in xi...end {
                if matchSegments(pat, pi + 1, path, split, end) { return true }
            }
            return false
        }
        guard xi < end else { return false }
        guard segmentMatch(head, 0, path[xi], 0) else { return false }
        return matchSegments(pat, pi + 1, path, xi + 1, end)
    }

    /// Glob-matches a single path segment against a single pattern segment,
    /// supporting `*` (any run of non-`/`), `?` (one char), and `[...]`/`[!...]`.
    private static func segmentMatch(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        switch p[pi] {
        case "*":
            // Collapse consecutive '*'; within a segment '*' matches any run.
            var np = pi
            while np < p.count && p[np] == "*" { np += 1 }
            if np == p.count { return true }
            for i in si...s.count {
                if segmentMatch(p, np, s, i) { return true }
            }
            return false
        case "?":
            return si < s.count && segmentMatch(p, pi + 1, s, si + 1)
        case "[":
            guard si < s.count else { return false }
            return matchCharClass(p, pi, s, si)
        default:
            return si < s.count && p[pi] == s[si] && segmentMatch(p, pi + 1, s, si + 1)
        }
    }

    /// Matches a `[...]` / `[!...]` character class at `p[pi]` against `s[si]`,
    /// supporting ranges (`a-z`) and negation (`[!...]`).
    private static func matchCharClass(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        var i = pi + 1
        var negate = false
        if i < p.count && (p[i] == "!" || p[i] == "^") { negate = true; i += 1 }

        var matched = false
        var hasClose = false
        let ch = s[si]
        while i < p.count {
            if p[i] == "]" { hasClose = true; i += 1; break }
            // Range like a-z (not when '-' is first or last in the class).
            if i + 2 < p.count && p[i + 1] == "-" && p[i + 2] != "]" {
                if ch >= p[i] && ch <= p[i + 2] { matched = true }
                i += 3
            } else {
                if ch == p[i] { matched = true }
                i += 1
            }
        }
        // Malformed class (no closing ']'): treat '[' literally.
        guard hasClose else {
            return p[pi] == ch && segmentMatch(p, pi + 1, s, si + 1)
        }
        if matched == negate { return false }
        return segmentMatch(p, i, s, si + 1)
    }
}
