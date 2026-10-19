import SwiftUI
import ServiceManagement
import SweepwellKit

@main
struct SweepwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        // Sweepwell usually quits from the menu bar with its window closed, and macOS saves
        // that as "this app had no windows". On the next launch SwiftUI then never builds the
        // main window, and the panel has nothing to open. A menu bar app gains nothing from
        // window restoration (its size and position are kept separately), so skip it.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // `Sweepwell --login-item-status`: report what macOS has on file, then exit.
        if CommandLine.arguments.contains("--login-item-status") {
            let names = ["notRegistered", "enabled", "requiresApproval", "notFound"]
            let status = SMAppService.mainApp.status
            print("login item: \(names.indices.contains(status.rawValue) ? names[status.rawValue] : "unknown") (installed copy: \(LoginItem.isInstalled))")
            exit(0)
        }
    }

    var body: some Scene {
        Window("Sweepwell", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        // Always create the window at launch (a login launch closes it straight away). If macOS
        // restored it as closed, SwiftUI would never build it, and the menu bar panel would have
        // no way to open it again.
        .restorationBehavior(.disabled)
        // UI check: SWEEPWELL_TEST_NO_WINDOW=1 starts with the window never built, as can happen
        // when macOS starts Sweepwell at login.
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["SWEEPWELL_TEST_NO_WINDOW"] == "1" ? .suppressed : .presented)
        .defaultSize(width: 1140, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Smart Scan") {
                    model.selection = .overview
                    model.smartScan()
                }.keyboardShortcut("r")
                Divider()
                ForEach(Array(Module.allCases.enumerated()), id: \.element) { index, module in
                    // ⌘1…⌘9 only: a shortcut is one key, and "10" is two (it crashed at launch).
                    if index < 9 {
                        Button(module.title) { model.selection = module }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    } else {
                        Button(module.title) { model.selection = module }
                    }
                }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
