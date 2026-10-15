import Foundation

public enum JunkKind: String, CaseIterable, Identifiable, Sendable {
    case userCaches, userLogs, xcode, developerCaches, incompleteDownloads, mailDownloads, iosBackups, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCaches: "App Caches"
        case .userLogs: "Logs & Crash Reports"
        case .xcode: "Xcode Junk"
        case .developerCaches: "Developer Tool Caches"
        case .incompleteDownloads: "Incomplete Downloads"
        case .mailDownloads: "Mail Downloads"
        case .iosBackups: "iOS Device Backups"
        case .trash: "Trash"
        }
    }

    public var summary: String {
        switch self {
        case .userCaches: "Temporary data apps keep to start faster. Apps rebuild what they need."
        case .userLogs: "Diagnostic logs and crash reports that are only useful when chasing a bug."
        case .xcode: "Build products, device support files and simulator caches Xcode can recreate."
        case .developerCaches: "Package manager downloads (npm, Homebrew, pip, Gradle…) that are fetched again on demand."
        case .incompleteDownloads: "Partial files left behind by interrupted browser downloads."
        case .mailDownloads: "Copies of attachments you opened in Mail. The originals stay in your mailbox."
        case .iosBackups: "Local iPhone and iPad backups. Review carefully: a backup cannot be recreated once the device is gone."
        case .trash: "Items already in your Trash. Removing them is permanent."
        }
    }

    public var symbol: String {
        switch self {
        case .userCaches: "shippingbox"
        case .userLogs: "doc.text.magnifyingglass"
        case .xcode: "hammer"
        case .developerCaches: "terminal"
        case .incompleteDownloads: "arrow.down.circle.dotted"
        case .mailDownloads: "paperclip"
        case .iosBackups: "iphone"
        case .trash: "trash"
        }
    }

    public var removalPurpose: RemovalPurpose { self == .trash ? .trashContents : .junk }
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let size: Int64
    public let fileCount: Int
    public let kind: JunkKind
    /// False for things that are safe to offer but deserve a conscious decision.
    public let selectedByDefault: Bool
    public let note: String?
}

public struct JunkGroup: Identifiable, Sendable {
    public var id: JunkKind { kind }
    public let kind: JunkKind
    public var items: [JunkItem]
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct JunkScanner: Sendable {
    public let environment: ScanEnvironment
    /// Bundle identifiers of running apps; their caches are listed but left unticked.
    public let runningBundleIDs: Set<String>

    public init(environment: ScanEnvironment, runningBundleIDs: Set<String> = []) {
        self.environment = environment
        self.runningBundleIDs = runningBundleIDs
    }

    private struct Candidate {
        let url: URL
        let name: String
        let kind: JunkKind
        var selected = true
        var note: String?
    }

    /// Caches macOS services keep live state in; clearing them causes re-syncs, not savings.
    private static let cacheDenyList: Set<String> = [
        "CloudKit", "com.apple.bird", "com.apple.cloudd", "FamilyCircle", "com.apple.homed",
        "com.apple.HomeKit", "com.apple.ap.adprivacyd", "com.apple.containermanagerd"
    ]

    /// Developer caches, relative to home. Entries below `Library/Caches` are claimed here so
    /// they are not listed a second time as plain app caches.
    private static let developerCaches: [(path: String, name: String, selected: Bool, note: String?)] = [
        (".npm/_cacache", "npm cache", true, nil),
        ("Library/Caches/Yarn", "Yarn cache", true, nil),
        ("Library/Caches/pnpm", "pnpm cache", true, nil),
        (".bun/install/cache", "Bun cache", true, nil),
        ("Library/Caches/pip", "pip cache", true, nil),
        ("Library/Caches/Homebrew", "Homebrew downloads", true, nil),
        ("Library/Caches/CocoaPods", "CocoaPods cache", true, nil),
        ("Library/Caches/org.swift.swiftpm", "Swift Package Manager cache", true, nil),
        ("Library/Caches/go-build", "Go build cache", true, nil),
        ("Library/Caches/ms-playwright", "Playwright browsers", true, nil),
        ("Library/Caches/Cypress", "Cypress binaries", true, nil),
        ("Library/Caches/electron", "Electron downloads", true, nil),
        (".gradle/caches", "Gradle caches", true, nil),
        (".cargo/registry/cache", "Cargo crate downloads", true, nil),
        (".m2/repository", "Maven local repository", false, "Every dependency is downloaded again on the next build.")
    ]

    private static let incompleteExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    /// - Parameter kinds: limit the scan to these categories (nil scans everything); only the
    ///   chosen categories are sized, which is where the time goes.
    public func scan(kinds: Set<JunkKind>? = nil, control: ScanControl = ScanControl()) -> [JunkGroup] {
        var candidates: [Candidate] = []
        candidates += developerCacheCandidates()
        candidates += userCacheCandidates()
        candidates += children(of: "Library/Logs", kind: .userLogs)
        candidates += xcodeCandidates()
        candidates += incompleteDownloadCandidates()
        candidates += children(of: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", kind: .mailDownloads)
        candidates += children(of: "Library/Application Support/MobileSync/Backup", kind: .iosBackups)
            .map { var c = $0; c.selected = false; c.note = "A device backup. Keep it unless you have a newer one."; return c }
        candidates += children(of: ".Trash", kind: .trash, includeHidden: true)
        if let kinds { candidates.removeAll { !kinds.contains($0.kind) } }

        // Sizing is where the time goes, so it is spread over all cores.
        var measured = [DiskScanner.Measurement](repeating: .init(), count: candidates.count)
        measured.withUnsafeMutableBufferPointer { buffer in
            let slots = UnsafeSendableBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                if control.isCancelled { return }
                slots.base[i] = DiskScanner.measure(candidates[i].url, control: control)
            }
        }

        var groups: [JunkKind: [JunkItem]] = [:]
        for (candidate, measurement) in zip(candidates, measured) where measurement.bytes > 0 {
            groups[candidate.kind, default: []].append(
                JunkItem(url: candidate.url, name: candidate.name, size: measurement.bytes,
                         fileCount: measurement.files, kind: candidate.kind,
                         selectedByDefault: candidate.selected, note: candidate.note))
        }
        return JunkKind.allCases.compactMap { kind in
            guard let items = groups[kind], !items.isEmpty else { return nil }
            return JunkGroup(kind: kind, items: items.sorted { $0.size > $1.size })
        }
    }

    // MARK: Candidates

    private func list(_ relativePath: String, includeHidden: Bool = false) -> [URL] {
        let directory = environment.homeRelative(relativePath)
        guard let entries = try? FastDirectoryReader.read(directory.path) else { return [] }
        return entries
            .filter { includeHidden || !$0.name.hasPrefix(".") }
            .map { directory.appendingPathComponent($0.name, isDirectory: $0.kind == .directory) }
    }

    private func children(of relativePath: String, kind: JunkKind, includeHidden: Bool = false) -> [Candidate] {
        list(relativePath, includeHidden: includeHidden)
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { Candidate(url: $0, name: $0.lastPathComponent, kind: kind) }
    }

    private func developerCacheCandidates() -> [Candidate] {
        var result = Self.developerCaches.compactMap { entry -> Candidate? in
            let url = environment.homeRelative(entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Candidate(url: url, name: entry.name, kind: .developerCaches,
                             selected: entry.selected, note: entry.note)
        }
        // ~/.cache is the XDG catch-all used by command-line tools.
        result += list(".cache").map { Candidate(url: $0, name: "\($0.lastPathComponent) (~/.cache)", kind: .developerCaches) }
        return result
    }

    private func userCacheCandidates() -> [Candidate] {
        let claimed = Set(Self.developerCaches.map { environment.homeRelative($0.path).path })
        let ownBundleID = Bundle.main.bundleIdentifier
        return list("Library/Caches").compactMap { url in
            let name = url.lastPathComponent
            if claimed.contains(url.path) || Self.cacheDenyList.contains(name) || name == ownBundleID { return nil }
            var candidate = Candidate(url: url, name: name, kind: .userCaches)
            if runningBundleIDs.contains(name) {
                candidate.selected = false
                candidate.note = "This app is running. Quit it first for a clean sweep."
            }
            return candidate
        }
    }

    private func xcodeCandidates() -> [Candidate] {
        var result = children(of: "Library/Developer/Xcode/DerivedData", kind: .xcode)
            .map { c -> Candidate in
                var c = c
                // "MyApp-abcdefghijkl" → "MyApp build data"
                let project = c.name.split(separator: "-").dropLast().joined(separator: "-")
                c = Candidate(url: c.url, name: (project.isEmpty ? c.name : project) + " build data", kind: .xcode)
                return c
            }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            result += children(of: "Library/Developer/Xcode/\(platform) DeviceSupport", kind: .xcode)
                .map { Candidate(url: $0.url, name: "\(platform) \($0.name) device support", kind: .xcode) }
        }
        result += children(of: "Library/Developer/CoreSimulator/Caches", kind: .xcode)
            .map { Candidate(url: $0.url, name: "Simulator cache: \($0.name)", kind: .xcode) }
        result += children(of: "Library/Developer/Xcode/Archives", kind: .xcode)
            .map { Candidate(url: $0.url, name: "Archives from \($0.name)", kind: .xcode, selected: false,
                             note: "Archives are needed to symbolicate crash logs of shipped builds.") }
        return result
    }

    private func incompleteDownloadCandidates() -> [Candidate] {
        list("Downloads")
            .filter { Self.incompleteExtensions.contains($0.pathExtension.lowercased()) }
            .map { Candidate(url: $0, name: $0.lastPathComponent, kind: .incompleteDownloads) }
    }
}

/// Lets `concurrentPerform` write disjoint slots of one array without a lock.
struct UnsafeSendableBuffer<Element>: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<Element>
    init(_ base: UnsafeMutableBufferPointer<Element>) { self.base = base }
}
