import Foundation

// MARK: - Ignore

/// Protocol for gitignore pattern matching.
public protocol GKIgnoreProtocol {
    /// Checks if a path should be ignored.
    func isIgnored(path: String) -> Bool
}

/// Implements gitignore pattern matching.
public struct GKIgnore: GKIgnoreProtocol {
    let patterns: [GKIgnorePattern]

    public init(patterns: [GKIgnorePattern] = []) {
        self.patterns = patterns
    }

    /// Creates an ignore matcher from a .gitignore file.
    public init(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        self.patterns = GKIgnore.parse(content)
    }

    /// Parses gitignore file content into patterns.
    public static func parse(_ content: String) -> [GKIgnorePattern] {
        content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { GKIgnorePattern(pattern: $0) }
    }

    /// Builds an ignore matcher by merging patterns from multiple source files.
    ///
    /// Sources are read in the given order and their patterns concatenated, so later
    /// sources take precedence (last-match-wins, including negation). This is used to
    /// combine the global `core.excludesFile`, `.git/info/exclude`, and per-directory
    /// `.gitignore` files (shallow to deep).
    ///
    /// Missing or unreadable files contribute zero patterns and never throw.
    public init(mergingFiles urls: [URL]) {
        var merged = [GKIgnorePattern]()
        for url in urls {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            merged.append(contentsOf: GKIgnore.parse(content))
        }
        self.patterns = merged
    }

    public func isIgnored(path: String) -> Bool {
        var ignored = false
        for pattern in patterns {
            if pattern.matches(path: path) {
                ignored = !pattern.isNegation
            }
        }
        return ignored
    }
}

/// A single gitignore pattern.
public struct GKIgnorePattern: Sendable {
    public let rawPattern: String
    public let isNegation: Bool
    public let isDirectoryOnly: Bool
    let matchPattern: String

    public init(pattern: String) {
        var p = pattern
        self.isNegation = p.hasPrefix("!")
        if isNegation { p = String(p.dropFirst()) }

        self.isDirectoryOnly = p.hasSuffix("/")
        if isDirectoryOnly { p = String(p.dropLast()) }

        self.rawPattern = pattern
        self.matchPattern = p
    }

    /// Checks if this pattern matches the given path.
    public func matches(path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)

        if matchPattern.contains("/") {
            // Pattern with path separator - match from root
            return globMatch(path, pattern: matchPattern)
        } else {
            // Pattern without separator - match any component
            for component in components {
                if globMatch(component, pattern: matchPattern) {
                    return true
                }
            }
            return globMatch(path, pattern: matchPattern)
        }
    }

    private func globMatch(_ string: String, pattern: String) -> Bool {
        let s = Array(string)
        let p = Array(pattern)
        return globMatchHelper(s, 0, p, 0)
    }

    private func globMatchHelper(_ s: [Character], _ si: Int, _ p: [Character], _ pi: Int) -> Bool {
        if pi == p.count { return si == s.count }
        if p[pi] == "*" {
            if pi + 1 < p.count && p[pi + 1] == "*" {
                // ** matches everything including /
                for i in si...s.count {
                    if globMatchHelper(s, i, p, pi + 2) { return true }
                }
                return false
            }
            // * matches everything except /
            for i in si...s.count {
                if i > si && (i <= s.count && s[i-1] == "/") { break }
                if globMatchHelper(s, i, p, pi + 1) { return true }
            }
            return false
        }
        if si == s.count { return false }
        if p[pi] == "?" {
            return s[si] != "/" && globMatchHelper(s, si + 1, p, pi + 1)
        }
        if p[pi] == s[si] {
            return globMatchHelper(s, si + 1, p, pi + 1)
        }
        return false
    }
}
