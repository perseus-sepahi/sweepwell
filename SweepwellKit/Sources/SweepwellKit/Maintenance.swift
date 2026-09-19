import Foundation

public enum MaintenanceTask: String, CaseIterable, Identifiable, Sendable {
    case flushDNS, freeMemory, thinSnapshots, reindexSpotlight, resetQuickLook, refreshLaunchServices, restartDock, restartFinder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flushDNS: "Flush DNS Cache"
        case .freeMemory: "Free Up Inactive Memory"
        case .thinSnapshots: "Thin Time Machine Snapshots"
        case .reindexSpotlight: "Rebuild Spotlight Index"
        case .resetQuickLook: "Reset Quick Look"
        case .refreshLaunchServices: "Tidy “Open With” Menus"
        case .restartDock: "Restart the Dock"
        case .restartFinder: "Restart Finder"
        }
    }

    public var detail: String {
        switch self {
        case .flushDNS: "Helps when a website moved but your Mac keeps going to the old address, or some sites will not load."
        case .freeMemory: "Asks macOS to drop cached file data from RAM. Useful right before a memory-hungry job; macOS refills the cache on its own."
        case .thinSnapshots: "Local Time Machine snapshots are the usual source of “purgeable” space. This asks macOS to give that space back now."
        case .reindexSpotlight: "For when search misses files you know exist. Indexing runs in the background and can take an hour."
        case .resetQuickLook: "Fixes blank or outdated previews and thumbnails in Finder."
        case .refreshLaunchServices: "Removes stale and duplicate apps from the “Open With” menu by compacting the Launch Services database."
        case .restartDock: "Clears up a frozen Dock, stuck badges or Mission Control glitches. Your windows stay open."
        case .restartFinder: "Refreshes Finder when icons, sidebars or the desktop stop updating."
        }
    }

    public var symbol: String {
        switch self {
        case .flushDNS: "network"
        case .freeMemory: "memorychip"
        case .thinSnapshots: "clock.arrow.circlepath"
        case .reindexSpotlight: "magnifyingglass"
        case .resetQuickLook: "eye"
        case .refreshLaunchServices: "arrow.up.forward.app"
        case .restartDock: "dock.rectangle"
        case .restartFinder: "folder"
        }
    }

    /// Tasks that need root show the standard macOS password dialog when they run.
    public var requiresAdministrator: Bool {
        switch self {
        case .flushDNS, .freeMemory, .thinSnapshots, .reindexSpotlight: true
        default: false
        }
    }

    /// Fixed command lines only: nothing here is ever built from user input.
    var commands: [(executable: String, arguments: [String])] {
        switch self {
        case .flushDNS: [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])]
        case .freeMemory: [("/usr/sbin/purge", [])]
        case .thinSnapshots: [("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "999999999999", "4"])]
        case .reindexSpotlight: [("/usr/bin/mdutil", ["-E", "/"])]
        case .resetQuickLook: [("/usr/bin/qlmanage", ["-r"]), ("/usr/bin/qlmanage", ["-r", "cache"])]
        case .refreshLaunchServices:
            [("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
              ["-gc", "-r", "-apps", "user,local"])]
        case .restartDock: [("/usr/bin/killall", ["Dock"])]
        case .restartFinder: [("/usr/bin/killall", ["Finder"])]
        }
    }
}

public struct MaintenanceOutcome: Sendable {
    public let succeeded: Bool
    public let message: String
}

public enum MaintenanceRunner {
    public static func run(_ task: MaintenanceTask) -> MaintenanceOutcome {
        task.requiresAdministrator ? runPrivileged(task) : runPlain(task)
    }

    private static func runPlain(_ task: MaintenanceTask) -> MaintenanceOutcome {
        for command in task.commands {
            let result = Shell.run(command.executable, command.arguments)
            if !result.succeeded {
                return MaintenanceOutcome(succeeded: false, message: result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The command failed.")
            }
        }
        return MaintenanceOutcome(succeeded: true, message: "Done")
    }

    /// `do shell script … with administrator privileges` makes macOS itself collect the
    /// password; Sweepwell never sees it.
    private static func runPrivileged(_ task: MaintenanceTask) -> MaintenanceOutcome {
        let line = task.commands
            .map { ([$0.executable] + $0.arguments).map(shellQuote).joined(separator: " ") }
            .joined(separator: " && ")
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Sweepwell wants to run “\(task.title)”.\" with administrator privileges"
        // A child osascript keeps the app responsive while the password dialog is up.
        let result = Shell.run("/usr/bin/osascript", ["-e", source])
        if result.succeeded { return MaintenanceOutcome(succeeded: true, message: "Done") }
        let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.contains("-128") { return MaintenanceOutcome(succeeded: false, message: "Cancelled") }
        return MaintenanceOutcome(succeeded: false, message: output.isEmpty ? "The command failed." : output)
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 KB", not "Zero KB": these strings end up inside button titles.
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    public static func uptime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? ""
    }
}
