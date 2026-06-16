import Foundation

// MARK: - Path & Reference Name Validation

/// Centralized validation for untrusted path components and reference names.
///
/// Git objects (trees) and remote ref advertisements are attacker-controlled
/// input. Writing them to disk without validation enables directory traversal
/// (e.g. a tree entry named `..` or `../../etc/...`) and `.git` overwrites that
/// can lead to remote code execution. These helpers reject such inputs before
/// any filesystem path is constructed.
enum GKPathValidation {
    /// Validates a single path component taken from a tree entry name.
    ///
    /// Rejects names that Git itself forbids inside a tree:
    /// - empty names,
    /// - `.` and `..`,
    /// - any name containing a path separator (`/` or `\`) or a NUL byte,
    /// - `.git` in any case, including filesystem-equivalent spellings such as
    ///   `.git.`, `.git ` (trailing dot/space, collapsed by Windows/HFS+) and
    ///   the 8.3 short name `git~1`.
    /// - Parameter name: The raw entry name to validate.
    /// - Throws: `GKError.unsafePath` if the name is not safe to materialize.
    static func validateTreeEntryName(_ name: String) throws {
        guard !name.isEmpty else {
            throw GKError.unsafePath("empty path component")
        }
        guard name != "." && name != ".." else {
            throw GKError.unsafePath("path component '\(name)'")
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw GKError.unsafePath("path separator or NUL in component '\(name)'")
        }
        if isDotGit(name) {
            throw GKError.unsafePath("'.git' path component '\(name)'")
        }
    }

    /// Whether `name` is a filesystem-equivalent spelling of `.git`.
    ///
    /// Folds case and strips trailing dots/spaces (which Windows and HFS+ ignore
    /// when resolving names) so that `.GIT`, `.git.`, and `.git ` are all caught,
    /// along with the classic `git~1` 8.3 short name.
    private static func isDotGit(_ name: String) -> Bool {
        let lowered = name.lowercased()
        var trimmed = Substring(lowered)
        while let last = trimmed.last, last == "." || last == " " {
            trimmed = trimmed.dropLast()
        }
        return trimmed == ".git" || lowered == "git~1"
    }

    /// Ensures `candidate` resolves to a location inside `base`.
    ///
    /// A defense-in-depth check applied after path components are joined: even if
    /// component validation were bypassed, a path that escapes the repository
    /// root (via `..` or a symlink-resolved prefix) is rejected.
    /// - Parameters:
    ///   - candidate: The fully constructed URL about to be written.
    ///   - base: The directory the candidate must remain within.
    /// - Throws: `GKError.unsafePath` if `candidate` is not contained in `base`.
    static func ensureContained(_ candidate: URL, within base: URL) throws {
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path

        // Compare on path-component boundaries so that "/repo-evil" is not
        // treated as being inside "/repo".
        let baseWithSlash = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath == basePath || candidatePath.hasPrefix(baseWithSlash) else {
            throw GKError.unsafePath("'\(candidatePath)' escapes '\(basePath)'")
        }
    }

    /// Validates a reference name (e.g. `refs/heads/main`) before it is used to
    /// build a filesystem path under `.git`.
    ///
    /// Implements the relevant subset of `git check-ref-format`: rejects empty
    /// names, traversal (`..`, leading/trailing/double slash), `.lock` suffixes,
    /// `.`-prefixed components, ASCII control characters, whitespace, and the
    /// special bytes Git forbids (` ~ ^ : ? * [ \` and the `@{` sequence).
    /// - Parameter name: The full reference name to validate.
    /// - Throws: `GKError.invalidReferenceName` if the name is unsafe.
    static func validateReferenceName(_ name: String) throws {
        guard !name.isEmpty else {
            throw GKError.invalidReferenceName("empty reference name")
        }
        guard name != "@" else {
            throw GKError.invalidReferenceName("reference name cannot be '@'")
        }
        guard !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("//") else {
            throw GKError.invalidReferenceName("invalid '/' placement in '\(name)'")
        }
        guard !name.hasSuffix("."), !name.contains("..") else {
            throw GKError.invalidReferenceName("'.'/'..' sequence in '\(name)'")
        }
        guard !name.contains("@{") else {
            throw GKError.invalidReferenceName("'@{' sequence in '\(name)'")
        }

        let forbidden: Set<Character> = [" ", "~", "^", ":", "?", "*", "[", "\\", "\u{7f}"]
        for scalar in name.unicodeScalars where scalar.value < 0x20 {
            throw GKError.invalidReferenceName("control character in '\(name)'")
        }
        for character in name where forbidden.contains(character) {
            throw GKError.invalidReferenceName("forbidden character '\(character)' in '\(name)'")
        }

        // Per-component checks: no component may start with '.' or end with '.lock'.
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty else {
                throw GKError.invalidReferenceName("empty path component in '\(name)'")
            }
            guard !component.hasPrefix(".") else {
                throw GKError.invalidReferenceName("component begins with '.' in '\(name)'")
            }
            guard !component.hasSuffix(".lock") else {
                throw GKError.invalidReferenceName("component ends with '.lock' in '\(name)'")
            }
        }
    }
}
