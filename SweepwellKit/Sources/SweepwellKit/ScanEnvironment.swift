import Foundation

/// Where Sweepwell looks. Everything is derived from `home`, so pointing it at a fixture
/// folder gives a complete dry-run world for tests and demos.
public struct ScanEnvironment: Sendable, Equatable {
    public var home: URL
    public var applicationDirectories: [URL]
    /// True when `home` is a stand-in (set through `SWEEPWELL_HOME`), not the real account.
    public var isFixture: Bool

    public init(home: URL, applicationDirectories: [URL], isFixture: Bool) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.applicationDirectories = applicationDirectories.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.isFixture = isFixture
    }

    public static func fixture(home: URL) -> ScanEnvironment {
        ScanEnvironment(home: home, applicationDirectories: [home.appendingPathComponent("Applications")],
                        isFixture: true)
    }

    /// The signed-in user's real folders, unless `SWEEPWELL_HOME` redirects to a fixture.
    public static var live: ScanEnvironment {
        if let override = ProcessInfo.processInfo.environment["SWEEPWELL_HOME"], !override.isEmpty {
            return .fixture(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ScanEnvironment(home: home,
                               applicationDirectories: [URL(fileURLWithPath: "/Applications"),
                                                        home.appendingPathComponent("Applications")],
                               isFixture: false)
    }

    public var library: URL { home.appendingPathComponent("Library") }
    public var trash: URL { home.appendingPathComponent(".Trash") }

    public func homeRelative(_ path: String) -> URL { home.appendingPathComponent(path) }

    /// The usual places people keep their own files; the default for file-oriented scans.
    public var userFolders: [URL] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum FullDiskAccess {
    /// Folders every account has and only Full Disk Access can open. There is no API for the
    /// question, so the answer comes from trying: the first probe that exists decides.
    private static let probes = ["Library/Safari", ".Trash", "Library/Mail", "Library/Application Support/com.apple.TCC"]

    public static func isGranted(_ environment: ScanEnvironment) -> Bool {
        if environment.isFixture { return true }
        for probe in probes {
            let fd = open(environment.homeRelative(probe).path, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                close(fd)
                return true
            }
            // Denied is an answer; "does not exist" only means this probe cannot tell.
            if errno == EPERM || errno == EACCES { return false }
        }
        return true
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
