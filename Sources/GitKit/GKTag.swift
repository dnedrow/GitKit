import Foundation

// MARK: - Tag

/// Represents a Git annotated tag object.
public struct GKTag: GKObjectProtocol, Sendable {
    public let oid: GKObjectID
    public let targetOID: GKObjectID
    public let targetType: GKObjectType
    public let tagName: String
    public let tagger: GKSignature?
    public let message: String
    public var type: GKObjectType { .tag }

    /// Creates a new annotated tag.
    public init(
        targetOID: GKObjectID,
        targetType: GKObjectType,
        tagName: String,
        tagger: GKSignature?,
        message: String
    ) {
        self.targetOID = targetOID
        self.targetType = targetType
        self.tagName = tagName
        self.tagger = tagger
        self.message = message

        let data = GKTag.serializeTag(
            targetOID: targetOID,
            targetType: targetType,
            tagName: tagName,
            tagger: tagger,
            message: message
        )
        let raw = GKRawObject(type: .tag, data: data)
        self.oid = raw.oid
    }

    /// Creates a tag from raw object data.
    init(oid: GKObjectID, data: Data) throws {
        self.oid = oid

        guard let content = String(data: data, encoding: .utf8) else {
            throw GKError.invalidTag("Cannot decode tag as UTF-8")
        }

        var targetOID: GKObjectID?
        var targetType: GKObjectType?
        var tagName: String?
        var tagger: GKSignature?
        var messageLines = [String]()
        var inMessage = false

        for line in content.components(separatedBy: "\n") {
            if inMessage {
                messageLines.append(line)
                continue
            }

            if line.isEmpty {
                inMessage = true
                continue
            }

            if line.hasPrefix("object ") {
                targetOID = GKObjectID(hex: String(line.dropFirst(7)))
            } else if line.hasPrefix("type ") {
                targetType = GKObjectType(rawValue: String(line.dropFirst(5)))
            } else if line.hasPrefix("tag ") {
                tagName = String(line.dropFirst(4))
            } else if line.hasPrefix("tagger ") {
                tagger = GKSignature.parse(String(line.dropFirst(7)))
            }
        }

        guard let target = targetOID else {
            throw GKError.invalidTag("Missing object field")
        }
        guard let type = targetType else {
            throw GKError.invalidTag("Missing type field")
        }
        guard let name = tagName else {
            throw GKError.invalidTag("Missing tag field")
        }

        self.targetOID = target
        self.targetType = type
        self.tagName = name
        self.tagger = tagger
        self.message = messageLines.joined(separator: "\n")
    }

    public func serialize() -> Data {
        GKTag.serializeTag(
            targetOID: targetOID,
            targetType: targetType,
            tagName: tagName,
            tagger: tagger,
            message: message
        )
    }

    private static func serializeTag(
        targetOID: GKObjectID,
        targetType: GKObjectType,
        tagName: String,
        tagger: GKSignature?,
        message: String
    ) -> Data {
        var lines = [String]()
        lines.append("object \(targetOID.hex)")
        lines.append("type \(targetType.rawValue)")
        lines.append("tag \(tagName)")
        if let tagger = tagger {
            lines.append("tagger \(tagger.formatted)")
        }
        lines.append("")
        lines.append(message)

        return Data(lines.joined(separator: "\n").utf8)
    }
}
