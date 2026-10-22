import Foundation
import Darwin

/// What the Mac can and cannot promise about erasing data, shown next to the shredder.
public struct ShredConditions: Sendable, Equatable {
    /// FileVault encrypts the whole disk: old blocks that linger are unreadable without the key.
    public var fileVaultOn: Bool?
    public var solidState: Bool?
    /// Local Time Machine snapshots keep their own copy of files that existed when they were taken.
    public var localSnapshots: Int

    public static func current() -> ShredConditions {
        let fileVault = Shell.run("/usr/bin/fdesetup", ["isactive"], timeout: 15).output?.trimmingCharacters(in: .whitespacesAndNewlines)
        var solidState: Bool?
        if let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 15).output?.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any] {
            solidState = plist["SolidState"] as? Bool
        }
        let snapshots = (Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15).output ?? "")
            .split(separator: "\n").filter { $0.contains("com.apple") }.count
        return ShredConditions(fileVaultOn: fileVault.map { $0 == "true" }, solidState: solidState, localSnapshots: snapshots)
    }
}

public enum ShredPasses: Int, CaseIterable, Sendable, Identifiable {
    /// One pass of random data: as good as any number on modern drives.
    case one = 1
    /// Random, random, zeros: for people who want the traditional ritual.
    case three = 3

    public var id: Int { rawValue }
}

public struct ShredReport: Sendable {
    public var shredded: [URL] = []
    public var bytesOverwritten: Int64 = 0
    public var failures: [RemovalReport.Failure] = []
    public var cancelled = false
    /// Files macOS had stored compressed: writing to them puts the new bytes in new blocks, so
    /// the old compressed copy is not overwritten (FileVault still keeps it unreadable).
    public var compressedFiles = 0
}

/// What the test hook sees for one file, after its last pass and before truncation.
public struct ShredInspection: Sendable {
    public let name: String
    public let contents: Data
    /// Extended attributes still on the file at that point (they should all be gone).
    public let remainingAttributes: [String]
}

/// Overwrites files in place, flushes the overwrite all the way to the drive, truncates them,
/// gives them a random name and only then unlinks them. Folders are shredded file by file and
/// then removed bottom-up. Symbolic links are removed, never followed.
///
/// The walk never resolves a path string after the safety check: it works on open folder
/// handles (`openat`, `fstatat`, `renameat`, `unlinkat`) and re-checks each opened file with
/// `fstat`, so swapping a folder for a symlink mid-shred cannot redirect it anywhere else.
/// Extended attributes, including the resource fork, are overwritten and removed too.
///
/// Honest limits, shown in the UI: on an SSD with APFS, copy-on-write, clones, snapshots and
/// the drive's own wear-levelling can leave old blocks that no overwrite reaches. FileVault is
/// what makes those unreadable.
public struct Shredder: Sendable {
    public let environment: ScanEnvironment
    private let safetyGuard: SafetyGuard

    public init(environment: ScanEnvironment) {
        self.environment = environment
        self.safetyGuard = SafetyGuard(environment: environment)
    }

    /// Total bytes that will be overwritten, for the confirmation.
    public static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + DiskScanner.measure($1).bytes }
    }

    /// - Parameter inspect: test hook, called for each file after its last overwrite pass and
    ///   attribute wipe, before truncation, with what the file then holds.
    public func shred(_ urls: [URL], passes: ShredPasses, control: ScanControl = ScanControl(),
                      inspect: ((ShredInspection) -> Void)? = nil) -> ShredReport {
        var report = ShredReport()
        for url in urls {
            if control.isCancelled { report.cancelled = true; break }
            do {
                try safetyGuard.validate(url, purpose: .shred)
                // The guard resolved the parent; from here on everything is relative to it.
                let resolved = SafetyGuard.resolveParent(of: url)
                let parent = open(resolved.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard parent >= 0 else { throw ShredError(path: url.path, reason: String(cString: strerror(errno))) }
                defer { close(parent) }
                try shredEntry(named: resolved.lastPathComponent, in: parent, passes: passes, control: control,
                               report: &report, inspect: inspect)
                if control.isCancelled { report.cancelled = true; break }
                report.shredded.append(url)
            } catch {
                report.failures.append(.init(url: url, message: Remover.describe(error)))
            }
        }
        return report
    }

    private func shredEntry(named name: String, in parent: Int32, passes: ShredPasses, control: ScanControl,
                            report: inout ShredReport, inspect: ((ShredInspection) -> Void)?) throws {
        func fail(_ reason: String? = nil) -> ShredError { ShredError(path: name, reason: reason ?? String(cString: strerror(errno))) }
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail() }

        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            // Only the link goes; whatever it points to is left alone.
            guard unlinkat(parent, name, 0) == 0 else { throw fail() }

        case S_IFDIR:
            let dir = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard dir >= 0 else { throw fail() }
            var opened = stat()
            guard fstat(dir, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
                close(dir); throw fail("it changed while being shredded")
            }
            for child in Self.entries(of: dir) {
                if control.isCancelled { close(dir); return }
                do { try shredEntry(named: child, in: dir, passes: passes, control: control, report: &report, inspect: inspect) }
                catch { close(dir); throw error }
            }
            close(dir)
            let hidden = try scramble(name, in: parent)
            guard unlinkat(parent, hidden, AT_REMOVEDIR) == 0 else { throw fail() }

        case S_IFREG:
            if st.st_nlink > 1 { throw fail("it has other hard links; overwriting it would destroy them too") }
            let fd = openat(parent, name, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { throw fail() }
            defer { close(fd) }
            // The file opened must be the file checked: same device, inode, still one link.
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == st.st_dev,
                  opened.st_ino == st.st_ino, opened.st_nlink == 1 else { throw fail("it changed while being shredded") }
            if opened.st_flags & UInt32(UF_COMPRESSED) != 0 { report.compressedFiles += 1 }

            report.bytesOverwritten += try overwrite(fd, size: Int64(opened.st_size), passes: passes, control: control, name: name)
            if control.isCancelled { return }
            try wipeAttributes(fd, name: name)
            if let inspect {
                inspect(ShredInspection(name: name, contents: Self.read(fd, size: Int(opened.st_size)),
                                        remainingAttributes: Self.attributeNames(fd)))
            }
            guard ftruncate(fd, 0) == 0 else { throw fail() }
            _ = fcntl(fd, F_FULLFSYNC)
            let hidden = try scramble(name, in: parent)
            guard unlinkat(parent, hidden, 0) == 0 else { throw fail() }

        default:
            throw fail("it is not a regular file or folder")
        }
    }

    /// Writes every byte of the file `passes` times, forcing each pass onto the drive with
    /// F_FULLFSYNC (a plain fsync can leave it in the drive's cache).
    private func overwrite(_ fd: Int32, size: Int64, passes: ShredPasses, control: ScanControl, name: String) throws -> Int64 {
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var written: Int64 = 0
        let plan: [Bool] = passes == .one ? [true] : [true, true, false]   // true = random, false = zeros
        for random in plan {
            if !random { memset(buffer, 0, chunk) }
            var offset: Int64 = 0
            while offset < size {
                if control.isCancelled { return written }
                let count = Int(min(Int64(chunk), size - offset))
                if random { arc4random_buf(buffer, count) }
                let result = pwrite(fd, buffer, count, off_t(offset))
                guard result > 0 else { throw ShredError(path: name, reason: String(cString: strerror(errno))) }
                offset += Int64(result)
                written += Int64(result)
                control.record(files: 0, bytes: Int64(result), path: name)
            }
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                throw ShredError(path: name, reason: "the drive did not confirm the overwrite")
            }
        }
        control.record(files: 1, bytes: 0, path: name)
        return written
    }

    /// Extended attributes (Finder tags, quarantine, the resource fork…) can hold data of their
    /// own: each is rewritten with random bytes of the same length, then removed.
    private func wipeAttributes(_ fd: Int32, name: String) throws {
        for attribute in Self.attributeNames(fd) where !Self.systemAttributes.contains(attribute) {
            let length = fgetxattr(fd, attribute, nil, 0, 0, 0)
            if length > 0 {
                var noise = [UInt8](repeating: 0, count: length)
                arc4random_buf(&noise, length)
                _ = fsetxattr(fd, attribute, noise, length, 0, 0)
            }
            guard fremovexattr(fd, attribute, 0) == 0 || errno == ENOATTR else {
                throw ShredError(path: name, reason: "could not remove its \(attribute) attribute")
            }
        }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    /// Tags macOS attaches and protects itself. `com.apple.provenance` records which app made the
    /// file, not anything from its contents, and apps cannot remove it; it goes with the file.
    static let systemAttributes: Set<String> = ["com.apple.provenance"]

    static func attributeNames(_ fd: Int32) -> [String] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard flistxattr(fd, &buffer, size, 0) > 0 else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    private static func read(_ fd: Int32, size: Int) -> Data {
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, size, 0) }
        return count >= 0 ? data.prefix(count) : Data()
    }

    private static func entries(of dir: Int32) -> [String] {
        let copy = dup(dir)
        guard copy >= 0, let stream = fdopendir(copy) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Renames to a random name in the same folder, so the original name does not linger.
    private func scramble(_ name: String, in parent: Int32) throws -> String {
        let hidden = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard renameat(parent, name, parent, hidden) == 0 else { throw ShredError(path: name, reason: String(cString: strerror(errno))) }
        return hidden
    }
}

public struct ShredError: Error, LocalizedError, Sendable {
    public let path: String
    public let reason: String
    public var errorDescription: String? { reason }
}
