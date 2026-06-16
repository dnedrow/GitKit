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
                lines.append("[\(section.name) \"\(sub)\"]")
            } else {
                lines.append("[\(section.name)]")
            }
            for entry in section.entries {
                lines.append("\t\(entry.key) = \(entry.value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
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
            let afterQuote = content.index(after: quoteStart)
            if let quoteEnd = content[afterQuote...].firstIndex(of: "\"") {
                subsection = String(content[afterQuote..<quoteEnd])
            }
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
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
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
