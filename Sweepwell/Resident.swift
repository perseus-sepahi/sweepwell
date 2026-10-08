import SwiftUI
import AppKit
import ServiceManagement
import SweepwellKit

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
    /// Scene actions only exist inside SwiftUI; the root view hands them over on first
    /// appearance so AppKit-side code (the status panel) can open windows too.
    static var openMainWindow: (() -> Void)?
    static var openSettingsWindow: (() -> Void)?
    private var statusPanel: StatusPanelController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.stored.apply()
        if !ScanEnvironmentFlags.isFixture { Self.loginItem.enableByDefaultOnce() }

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
        statusPanel = StatusPanelController(model: .shared)
        let hooks = ProcessInfo.processInfo.environment
        if hooks["SWEEPWELL_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.statusPanel?.show()
                if hooks["SWEEPWELL_PANEL_BACKDROP"] == "1", let frame = self.statusPanel?.panelFrame {
                    // Behind the panel's own frame, with room to spare on every side.
                    Self.showTestBackdrop(covering: frame.insetBy(dx: -40, dy: -40))
                }
                AppModel.shared.expandedVital = hooks["SWEEPWELL_PANEL_EXPAND"].flatMap(Vital.init(rawValue:))
            }
        }
        if hooks["SWEEPWELL_TEST_REOPEN"] == "1" {
            // UI check: the window was closed at launch; prove it can come back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Self.showMainWindow() }
        }
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

    /// UI check only: a colourful wallpaper-like window under the panel, so captures show the
    /// glass bending something without photographing anything else on screen.
    private static var testBackdrop: NSWindow?
    private static func showTestBackdrop(covering frame: NSRect) {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar   // above ordinary windows, below the panel
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(hex: 0x2E7D32), Color(hex: 0x9CCC65), Color(hex: 0x1565C0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<6, id: \.self) { i in
                Circle().fill([Color.orange, .pink, .yellow, .cyan, .purple, .white][i].opacity(0.7))
                    .frame(width: 160, height: 160)
                    .offset(x: CGFloat(i % 3) * 140 - 140, y: CGFloat(i / 3) * 360 - 180)
            }
        }
        .frame(width: frame.width, height: frame.height))
        // Keep the window exactly the size asked for, so it covers everything behind the panel.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = host
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        testBackdrop = window
    }

    /// Brings the main window back from menu-bar-only mode.
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let existing = contentWindows.first(where: { $0.identifier?.rawValue.hasPrefix("main") ?? false }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showSettings() {
        NSApp.setActivationPolicy(.regular)
        openSettingsWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Status item and panel

/// A panel that can take keyboard focus even though it has no title bar, so the controls
/// inside it behave normally.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The menu bar icon and the summary panel under it. Hand-rolled instead of `MenuBarExtra`
/// because Liquid Glass needs a truly transparent window behind it, which MenuBarExtra's
/// system-owned panel does not offer.
@MainActor
final class StatusPanelController: NSObject {
    // Variable length keeps the item as narrow as its glyph: on a crowded menu bar next to the
    // notch, a few points decide whether macOS shows the icon or folds it into the « overflow.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: KeyPanel
    private let hosting: NSHostingView<AnyView>
    private var outsideClickMonitor: Any?
    private var lastClosed = Date.distantPast

    init(model: AppModel) {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server would trace the transparent margin with its shadow; the glass
        // draws its own instead.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        hosting.rootView = AnyView(MenuPanelView(dismiss: { [weak self] in self?.close() },
                                                 sizeChanged: { [weak self] in self?.fit(to: $0) }).environment(model))

        if let button = statusItem.button {
            // The broom from the app icon, as a template so macOS tints it for the menu bar.
            // The broom from the app icon, as a template so macOS tints it for the menu bar.
            let glyph = NSImage(named: "BroomGlyph") ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            glyph?.isTemplate = true
            glyph?.size = NSSize(width: 18, height: 18)
            glyph?.accessibilityDescription = "Sweepwell"
            button.image = glyph
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// A click on the icon while the panel is open reaches us twice: first the panel loses
    /// focus and closes itself, then the button's action fires. Without this check the second
    /// half would see a closed panel and open it again, so the icon could never dismiss it.
    var panelFrame: NSRect { panel.frame }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            show()
        }
    }

    func show() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let size = hosting.fittingSize
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Centred under the icon, but never hanging off the edge of the screen.
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        AppModel.shared.panelVisible = true
        AppModel.shared.refreshTrash()
        Task { await AppModel.shared.sampleNow() }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// The panel grows and shrinks with its content (overview vs. a breakdown). It hangs from
    /// the menu bar, so the top edge stays put and the bottom edge moves.
    private func fit(to size: CGSize) {
        guard panel.isVisible, size.height > 50, abs(panel.frame.height - size.height) > 0.5 else { return }
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func close() {
        if panel.isVisible { lastClosed = Date() }
        // Next time, open fresh: nothing expanded, no stale messages.
        AppModel.shared.panelVisible = false
        AppModel.shared.expandedVital = nil
        AppModel.shared.panelMessage = nil
        panel.orderOut(nil)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    @objc private func panelResignedKey() {
        if ProcessInfo.processInfo.environment["SWEEPWELL_OPEN_PANEL"] != "1" { close() }
    }
}

enum ScanEnvironmentFlags {
    static var isFixture: Bool { !(ProcessInfo.processInfo.environment["SWEEPWELL_HOME"] ?? "").isEmpty }
}
