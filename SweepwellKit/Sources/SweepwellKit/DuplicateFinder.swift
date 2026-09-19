import Foundation
import CryptoKit

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let modified: Date
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    /// Space one copy occupies on disk.
    public let size: Int64
    /// Oldest first: the first file is the presumed original.
    public let files: [DuplicateFile]
    public var wastedBytes: Int64 { size * Int64(files.count - 1) }

    public init(id: String, size: Int64, files: [DuplicateFile]) {
        self.id = id
        self.size = size
        self.files = files
    }
}

public enum DuplicateFinder {
    private struct Candidate {
        let path: String
        let allocated: Int64
        let modified: Date
    }

    /// Three passes, cheapest first: group by byte length, then by a hash of the first 64 KB,
    /// and only fully hash the files that still collide. Most files drop out before any
    /// real I/O happens.
    public static func find(in roots: [URL], minimumSize: Int64, control: ScanControl) -> [DuplicateGroup] {
        var bySize: [Int64: [Candidate]] = [:]
        var seenFileIDs = Set<UInt64>()
        for root in roots {
            let path = root.resolvingSymlinksInPath().path
            DiskScanner.walk(path: path, device: DiskScanner.deviceID(of: path), control: control,
                             skipPackages: true, skipHidden: true) { directory, entry in
                guard entry.logicalSize >= minimumSize else { return }
                // Overlapping roots would otherwise pair a file with itself.
                guard seenFileIDs.insert(entry.fileID).inserted else { return }
                bySize[entry.logicalSize, default: []].append(
                    Candidate(path: DiskScanner.join(directory, entry.name),
                              allocated: entry.allocatedSize, modified: entry.modified))
            }
        }

        let sizeGroups = bySize.values.filter { $0.count > 1 }
        let lock = NSLock()
        var groups: [DuplicateGroup] = []
        DispatchQueue.concurrentPerform(iterations: sizeGroups.count) { i in
            if control.isCancelled { return }
            let found = confirm(sizeGroups[i], control: control)
            if !found.isEmpty { lock.withLock { groups += found } }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    private static func confirm(_ candidates: [Candidate], control: ScanControl) -> [DuplicateGroup] {
        var byHead: [Data: [Candidate]] = [:]
        for candidate in candidates {
            guard let head = hash(candidate.path, limit: 64 * 1024, control: control) else { continue }
            byHead[head, default: []].append(candidate)
        }
        var result: [DuplicateGroup] = []
        for headGroup in byHead.values where headGroup.count > 1 {
            var byContent: [Data: [Candidate]] = [:]
            for candidate in headGroup {
                guard let digest = hash(candidate.path, limit: nil, control: control) else { continue }
                byContent[digest, default: []].append(candidate)
            }
            for (digest, matches) in byContent where matches.count > 1 {
                let files = matches.sorted { ($0.modified, $0.path) < ($1.modified, $1.path) }
                    .map { DuplicateFile(url: URL(fileURLWithPath: $0.path), modified: $0.modified) }
                result.append(DuplicateGroup(id: digest.map { String(format: "%02x", $0) }.joined(),
                                             size: matches[0].allocated, files: files))
            }
        }
        return result
    }

    private static func hash(_ path: String, limit: Int?, control: ScanControl) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            if control.isCancelled { return nil }
            let chunk = try? handle.read(upToCount: min(remaining, 1 << 20))
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }
}
