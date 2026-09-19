import SwiftUI
import AppKit
import ServiceManagement

/// "Open at login", backed by the system's own login item list (System Settings → General →
/// Login Items), so the user can always see and revoke it there as well.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// A login item remembers where the app lives. Registering a copy in a build folder
    /// would break on the next clean, so only an installed copy may register.
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// On by default, but only decided once: after that the user's choice stands, including
    /// a choice made in System Settings.
    func enableByDefaultOnce() {
        let key = "didOfferLoginItem"
        guard Self.isInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if status == .notRegistered || status == .notFound { set(true) }
    }
}

/// Keeps Sweepwell alive as a menu bar resident: closing the window leaves the menu bar icon
/// (and only that) running, until the user picks Quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let loginItem = LoginItem()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.stored.apply()
        if !ScanEnvironmentFlags.isFixture { Self.loginItem.enableByDefaultOnce() }

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
        if Self.wasLaunchedAtLogin {
            // Started by macOS at login: stay out of the way, in the menu bar only.
            DispatchQueue.main.async {
                Self.contentWindows.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing.canBecomeMain else { return }
        // The window is still listed while it closes, so look again on the next turn.
        DispatchQueue.main.async {
            if Self.contentWindows.allSatisfy({ !$0.isVisible }) { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Real windows (main, settings), as opposed to the menu bar panel and status item.
    private static var contentWindows: [NSWindow] { NSApp.windows.filter(\.canBecomeMain) }

    private static var wasLaunchedAtLogin: Bool {
        if ProcessInfo.processInfo.environment["SWEEPWELL_LAUNCHED_AT_LOGIN"] == "1" { return true }
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Brings the main window back from menu-bar-only mode.
    @MainActor static func showMainWindow(using openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ScanEnvironmentFlags {
    static var isFixture: Bool { !(ProcessInfo.processInfo.environment["SWEEPWELL_HOME"] ?? "").isEmpty }
}
