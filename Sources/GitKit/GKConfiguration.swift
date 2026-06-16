import Foundation

// MARK: - Configuration

/// Protocol for Git configuration access.
public protocol GKConfigurationProtocol {
    /// Gets a string value for a key.
    func getString(_ key: String) -> String?

    /// Gets a boolean value for a key.
    func getBool(_ key: String) -> Bool?

    /// Gets an integer value for a key.
    func getInt(_ key: String) -> Int?

    /// Sets a value for a key.
    mutating func set(_ key: String, value: String) throws

    /// Removes a key.
    mutating func remove(_ key: String) throws
}

/// Git configuration file parser and writer.
public struct GKConfiguration: GKConfigurationProtocol {
    var sections: [GKConfigSection]
    let url: URL?

    public init() {
        self.sections = []
        self.url = nil
    }

    /// Reads a configuration from a file.
    public init(from url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.sections = []
            return
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        self.sections = GKConfiguration.parse(content)
    }

    public func getString(_ key: String) -> String? {
        let (section, subsection, name) = splitKey(key)
        return sections.first(where: { $0.name == section && $0.subsection == subsection })?
            .entries.first(where: { $0.key == name })?.value
    }

    public func getBool(_ key: String) -> Bool? {
        guard let value = getString(key) else { return nil }
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    public func getInt(_ key: String) -> Int? {
        guard let value = getString(key) else { return nil }
        return Int(value)
    }

    public mutating func set(_ key: String, value: String) throws {
        let (section, subsection, name) = splitKey(key)
        try GKConfiguration.validateIdentifiers(section: section, subsection: subsection, name: name)

        if let idx = sections.firstIndex(where: { $0.name == section && $0.subsection == subsection }) {
            if let entryIdx = sections[idx].entries.firstIndex(where: { $0.key == name }) {
                sections[idx].entries[entryIdx] = GKConfigEntry(key: name, value: value)
            } else {
                sections[idx].entries.append(GKConfigEntry(key: name, value: value))
            }
        } else {
            var newSection = GKConfigSection(name: section, subsection: subsection)
            newSection.entries.append(GKConfigEntry(key: name, value: value))
            sections.append(newSection)
        }

        try save()
    }

    public mutating func remove(_ key: String) throws {
        let (section, subsection, name) = splitKey(key)

        if let idx = sections.firstIndex(where: { $0.name == section && $0.subsection == subsection }) {
            sections[idx].entries.removeAll { $0.key == name }
        }

        try save()
    }

    // MARK: - Remote Configuration

    /// Gets all configured remotes.
    public func remotes() -> [GKRemote] {
        sections.filter { $0.name == "remote" && $0.subsection != nil }.map { section in
            let name = section.subsection ?? ""
            let url = section.entries.first(where: { $0.key == "url" })?.value ?? ""
            let fetch = section.entries.first(where: { $0.key == "fetch" })?.value
            return GKRemote(name: name, url: url, fetchRefspec: fetch)
        }
    }

    /// Gets a specific remote by name.
    public func remote(named name: String) -> GKRemote? {
        remotes().first(where: { $0.name == name })
    }

    // MARK: - Ignore Configuration

    /// Resolves the global excludes file referenced by `core.excludesFile`.
    ///
    /// Expands a leading `~` to the user's home directory. Returns `nil` when the key
    /// is unset or when the resolved file does not exist, so callers can treat a missing
    /// global ignore file as "no global patterns" without handling errors.
    public func coreExcludesFile() -> URL? {
        guard let raw = getString("core.excludesFile")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            return nil
        }

        let expanded: String
        if raw == "~" {
            expanded = URL(fileURLWithPath: NSHomeDirectory()).path
        } else if raw.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = (raw as NSString).expandingTildeInPath
        }

        guard FileManager.default.fileExists(atPath: expanded) else {
            return nil
        }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - Branch Configuration

    /// Gets the upstream (tracking) information for a branch.
    public func branchUpstream(_ branch: String) -> (remote: String, merge: String)? {
        guard let remote = getString("branch.\(branch).remote"),
              let merge = getString("branch.\(branch).merge") else {
            return nil
        }
        return (remote, merge)
    }

    // MARK: - Private

    /// Validates the identifiers that compose a config key before they are
    /// written to disk.
    ///
    /// The section name and variable name are written **unquoted**, so they must
    /// contain only characters Git permits there (letters, digits, `-`, and `.`
    /// for sections). The subsection is quoted and escaped on write, so it only
    /// needs to be free of newlines and NUL bytes, which Git forbids and which
    /// could otherwise break out of the header.
    static func validateIdentifiers(section: String, subsection: String?, name: String) throws {
        func isSectionChar(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "."
        }
        func isNameChar(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "-"
        }

        guard !section.isEmpty, section.unicodeScalars.allSatisfy(isSectionChar) else {
            throw GKError.invalidConfiguration("invalid section name '\(section)'")
        }
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(isNameChar) else {
            throw GKError.invalidConfiguration("invalid variable name '\(name)'")
        }
        if let subsection {
            for scalar in subsection.unicodeScalars where scalar == "\n" || scalar == "\r" || scalar == "\0" {
                throw GKError.invalidConfiguration("invalid subsection name '\(subsection)'")
            }
        }
    }

    /// Unescapes a quoted/escaped config value, honoring inline `#`/`;` comments
    /// outside of quotes. This is the read-side counterpart to `escapeValue`.
    static func parseValue(_ raw: String) -> String {
        // Leading whitespace (always outside quotes) is insignificant in Git.
        let trimmed = Substring(raw).drop { $0 == " " || $0 == "\t" }
        let characters = Array(trimmed)

        var result = [Character]()
        var inQuotes = false
        var trailingUnquotedWhitespace = 0
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                let mapped: Character
                switch next {
                case "n": mapped = "\n"
                case "t": mapped = "\t"
                case "b": mapped = "\u{08}"
                case "\"": mapped = "\""
                case "\\": mapped = "\\"
                default: mapped = next
                }
                result.append(mapped)
                trailingUnquotedWhitespace = 0
                index += 2
                continue
            }

            if character == "\"" {
                inQuotes.toggle()
                index += 1
                continue
            }

            if !inQuotes && (character == "#" || character == ";") {
                break // Start of an inline comment.
            }

            if !inQuotes && (character == " " || character == "\t") {
                result.append(character)
                trailingUnquotedWhitespace += 1
                index += 1
                continue
            }

            result.append(character)
            trailingUnquotedWhitespace = 0
            index += 1
        }

        if trailingUnquotedWhitespace > 0 {
            result.removeLast(trailingUnquotedWhitespace)
        }
        return String(result)
    }

    private func splitKey(_ key: String) -> (section: String, subsection: String?, name: String) {
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        if parts.count == 3 {
            return (parts[0], parts[1], parts[2])
        } else if parts.count == 2 {
            return (parts[0], nil, parts[1])
        }
        return (key, nil, "")
    }

    private func save() throws {
        guard let url = url else { return }
        let content = serialize()
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func serialize() -> String {
        var lines = [String]()
        for section in sections {
            if let sub = section.subsection {
                lines.append("[\(section.name) \"\(GKConfiguration.escapeSubsection(sub))\"]")
            } else {
                lines.append("[\(section.name)]")
            }
            for entry in section.entries {
                lines.append("\t\(entry.key) = \(GKConfiguration.escapeValue(entry.value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Escaping

    /// Escapes a subsection name for a `[section "subsection"]` header.
    ///
    /// Only backslash and double-quote are special inside the quoted subsection;
    /// escaping them prevents a value such as `origin"]\n[core` from closing the
    /// header early and injecting a new section. Newlines are rejected upstream
    /// in `set(_:value:)` because Git does not permit them in a subsection.
    static func escapeSubsection(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.append(character)
            }
        }
        return result
    }

    /// Escapes and, when necessary, double-quotes a configuration value so it
    /// cannot inject additional lines or sections into the config file.
    ///
    /// Newlines, tabs, backspaces, quotes, backslashes, comment characters
    /// (`#`/`;`), other control characters, and leading/trailing whitespace all
    /// force the value to be wrapped in quotes with the appropriate escapes. This
    /// is the primary defense against config-injection: a remote URL containing
    /// `\n[core]\n\tsshCommand = ...` is stored as a single inert quoted value.
    static func escapeValue(_ value: String) -> String {
        var escaped = ""
        var needsQuoting = value.isEmpty
            || value.first == " " || value.first == "\t"
            || value.last == " " || value.last == "\t"

        for character in value {
            switch character {
            case "\\": escaped += "\\\\"; needsQuoting = true
            case "\"": escaped += "\\\""; needsQuoting = true
            case "\n": escaped += "\\n"; needsQuoting = true
            case "\t": escaped += "\\t"; needsQuoting = true
            case "\u{08}": escaped += "\\b"; needsQuoting = true
            case "#", ";": escaped.append(character); needsQuoting = true
            default:
                if let ascii = character.asciiValue, ascii < 0x20 {
                    // Other control characters: keep verbatim but force quoting
                    // so they cannot be mistaken for line structure.
                    needsQuoting = true
                }
                escaped.append(character)
            }
        }

        return needsQuoting ? "\"\(escaped)\"" : escaped
    }

    private static func parse(_ content: String) -> [GKConfigSection] {
        var sections = [GKConfigSection]()
        var currentSection: GKConfigSection?

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("[") {
                if let section = currentSection {
                    sections.append(section)
                }
                currentSection = parseSectionHeader(trimmed)
            } else if let section = currentSection {
                if let entry = parseEntry(trimmed) {
                    currentSection?.entries.append(entry)
                }
                _ = section // silence warning
            }
        }

        if let section = currentSection {
            sections.append(section)
        }

        return sections
    }

    private static func parseSectionHeader(_ line: String) -> GKConfigSection {
        var name = ""
        var subsection: String?

        let content = line.dropFirst().dropLast() // Remove [ and ]
        if let quoteStart = content.firstIndex(of: "\"") {
            name = String(content[..<quoteStart]).trimmingCharacters(in: .whitespaces)
            // Walk the quoted subsection, honoring `\\` and `\"` escapes, until
            // the matching unescaped closing quote.
            var sub = ""
            var index = content.index(after: quoteStart)
            while index < content.endIndex {
                let character = content[index]
                if character == "\\" {
                    let next = content.index(after: index)
                    if next < content.endIndex {
                        sub.append(content[next])
                        index = content.index(after: next)
                        continue
                    }
                } else if character == "\"" {
                    break
                }
                sub.append(character)
                index = content.index(after: index)
            }
            subsection = sub
        } else {
            name = String(content).trimmingCharacters(in: .whitespaces)
        }

        return GKConfigSection(name: name, subsection: subsection)
    }

    private static func parseEntry(_ line: String) -> GKConfigEntry? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            // Boolean key (key without value means true)
            let key = line.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : GKConfigEntry(key: key, value: "true")
        }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = parseValue(String(parts[1]))
        return GKConfigEntry(key: key, value: value)
    }
}

// MARK: - Supporting Types

struct GKConfigSection {
    let name: String
    let subsection: String?
    var entries: [GKConfigEntry]

    init(name: String, subsection: String?) {
        self.name = name
        self.subsection = subsection
        self.entries = []
    }
}

struct GKConfigEntry {
    let key: String
    let value: String
}

/// Represents a Git remote.
public struct GKRemote: Sendable, Equatable {
    public let name: String
    public let url: String
    public let fetchRefspec: String?

    public init(name: String, url: String, fetchRefspec: String? = nil) {
        self.name = name
        self.url = url
        self.fetchRefspec = fetchRefspec
    }
}
