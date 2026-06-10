import Foundation

// MARK: - File-based Reference Storage

/// File-system-based reference storage (.git/refs/).
final class GKFileReferenceStorage: GKReferenceStorage {
    let gitDir: URL

    init(gitDir: URL) {
        self.gitDir = gitDir
    }

    func resolve(_ name: String) throws -> GKReferenceTarget {
        // Handle HEAD specially
        let refPath: URL
        if name == "HEAD" {
            refPath = gitDir.appendingPathComponent("HEAD")
        } else if name.hasPrefix("refs/") {
            refPath = gitDir.appendingPathComponent(name)
        } else {
            // Try as a branch shorthand
            refPath = gitDir.appendingPathComponent("refs/heads/\(name)")
        }

        guard FileManager.default.fileExists(atPath: refPath.path) else {
            // Check packed-refs
            if let target = try? resolveFromPackedRefs(name) {
                return target
            }
            throw GKError.referenceNotFound(name)
        }

        let content = try String(contentsOf: refPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        if content.hasPrefix("ref: ") {
            return .symbolic(String(content.dropFirst(5)))
        } else if let oid = GKObjectID(hex: content) {
            return .direct(oid)
        } else {
            throw GKError.invalidReference("Invalid reference content: \(content)")
        }
    }

    func list(matching pattern: String?) throws -> [GKReference] {
        var refs = [GKReference]()

        // Read loose refs
        let refsDir = gitDir.appendingPathComponent("refs")
        if FileManager.default.fileExists(atPath: refsDir.path) {
            try collectRefs(from: refsDir, prefix: "refs/", into: &refs)
        }

        // Read packed-refs
        let packedRefsPath = gitDir.appendingPathComponent("packed-refs")
        if FileManager.default.fileExists(atPath: packedRefsPath.path) {
            let content = try String(contentsOf: packedRefsPath, encoding: .utf8)
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("^") {
                    continue
                }
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let oid = GKObjectID(hex: String(parts[0])) {
                    let name = String(parts[1])
                    refs.append(GKReference(name: name, target: .direct(oid)))
                }
            }
        }

        // Filter by pattern if provided
        if let pattern = pattern {
            return refs.filter { matchesGlob($0.name, pattern: pattern) }
        }

        return refs
    }

    func write(_ reference: GKReference) throws {
        let refPath = gitDir.appendingPathComponent(reference.name)
        let dir = refPath.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let content: String
        switch reference.target {
        case .direct(let oid):
            content = oid.hex + "\n"
        case .symbolic(let target):
            content = "ref: \(target)\n"
        }

        try content.write(to: refPath, atomically: true, encoding: .utf8)
    }

    func delete(name: String) throws {
        let refPath = gitDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: refPath.path) else {
            throw GKError.referenceNotFound(name)
        }
        try FileManager.default.removeItem(at: refPath)
    }

    func exists(_ name: String) -> Bool {
        let refPath = gitDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: refPath.path) {
            return true
        }
        // Check packed-refs
        return (try? resolveFromPackedRefs(name)) != nil
    }

    // MARK: - HEAD Operations

    func readHead() throws -> GKHead {
        let target = try resolve("HEAD")
        switch target {
        case .symbolic(let ref):
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return .branch(branch)
        case .direct(let oid):
            return .detached(oid)
        }
    }

    func writeHead(_ head: GKHead) throws {
        let headPath = gitDir.appendingPathComponent("HEAD")
        let content: String
        switch head {
        case .branch(let name):
            content = "ref: refs/heads/\(name)\n"
        case .detached(let oid):
            content = oid.hex + "\n"
        }
        try content.write(to: headPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private func collectRefs(from dir: URL, prefix: String, into refs: inout [GKReference]) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }

        for url in contents {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                try collectRefs(from: url, prefix: prefix + url.lastPathComponent + "/", into: &refs)
            } else {
                let name = prefix + url.lastPathComponent
                let content = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

                let target: GKReferenceTarget
                if content.hasPrefix("ref: ") {
                    target = .symbolic(String(content.dropFirst(5)))
                } else if let oid = GKObjectID(hex: content) {
                    target = .direct(oid)
                } else {
                    continue
                }

                refs.append(GKReference(name: name, target: target))
            }
        }
    }

    private func resolveFromPackedRefs(_ name: String) throws -> GKReferenceTarget? {
        let packedRefsPath = gitDir.appendingPathComponent("packed-refs")
        guard FileManager.default.fileExists(atPath: packedRefsPath.path) else {
            return nil
        }

        let content = try String(contentsOf: packedRefsPath, encoding: .utf8)
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("^") {
                continue
            }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            if parts.count == 2 && String(parts[1]) == name {
                if let oid = GKObjectID(hex: String(parts[0])) {
                    return .direct(oid)
                }
            }
        }
        return nil
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        // Simple glob matching: * matches any characters
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return string.hasPrefix(prefix)
        }
        return string == pattern
    }
}
