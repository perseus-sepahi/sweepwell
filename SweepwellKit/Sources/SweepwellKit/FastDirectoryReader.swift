import Foundation
import Darwin

/// One entry of a directory listing, with the metadata every Sweepwell module needs.
public struct DirEntry: Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }

    public var name: String
    public var kind: Kind
    /// Bytes actually occupied on disk (what deleting the file gives back).
    public var allocatedSize: Int64
    /// Logical length of the file (used to pair up duplicate candidates).
    public var logicalSize: Int64
    public var modified: Date
    public var accessed: Date
    public var fileID: UInt64
    public var linkCount: UInt32
    public var deviceID: Int32
}

public struct DirectoryReadError: Error, Sendable {
    public let path: String
    public let code: Int32
    public var isPermissionDenied: Bool { code == EPERM || code == EACCES }
}

/// Reads a whole directory with `getattrlistbulk(2)`: names, types, sizes and dates for
/// hundreds of entries per syscall instead of one `stat` per file.
public enum FastDirectoryReader {
    // <sys/attr.h> bits, spelled out as UInt32 so the masks combine without casts.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnAccTime: UInt32 = 0x0000_1000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private static let vnodeRegular: UInt32 = 1
    private static let vnodeDirectory: UInt32 = 2
    private static let vnodeSymlink: UInt32 = 5

    private static let bufferSize = 128 * 1024

    public static func read(_ path: String) throws -> [DirEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw DirectoryReadError(path: path, code: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnError | cmnName | cmnDevID | cmnObjType
            | cmnModTime | cmnAccTime | cmnFileID
        request.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [DirEntry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                // Filesystems without bulk support (some network mounts) get the slow path.
                if entries.isEmpty, errno == ENOTSUP || errno == EINVAL {
                    return try readSlow(path)
                }
                throw DirectoryReadError(path: path, code: errno)
            }
            entries.reserveCapacity(entries.count + Int(count))
            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = parse(entryStart + 4) { entries.append(entry) }
                entryStart += length
            }
        }
        return entries
    }

    /// Fields arrive in the bit order of the request masks: returned-attrs, error, then the
    /// common group low bit → high bit, then the file group. Anything not flagged in
    /// `returned` is absent from the buffer, so every read is guarded by its bit.
    private static func parse(_ start: UnsafeRawPointer) -> DirEntry? {
        var p = start
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & cmnError != 0 {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }
        guard returned.commonattr & cmnName != 0 else { return nil }
        let nameRef = p.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (p + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        p += MemoryLayout<attrreference_t>.size

        var deviceID: Int32 = 0
        if returned.commonattr & cmnDevID != 0 {
            deviceID = p.loadUnaligned(as: Int32.self)
            p += 4
        }
        var objType: UInt32 = 0
        if returned.commonattr & cmnObjType != 0 {
            objType = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        var modified = Date.distantPast
        if returned.commonattr & cmnModTime != 0 {
            modified = date(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        var accessed = Date.distantPast
        if returned.commonattr & cmnAccTime != 0 {
            accessed = date(p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        var fileID: UInt64 = 0
        if returned.commonattr & cmnFileID != 0 {
            fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }

        var linkCount: UInt32 = 1
        if returned.fileattr & fileLinkCount != 0 {
            linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        var logicalSize: Int64 = 0
        if returned.fileattr & fileTotalSize != 0 {
            logicalSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        var allocatedSize: Int64 = 0
        if returned.fileattr & fileAllocSize != 0 {
            allocatedSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }

        let kind: DirEntry.Kind
        switch objType {
        case vnodeRegular: kind = .file
        case vnodeDirectory: kind = .directory
        case vnodeSymlink: kind = .symlink
        default: kind = .other
        }
        // The file group is also filled in for symlinks (length of the target path).
        if kind != .file {
            logicalSize = 0
            allocatedSize = 0
        }
        return DirEntry(name: name, kind: kind, allocatedSize: allocatedSize, logicalSize: logicalSize,
                        modified: modified, accessed: accessed, fileID: fileID,
                        linkCount: linkCount, deviceID: deviceID)
    }

    private static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000)
    }

    /// `lstat`-per-entry fallback with the same output shape.
    static func readSlow(_ path: String) throws -> [DirEntry] {
        guard let dir = opendir(path) else { throw DirectoryReadError(path: path, code: errno) }
        defer { closedir(dir) }
        var entries: [DirEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard lstat(path + "/" + name, &st) == 0 else { continue }
            let kind: DirEntry.Kind
            switch st.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            let isFile = kind == .file
            entries.append(DirEntry(name: name, kind: kind,
                                    allocatedSize: isFile ? Int64(st.st_blocks) * 512 : 0,
                                    logicalSize: isFile ? Int64(st.st_size) : 0,
                                    modified: date(st.st_mtimespec), accessed: date(st.st_atimespec),
                                    fileID: UInt64(st.st_ino), linkCount: UInt32(st.st_nlink),
                                    deviceID: st.st_dev))
        }
        return entries
    }
}
