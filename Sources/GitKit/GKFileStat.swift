import Foundation

// MARK: - File Stat Cache

/// Cached filesystem metadata for an index entry, mirroring the stat fields
/// stored in the Git index. Used to detect working-tree modifications without
/// re-hashing file contents: if a file's current stat matches the cached value,
/// the file is treated as unchanged.
///
/// All fields are 32-bit to match the on-disk index layout; 64-bit platform
/// values are truncated to their low 32 bits exactly as Git does.
public struct GKFileStat: Sendable, Equatable {
    public var ctimeSeconds: UInt32
    public var ctimeNanoseconds: UInt32
    public var mtimeSeconds: UInt32
    public var mtimeNanoseconds: UInt32
    public var dev: UInt32
    public var ino: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var fileSize: UInt32

    public init(
        ctimeSeconds: UInt32 = 0,
        ctimeNanoseconds: UInt32 = 0,
        mtimeSeconds: UInt32 = 0,
        mtimeNanoseconds: UInt32 = 0,
        dev: UInt32 = 0,
        ino: UInt32 = 0,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        fileSize: UInt32 = 0
    ) {
        self.ctimeSeconds = ctimeSeconds
        self.ctimeNanoseconds = ctimeNanoseconds
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.dev = dev
        self.ino = ino
        self.uid = uid
        self.gid = gid
        self.fileSize = fileSize
    }

    /// The all-zero stat, used when no filesystem metadata is known. An entry
    /// carrying `.empty` is always verified by content during status.
    public static let empty = GKFileStat()

    /// Whether this stat carries no usable metadata (e.g. a legacy entry).
    public var isEmpty: Bool { self == .empty }

    // MARK: - Reading from the filesystem

    /// Reads stat metadata for the file at `url` via `lstat`, or returns `nil`
    /// if the file does not exist or cannot be stat'd.
    ///
    /// This is the single place that touches platform `stat` fields, isolating
    /// the Darwin/Linux `timespec` naming differences.
    public static func read(at url: URL) -> GKFileStat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }

        #if canImport(Darwin)
        let mtime = info.st_mtimespec
        let ctime = info.st_ctimespec
        #else
        let mtime = info.st_mtim
        let ctime = info.st_ctim
        #endif

        return GKFileStat(
            ctimeSeconds: UInt32(truncatingIfNeeded: Int(ctime.tv_sec)),
            ctimeNanoseconds: UInt32(truncatingIfNeeded: Int(ctime.tv_nsec)),
            mtimeSeconds: UInt32(truncatingIfNeeded: Int(mtime.tv_sec)),
            mtimeNanoseconds: UInt32(truncatingIfNeeded: Int(mtime.tv_nsec)),
            dev: UInt32(truncatingIfNeeded: Int(info.st_dev)),
            ino: UInt32(truncatingIfNeeded: UInt64(info.st_ino)),
            uid: UInt32(truncatingIfNeeded: Int(info.st_uid)),
            gid: UInt32(truncatingIfNeeded: Int(info.st_gid)),
            fileSize: UInt32(truncatingIfNeeded: Int(info.st_size))
        )
    }

    /// Whether `other` represents the same on-disk file state as this entry's
    /// cached stat, considering the fields Git uses to detect modification.
    /// Note: this does not account for racy-clean entries; callers must apply
    /// the index-mtime check separately.
    func matchesWorkingFile(_ other: GKFileStat) -> Bool {
        fileSize == other.fileSize
            && mtimeSeconds == other.mtimeSeconds
            && mtimeNanoseconds == other.mtimeNanoseconds
            && ctimeSeconds == other.ctimeSeconds
            && ctimeNanoseconds == other.ctimeNanoseconds
            && ino == other.ino
            && dev == other.dev
    }

    /// Whether this entry is "racily clean" relative to an index written at
    /// `indexMtimeSeconds`: a file whose mtime is at or after the index's own
    /// mtime could have been modified within the same timestamp tick and must
    /// be verified by content.
    func isRacyClean(indexMtimeSeconds: UInt32) -> Bool {
        mtimeSeconds >= indexMtimeSeconds
    }
}
