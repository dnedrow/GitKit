import Foundation

// MARK: - Core Errors

/// Errors that can occur during GitKit operations.
public enum GKError: Error, CustomStringConvertible {
    case repositoryNotFound(path: String)
    case repositoryAlreadyExists(path: String)
    case invalidObject(String)
    case invalidObjectType(String)
    case objectNotFound(GKObjectID)
    case invalidReference(String)
    case referenceNotFound(String)
    case invalidHead(String)
    case corruptedRepository(String)
    case indexError(String)
    case mergeConflict(paths: [String])
    case detachedHead
    case branchAlreadyExists(String)
    case branchNotFound(String)
    case remoteNotFound(String)
    case networkError(String)
    case protocolError(String)
    case authenticationRequired
    case invalidConfiguration(String)
    case ioError(String)
    case zlibError(String)
    case packfileError(String)
    case invalidTree(String)
    case invalidCommit(String)
    case invalidTag(String)
    case checkoutConflict(paths: [String])
    case uncommittedChanges
    case invalidDiff(String)

    public var description: String {
        switch self {
        case .repositoryNotFound(let path):
            return "Repository not found at path: \(path)"
        case .repositoryAlreadyExists(let path):
            return "Repository already exists at path: \(path)"
        case .invalidObject(let msg):
            return "Invalid object: \(msg)"
        case .invalidObjectType(let type):
            return "Invalid object type: \(type)"
        case .objectNotFound(let oid):
            return "Object not found: \(oid.hex)"
        case .invalidReference(let ref):
            return "Invalid reference: \(ref)"
        case .referenceNotFound(let ref):
            return "Reference not found: \(ref)"
        case .invalidHead(let msg):
            return "Invalid HEAD: \(msg)"
        case .corruptedRepository(let msg):
            return "Corrupted repository: \(msg)"
        case .indexError(let msg):
            return "Index error: \(msg)"
        case .mergeConflict(let paths):
            return "Merge conflict in: \(paths.joined(separator: ", "))"
        case .detachedHead:
            return "HEAD is detached"
        case .branchAlreadyExists(let name):
            return "Branch already exists: \(name)"
        case .branchNotFound(let name):
            return "Branch not found: \(name)"
        case .remoteNotFound(let name):
            return "Remote not found: \(name)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .protocolError(let msg):
            return "Protocol error: \(msg)"
        case .authenticationRequired:
            return "Authentication required"
        case .invalidConfiguration(let msg):
            return "Invalid configuration: \(msg)"
        case .ioError(let msg):
            return "I/O error: \(msg)"
        case .zlibError(let msg):
            return "Zlib error: \(msg)"
        case .packfileError(let msg):
            return "Packfile error: \(msg)"
        case .invalidTree(let msg):
            return "Invalid tree: \(msg)"
        case .invalidCommit(let msg):
            return "Invalid commit: \(msg)"
        case .invalidTag(let msg):
            return "Invalid tag: \(msg)"
        case .checkoutConflict(let paths):
            return "Checkout conflict in: \(paths.joined(separator: ", "))"
        case .uncommittedChanges:
            return "Uncommitted changes in working directory"
        case .invalidDiff(let msg):
            return "Invalid diff: \(msg)"
        }
    }
}
