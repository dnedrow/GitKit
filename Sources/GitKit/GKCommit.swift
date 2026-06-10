import Foundation

// MARK: - Commit

/// Represents a Git commit object.
public struct GKCommit: GKObjectProtocol, Sendable {
    public let oid: GKObjectID
    public let treeOID: GKObjectID
    public let parentOIDs: [GKObjectID]
    public let author: GKSignature
    public let committer: GKSignature
    public let message: String
    public let gpgSignature: String?
    public var type: GKObjectType { .commit }

    /// Creates a new commit.
    public init(
        treeOID: GKObjectID,
        parentOIDs: [GKObjectID],
        author: GKSignature,
        committer: GKSignature,
        message: String
    ) {
        self.treeOID = treeOID
        self.parentOIDs = parentOIDs
        self.author = author
        self.committer = committer
        self.message = message
        self.gpgSignature = nil

        let data = GKCommit.serializeCommit(
            treeOID: treeOID,
            parentOIDs: parentOIDs,
            author: author,
            committer: committer,
            message: message
        )
        let raw = GKRawObject(type: .commit, data: data)
        self.oid = raw.oid
    }

    /// Creates a commit from raw object data.
    init(oid: GKObjectID, data: Data) throws {
        self.oid = oid

        guard let content = String(data: data, encoding: .utf8) else {
            throw GKError.invalidCommit("Cannot decode commit as UTF-8")
        }

        var treeOID: GKObjectID?
        var parentOIDs = [GKObjectID]()
        var author: GKSignature?
        var committer: GKSignature?
        var gpgSig: String?
        var messageLines = [String]()
        var inMessage = false
        var inGPGSig = false

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if inMessage {
                messageLines.append(line)
                continue
            }

            if inGPGSig {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    gpgSig = (gpgSig ?? "") + line.trimmingCharacters(in: .whitespaces) + "\n"
                    continue
                } else {
                    inGPGSig = false
                }
            }

            if line.isEmpty {
                inMessage = true
                continue
            }

            if line.hasPrefix("tree ") {
                let hex = String(line.dropFirst(5))
                treeOID = GKObjectID(hex: hex)
            } else if line.hasPrefix("parent ") {
                let hex = String(line.dropFirst(7))
                if let pid = GKObjectID(hex: hex) {
                    parentOIDs.append(pid)
                }
            } else if line.hasPrefix("author ") {
                author = GKSignature.parse(String(line.dropFirst(7)))
            } else if line.hasPrefix("committer ") {
                committer = GKSignature.parse(String(line.dropFirst(10)))
            } else if line.hasPrefix("gpgsig ") {
                inGPGSig = true
                gpgSig = String(line.dropFirst(7)) + "\n"
            }
        }

        guard let tree = treeOID else {
            throw GKError.invalidCommit("Missing tree field")
        }
        guard let auth = author else {
            throw GKError.invalidCommit("Missing author field")
        }
        guard let comm = committer else {
            throw GKError.invalidCommit("Missing committer field")
        }

        self.treeOID = tree
        self.parentOIDs = parentOIDs
        self.author = auth
        self.committer = comm
        self.message = messageLines.joined(separator: "\n")
        self.gpgSignature = gpgSig
    }

    public func serialize() -> Data {
        GKCommit.serializeCommit(
            treeOID: treeOID,
            parentOIDs: parentOIDs,
            author: author,
            committer: committer,
            message: message
        )
    }

    /// The short summary (first line of the commit message).
    public var summary: String {
        message.components(separatedBy: "\n").first ?? ""
    }

    /// Whether this is a merge commit (has more than one parent).
    public var isMerge: Bool {
        parentOIDs.count > 1
    }

    /// Whether this is the initial commit (no parents).
    public var isRoot: Bool {
        parentOIDs.isEmpty
    }

    private static func serializeCommit(
        treeOID: GKObjectID,
        parentOIDs: [GKObjectID],
        author: GKSignature,
        committer: GKSignature,
        message: String
    ) -> Data {
        var lines = [String]()
        lines.append("tree \(treeOID.hex)")
        for parent in parentOIDs {
            lines.append("parent \(parent.hex)")
        }
        lines.append("author \(author.formatted)")
        lines.append("committer \(committer.formatted)")
        lines.append("")
        lines.append(message)

        let content = lines.joined(separator: "\n")
        return Data(content.utf8)
    }
}

// MARK: - Signature

/// Represents an author or committer identity with timestamp.
public struct GKSignature: Sendable, Equatable {
    public let name: String
    public let email: String
    public let time: Date
    public let timeZoneOffset: Int // minutes from UTC

    public init(name: String, email: String, time: Date = Date(), timeZoneOffset: Int = 0) {
        self.name = name
        self.email = email
        self.time = time
        self.timeZoneOffset = timeZoneOffset
    }

    /// The formatted string for serialization: "Name <email> timestamp timezone"
    var formatted: String {
        let timestamp = Int(time.timeIntervalSince1970)
        let hours = abs(timeZoneOffset) / 60
        let minutes = abs(timeZoneOffset) % 60
        let sign = timeZoneOffset >= 0 ? "+" : "-"
        return "\(name) <\(email)> \(timestamp) \(sign)\(String(format: "%02d%02d", hours, minutes))"
    }

    /// Parses a signature string like "Name <email> timestamp timezone"
    static func parse(_ string: String) -> GKSignature? {
        // Format: "Name <email> timestamp +/-HHMM"
        guard let emailStart = string.firstIndex(of: "<"),
              let emailEnd = string.firstIndex(of: ">") else {
            return nil
        }

        let name = String(string[string.startIndex..<emailStart]).trimmingCharacters(in: .whitespaces)
        let email = String(string[string.index(after: emailStart)..<emailEnd])

        let remainder = String(string[string.index(after: emailEnd)...]).trimmingCharacters(in: .whitespaces)
        let parts = remainder.split(separator: " ")

        guard parts.count >= 2,
              let timestamp = TimeInterval(parts[0]) else {
            return GKSignature(name: name, email: email)
        }

        let tzString = String(parts[1])
        let tzSign = tzString.hasPrefix("-") ? -1 : 1
        let tzDigits = tzString.dropFirst()
        let tzHours = Int(tzDigits.prefix(2)) ?? 0
        let tzMinutes = Int(tzDigits.suffix(2)) ?? 0
        let offset = tzSign * (tzHours * 60 + tzMinutes)

        return GKSignature(
            name: name,
            email: email,
            time: Date(timeIntervalSince1970: timestamp),
            timeZoneOffset: offset
        )
    }
}
