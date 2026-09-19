import SwiftUI
import ServiceManagement
import SweepwellKit

@main
struct SweepwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
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
        .windowStyle(.hiddenTitleBar)
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
                    Button(module.title) { model.selection = module }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        // Always present: the menu bar icon is how Sweepwell stays reachable once its window
        // is closed, and it only goes away when the user quits.
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
