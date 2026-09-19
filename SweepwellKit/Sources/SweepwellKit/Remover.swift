import Foundation

public enum RemovalMode: String, Sendable, CaseIterable {
    /// Move to the Trash: nothing is lost until the user empties it.
    case trash
    /// Delete immediately; space is reclaimed right away and there is no undo.
    case permanent
}

public struct RemovalRequest: Sendable {
    public let url: URL
    public let size: Int64
    public let purpose: RemovalPurpose

    public init(url: URL, size: Int64, purpose: RemovalPurpose) {
        self.url = url
        self.size = size
        self.purpose = purpose
    }
}

public struct RemovalReport: Sendable {
    public struct Failure: Sendable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let message: String
    }

    public var removed: [URL] = []
    public var failures: [Failure] = []
    public var bytesFreed: Int64 = 0

    public init() {}

    public mutating func merge(_ other: RemovalReport) {
        removed += other.removed
        failures += other.failures
        bytesFreed += other.bytesFreed
    }
}

public struct Remover: Sendable {
    public let environment: ScanEnvironment
    private let safetyGuard: SafetyGuard

    public init(environment: ScanEnvironment) {
        self.environment = environment
        self.safetyGuard = SafetyGuard(environment: environment)
    }

    public func remove(_ requests: [RemovalRequest], mode: RemovalMode,
                       control: ScanControl = ScanControl()) -> RemovalReport {
        var report = RemovalReport()
        let fileManager = FileManager.default
        for request in requests {
            if control.isCancelled { break }
            do {
                try safetyGuard.validate(request.url, purpose: request.purpose)
                // The Trash cannot be trashed again; everything else honours the chosen mode.
                if request.purpose == .trashContents || mode == .permanent {
                    try fileManager.removeItem(at: request.url)
                } else if environment.isFixture {
                    try moveToFixtureTrash(request.url)
                } else {
                    try fileManager.trashItem(at: request.url, resultingItemURL: nil)
                }
                report.removed.append(request.url)
                report.bytesFreed += request.size
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone (caches come and go while we work): the goal is met.
                report.removed.append(request.url)
            } catch {
                report.failures.append(.init(url: request.url, message: Self.describe(error)))
            }
        }
        return report
    }

    /// `trashItem` always uses the real account's Trash. A fixture home keeps to itself, so
    /// demos and tests never leave anything behind in the user's actual Trash.
    private func moveToFixtureTrash(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: environment.trash, withIntermediateDirectories: true)
        var target = environment.trash.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: target.path) {
            target = environment.trash.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        }
        try fileManager.moveItem(at: url, to: target)
    }

    static func describe(_ error: Error) -> String {
        if let violation = error as? SafetyViolation { return violation.reason }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
            return "Permission denied. macOS protects this item, or Sweepwell needs Full Disk Access."
        }
        return nsError.localizedDescription
    }
}
