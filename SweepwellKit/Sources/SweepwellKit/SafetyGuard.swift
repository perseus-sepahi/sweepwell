import Foundation

/// Why a path is being removed. Each purpose has its own, deliberately narrow, allow-list.
public enum RemovalPurpose: Sendable {
    /// Regenerable data found by the junk scanner (caches, logs, build products).
    case junk
    /// Items already in the user's Trash; removing them is permanent by nature.
    case trashContents
    /// A document the user picked themselves (large files, duplicates, Space Lens).
    case userFile
    /// An application bundle in one of the application folders.
    case application
    /// Support files of an app being uninstalled.
    case appLeftover
    /// A per-user launch agent plist.
    case launchAgent
    /// A folder the storage audit found and the user picked (always moved to the Trash).
    case auditItem
    /// A file or folder the user dropped on the shredder: overwritten, then deleted for good.
    case shred
}

public struct SafetyViolation: Error, LocalizedError, Sendable {
    public let path: String
    public let reason: String
    public var errorDescription: String? { "Refused to remove \(path): \(reason)" }
}

/// Last line of defence before anything leaves the disk. Scanners decide what to *offer*;
/// this decides what may actually be *removed*, from the resolved path alone, so a scanner
/// bug or a planted symlink cannot turn a cache clean-up into data loss.
public struct SafetyGuard: Sendable {
    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment) { self.environment = environment }

    /// Folders whose contents are personal data; junk clean-up never reaches into them.
    private static let personalFolders: Set<String> = [
        "Desktop", "Documents", "Pictures", "Movies", "Music", "Public", "Sites"
    ]

    /// `~/Library` areas that hold irreplaceable data even though they look like app support.
    private static let protectedLibraryFolders: Set<String> = [
        "Keychains", "Mobile Documents", "Mail", "Messages", "Calendars", "Accounts", "Photos",
        "CloudStorage", "Passes", "Safari", "IdentityServices", "Biome"
    ]

    /// Top-level home entries an audit removal must never touch.
    static let auditDenied: Set<String> = [
        ".Trash", ".ssh", ".gnupg", ".config", ".aws", ".kube", ".docker", ".netrc", ".password-store",
        "Applications", ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile", ".gitconfig"
    ]

    static let leftoverLocations: Set<String> = [
        "Application Support", "Caches", "Preferences", "Logs", "Containers", "Group Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "Application Scripts"
    ]

    public func validate(_ url: URL, purpose: RemovalPurpose) throws {
        let resolved = Self.resolveParent(of: url)
        let path = resolved.path

        func refuse(_ reason: String) -> SafetyViolation { SafetyViolation(path: path, reason: reason) }

        if purpose == .application {
            try validateApplication(resolved)
            return
        }

        guard let parts = components(of: resolved, below: environment.home) else {
            // Outside the home folder only user-picked files on external volumes are fair game.
            if purpose == .userFile || purpose == .shred, let external = Self.components(of: resolved, belowPath: "/Volumes"),
               external.count >= 2 {
                return
            }
            throw refuse("it is outside your home folder")
        }
        guard let first = parts.first else { throw refuse("it is the home folder itself") }

        switch purpose {
        case .trashContents:
            guard first == ".Trash", parts.count == 2 else { throw refuse("it is not an item in the Trash") }

        case .junk:
            if first == "Library" {
                guard parts.count >= 3 else { throw refuse("it is a top-level Library folder") }
                if Self.protectedLibraryFolders.contains(parts[1]) {
                    throw refuse("~/Library/\(parts[1]) holds personal data")
                }
            } else {
                guard parts.count >= 2 else { throw refuse("it is a top-level folder in your home") }
                if Self.personalFolders.contains(first) { throw refuse("~/\(first) holds personal files") }
                if first == ".Trash" { throw refuse("Trash items must be removed as Trash contents") }
            }

        case .userFile:
            if first == "Library" { throw refuse("~/Library is managed by apps, not a place for documents") }
            if first == ".Trash" { throw refuse("it is already in the Trash") }
            if parts.count == 1 {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if !exists || isDirectory.boolValue { throw refuse("it is a top-level folder in your home") }
            }

        case .appLeftover:
            guard first == "Library", parts.count >= 3 else { throw refuse("it is not inside a ~/Library support folder") }
            guard Self.leftoverLocations.contains(parts[1]) else {
                throw refuse("~/Library/\(parts[1]) is not an app support location")
            }

        case .launchAgent:
            guard parts.count == 3, first == "Library", parts[1] == "LaunchAgents",
                  parts[2].hasSuffix(".plist") else {
                throw refuse("it is not a plist in ~/Library/LaunchAgents")
            }

        case .auditItem:
            // Hidden tool folders, caches, VMs and SDKs: anywhere in the home folder except the
            // places that hold personal data or credentials.
            if Self.personalFolders.contains(first) || ["Desktop", "Downloads"].contains(first) {
                throw refuse("~/\(first) holds your own files")
            }
            if Self.auditDenied.contains(first) { throw refuse("~/\(first) holds credentials or system state") }
            if first == "Library" {
                guard parts.count >= 3 else { throw refuse("it is a top-level Library folder") }
                if Self.protectedLibraryFolders.contains(parts[1]) { throw refuse("~/Library/\(parts[1]) holds personal data") }
            }

        case .shred:
            if parts.count == 1 {
                // Whole top-level folders (Documents, Desktop, …) and dotfiles that hold
                // credentials or shell setup are too big a blast radius for one click.
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                let personal = Self.personalFolders.contains(first) || ["Desktop", "Downloads", "Applications"].contains(first)
                if personal || (isDirectory.boolValue && !first.hasPrefix(".")) || Self.auditDenied.contains(first) {
                    throw refuse("~/\(first) is a whole top-level folder or holds credentials")
                }
            }
            if first == "Library" { throw refuse("~/Library belongs to your apps and macOS") }
            if first == ".Trash", parts.count == 1 { throw refuse("it is the Trash itself") }

        case .application:
            break
        }
    }

    private func validateApplication(_ url: URL) throws {
        let path = url.path
        guard url.pathExtension == "app" else {
            throw SafetyViolation(path: path, reason: "it is not an application bundle")
        }
        if path.hasPrefix("/System/") {
            throw SafetyViolation(path: path, reason: "it is part of macOS")
        }
        if path == Bundle.main.bundleURL.resolvingSymlinksInPath().path {
            throw SafetyViolation(path: path, reason: "Sweepwell cannot uninstall itself while running")
        }
        let inside = environment.applicationDirectories.contains { directory in
            guard let parts = components(of: url, below: directory) else { return false }
            // The bundle itself, not something inside another bundle.
            return !parts.isEmpty && !parts.dropLast().contains { $0.hasSuffix(".app") }
        }
        guard inside else {
            throw SafetyViolation(path: path, reason: "it is not in an Applications folder")
        }
    }

    /// Resolves symlinks in every component except the last: removing a symlink only removes
    /// the link, but a symlinked *parent* would silently move the operation somewhere else.
    static func resolveParent(of url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    private func components(of url: URL, below base: URL) -> [String]? {
        Self.components(of: url, belowPath: base.path)
    }

    /// Path components of `url` relative to `basePath`; nil when it is not underneath.
    static func components(of url: URL, belowPath basePath: String) -> [String]? {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let path = url.path
        if path == base { return [] }
        guard path.hasPrefix(base + "/") else { return nil }
        let parts = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        return parts.contains("..") ? nil : parts
    }
}
