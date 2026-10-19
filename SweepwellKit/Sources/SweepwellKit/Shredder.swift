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
        let fileVault = Shell.run("/usr/bin/fdesetup", ["isactive"]).output?.trimmingCharacters(in: .whitespacesAndNewlines)
        var solidState: Bool?
        if let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/"]).output?.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any] {
            solidState = plist["SolidState"] as? Bool
        }
        let snapshots = (Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output ?? "")
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
}

/// Overwrites files in place, flushes the overwrite all the way to the drive, truncates them,
/// gives them a random name and only then unlinks them. Folders are shredded file by file and
/// then removed bottom-up. Symbolic links are removed, never followed.
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

    /// - Parameter inspect: test hook, called with each file after its last overwrite pass and
    ///   before it is truncated, renamed and removed, so a test can read what reached the disk.
    public func shred(_ urls: [URL], passes: ShredPasses, control: ScanControl = ScanControl(),
                      inspect: ((String) -> Void)? = nil) -> ShredReport {
        var report = ShredReport()
        for url in urls {
            if control.isCancelled { report.cancelled = true; break }
            do {
                try safetyGuard.validate(url, purpose: .shred)
                let path = SafetyGuard.resolveParent(of: url).path
                try shredItem(at: path, passes: passes, control: control, report: &report, inspect: inspect)
                if control.isCancelled { report.cancelled = true; break }
                report.shredded.append(url)
            } catch {
                report.failures.append(.init(url: url, message: Remover.describe(error)))
            }
        }
        return report
    }

    private func shredItem(at path: String, passes: ShredPasses, control: ScanControl, report: inout ShredReport,
                           inspect: ((String) -> Void)?) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            // Only the link goes; whatever it points to is left alone.
            guard unlink(path) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        case S_IFDIR:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for name in names {
                if control.isCancelled { return }
                try shredItem(at: path + "/" + name, passes: passes, control: control, report: &report, inspect: inspect)
            }
            let hidden = try scramble(path)
            guard rmdir(hidden) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        case S_IFREG:
            if st.st_nlink > 1 {
                throw ShredError(path: path, reason: "it has other hard links; overwriting it would destroy them too")
            }
            report.bytesOverwritten += try overwrite(path, size: Int64(st.st_size), passes: passes, control: control, inspect: inspect)
            if control.isCancelled { return }
            let hidden = try scramble(path)
            guard unlink(hidden) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        default:
            throw ShredError(path: path, reason: "it is not a regular file or folder")
        }
    }

    /// Writes every byte of the file `passes` times, forcing each pass onto the drive with
    /// F_FULLFSYNC (a plain fsync can leave it in the drive's cache), then truncates it.
    private func overwrite(_ path: String, size: Int64, passes: ShredPasses, control: ScanControl,
                           inspect: ((String) -> Void)?) throws -> Int64 {
        let fd = open(path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        defer { close(fd) }
        // Ask for the writes to go straight to the file's existing blocks, not through the cache.
        _ = fcntl(fd, F_NOCACHE, 1)

        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var written: Int64 = 0
        let plan: [Bool] = passes == .one ? [true] : [true, true, false]   // true = random, false = zeros
        for random in plan {
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
            if !random { memset(buffer, 0, chunk) }
            var remaining = size
            while remaining > 0 {
                if control.isCancelled { return written }
                let count = Int(min(Int64(chunk), remaining))
                if random { arc4random_buf(buffer, count) }
                let result = write(fd, buffer, count)
                guard result > 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
                remaining -= Int64(result)
                written += Int64(result)
                control.record(files: 0, bytes: Int64(result), path: path)
            }
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                throw ShredError(path: path, reason: "the drive did not confirm the overwrite")
            }
        }
        inspect?(path)
        guard ftruncate(fd, 0) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        _ = fcntl(fd, F_FULLFSYNC)
        control.record(files: 1, bytes: 0, path: path)
        return written
    }

    /// Renames to a random name in the same folder, so the original name does not linger in the
    /// directory either.
    private func scramble(_ path: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let hidden = directory + "/" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard rename(path, hidden) == 0 else { throw ShredError(path: path, reason: String(cString: strerror(errno))) }
        return hidden
    }
}

public struct ShredError: Error, LocalizedError, Sendable {
    public let path: String
    public let reason: String
    public var errorDescription: String? { reason }
}
