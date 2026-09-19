import Foundation

/// Shared between a running scan and the UI: the scan bumps counters, the UI polls them and
/// may flip `cancel()`. A lock instead of an actor so the hot loop never suspends.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var files = 0
    private var bytes: Int64 = 0
    private var denied = 0
    private var path = ""
    private var seenHardLinks = Set<UInt64>()

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public var filesScanned: Int { lock.withLock { files } }
    public var bytesScanned: Int64 { lock.withLock { bytes } }
    /// Directories that could not be opened (usually missing Full Disk Access).
    public var inaccessibleDirectories: Int { lock.withLock { denied } }
    public var currentPath: String { lock.withLock { path } }

    public func cancel() { lock.withLock { cancelled = true } }

    func record(files newFiles: Int, bytes newBytes: Int64, path newPath: String) {
        lock.withLock {
            files += newFiles
            bytes += newBytes
            path = newPath
        }
    }

    func recordDenied() { lock.withLock { denied += 1 } }

    /// A file with several hard links is charged to the first link seen and free afterwards.
    func claimHardLink(_ fileID: UInt64) -> Bool {
        lock.withLock { seenHardLinks.insert(fileID).inserted }
    }
}

/// A folder (or big file) in the Space Lens tree.
public final class DiskNode: Identifiable, @unchecked Sendable {
    public let name: String
    public let isDirectory: Bool
    /// Stand-in for all the files of a folder that are too small to list one by one.
    public let isAggregate: Bool
    public internal(set) var size: Int64
    public internal(set) var fileCount: Int
    public internal(set) var children: [DiskNode]
    public internal(set) weak var parent: DiskNode?
    private let rootPath: String?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, isAggregate: Bool = false, size: Int64 = 0,
         fileCount: Int = 0, children: [DiskNode] = [], rootPath: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.size = size
        self.fileCount = fileCount
        self.children = children
        self.rootPath = rootPath
    }

    public var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        if isAggregate { return parent.path }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Drops a child after it was deleted, fixing up every size on the way to the root.
    public func removeChild(_ child: DiskNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var node: DiskNode? = self
        while let current = node {
            current.size -= child.size
            current.fileCount -= child.fileCount
            node = current.parent
        }
    }
}

public struct LargeFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let accessed: Date
    public let isPackage: Bool
}

public enum DiskScanner {
    /// Bundles that Finder shows as one file; scans treat them the same way.
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xcarchive", "xcodeproj", "xcworkspace",
        "photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "imovielibrary", "fcpbundle",
        "logicx", "band", "pvm", "vmwarevm", "utm", "sparsebundle", "dSYM", "playground",
        "rtfd", "key", "pages", "numbers", "download", "scptd", "lproj", "pkg", "mpkg"
    ]

    /// Media libraries are one "file" to the user but never something to offer for deletion.
    static let libraryExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "imovielibrary"
    ]

    /// Files below this get folded into one "smaller files" node per folder, which keeps a
    /// multi-million-file home folder at a few hundred thousand nodes.
    public static let defaultNodeThreshold: Int64 = 1 << 20

    // MARK: Space Lens tree

    public static func scanTree(root: URL, control: ScanControl,
                                nodeThreshold: Int64 = defaultNodeThreshold) -> DiskNode {
        let path = root.resolvingSymlinksInPath().path
        let node = DiskNode(name: root.lastPathComponent, isDirectory: true, rootPath: path)
        let device = deviceID(of: path)
        fill(node, path: path, depth: 0, device: device, control: control, threshold: nodeThreshold)
        return node
    }

    private static func fill(_ node: DiskNode, path: String, depth: Int, device: Int32?,
                             control: ScanControl, threshold: Int64) {
        if control.isCancelled { return }
        let entries: [DirEntry]
        do { entries = try FastDirectoryReader.read(path) } catch {
            control.recordDenied()
            return
        }

        var children: [DiskNode] = []
        var directories: [(DiskNode, String)] = []
        var smallBytes: Int64 = 0
        var smallCount = 0
        var fileBytes: Int64 = 0
        var fileCount = 0

        for entry in entries {
            switch entry.kind {
            case .directory:
                // A different device ID means a mount point: another volume, not our bytes.
                if let device, entry.deviceID != device { continue }
                let child = DiskNode(name: entry.name, isDirectory: true)
                child.parent = node
                directories.append((child, join(path, entry.name)))
            case .file:
                if entry.linkCount > 1, !control.claimHardLink(entry.fileID) { continue }
                fileBytes += entry.allocatedSize
                fileCount += 1
                if entry.allocatedSize >= threshold {
                    let child = DiskNode(name: entry.name, isDirectory: false,
                                         size: entry.allocatedSize, fileCount: 1)
                    child.parent = node
                    children.append(child)
                } else {
                    smallBytes += entry.allocatedSize
                    smallCount += 1
                }
            case .symlink, .other:
                continue
            }
        }
        control.record(files: fileCount, bytes: fileBytes, path: path)

        // Fan out near the top, where folders like ~/Library have hundreds of heavy children;
        // deeper down the work per folder is too small to be worth a hop.
        if depth < 2, directories.count > 1 {
            DispatchQueue.concurrentPerform(iterations: directories.count) { i in
                fill(directories[i].0, path: directories[i].1, depth: depth + 1, device: device,
                     control: control, threshold: threshold)
            }
        } else {
            for (child, childPath) in directories {
                fill(child, path: childPath, depth: depth + 1, device: device,
                     control: control, threshold: threshold)
            }
        }

        for (child, _) in directories where child.size > 0 || child.fileCount > 0 {
            children.append(child)
        }
        if smallCount > 0 {
            let name = smallCount == 1 ? "1 smaller file" : "\(smallCount) smaller files"
            let aggregate = DiskNode(name: name, isDirectory: false, isAggregate: true,
                                     size: smallBytes, fileCount: smallCount)
            aggregate.parent = node
            children.append(aggregate)
        }
        children.sort { $0.size > $1.size }
        node.children = children
        node.size = fileBytes + directories.reduce(0) { $0 + $1.0.size }
        node.fileCount = fileCount + directories.reduce(0) { $0 + $1.0.fileCount }
    }

    // MARK: Sizing

    public struct Measurement: Sendable, Equatable {
        public var bytes: Int64 = 0
        public var files: Int = 0
    }

    /// Allocated size of a file or of everything below a folder. Stays on one volume.
    public static func measure(_ url: URL, control: ScanControl = ScanControl()) -> Measurement {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return Measurement() }
        if st.st_mode & S_IFMT != S_IFDIR {
            let bytes = (st.st_mode & S_IFMT == S_IFREG) ? Int64(st.st_blocks) * 512 : 0
            return Measurement(bytes: bytes, files: 1)
        }
        var total = Measurement()
        walk(path: path, device: st.st_dev, control: control, skipPackages: false) { _, entry in
            total.bytes += entry.allocatedSize
            total.files += 1
        }
        return total
    }

    /// Depth-first, single-threaded visit of every regular file below `path`.
    /// With `skipPackages`, a bundle is reported to `onPackage` and not descended into.
    static func walk(path: String, device: Int32?, control: ScanControl, skipPackages: Bool,
                     skipHidden: Bool = false,
                     onPackage: ((String, DirEntry) -> Void)? = nil,
                     onFile: (String, DirEntry) -> Void) {
        var stack = [path]
        while let current = stack.popLast() {
            if control.isCancelled { return }
            let entries: [DirEntry]
            do { entries = try FastDirectoryReader.read(current) } catch {
                control.recordDenied()
                continue
            }
            var files = 0
            var bytes: Int64 = 0
            for entry in entries {
                if skipHidden, entry.name.hasPrefix(".") { continue }
                switch entry.kind {
                case .directory:
                    if let device, entry.deviceID != device { continue }
                    if skipPackages, isPackageName(entry.name) {
                        onPackage?(current, entry)
                    } else {
                        stack.append(join(current, entry.name))
                    }
                case .file:
                    if entry.linkCount > 1, !control.claimHardLink(entry.fileID) { continue }
                    files += 1
                    bytes += entry.allocatedSize
                    onFile(current, entry)
                case .symlink, .other:
                    continue
                }
            }
            control.record(files: files, bytes: bytes, path: current)
        }
    }

    // MARK: Large & old files

    /// Files (and bundles) of at least `minimumSize` below the given folders.
    public static func findLargeFiles(in roots: [URL], minimumSize: Int64,
                                      control: ScanControl) -> [LargeFile] {
        let lock = NSLock()
        var found: [LargeFile] = []
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let rootPath = roots[i].resolvingSymlinksInPath().path
            var local: [LargeFile] = []
            var packages: [(String, DirEntry)] = []
            walk(path: rootPath, device: deviceID(of: rootPath), control: control, skipPackages: true,
                 skipHidden: true, onPackage: { dir, entry in packages.append((dir, entry)) },
                 onFile: { dir, entry in
                     guard entry.allocatedSize >= minimumSize else { return }
                     local.append(LargeFile(url: URL(fileURLWithPath: join(dir, entry.name)),
                                            size: entry.allocatedSize, modified: entry.modified,
                                            accessed: entry.accessed, isPackage: false))
                 })
            for (dir, entry) in packages {
                if control.isCancelled { break }
                let ext = (entry.name as NSString).pathExtension
                if libraryExtensions.contains(ext) { continue }
                let url = URL(fileURLWithPath: join(dir, entry.name), isDirectory: true)
                let size = measure(url, control: control).bytes
                guard size >= minimumSize else { continue }
                local.append(LargeFile(url: url, size: size, modified: entry.modified,
                                       accessed: entry.accessed, isPackage: true))
            }
            lock.withLock { found.append(contentsOf: local) }
        }
        return found.sorted { $0.size > $1.size }
    }

    // MARK: Helpers

    static func isPackageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && packageExtensions.contains(ext)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func deviceID(of path: String) -> Int32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : nil
    }
}
