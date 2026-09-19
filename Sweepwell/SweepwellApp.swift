import SwiftUI
import SweepwellKit

@main
struct SweepwellApp: App {
    @State private var model = AppModel()
    @AppStorage(Preferences.showMenuBarKey) private var showMenuBar = true

    var body: some Scene {
        Window("Sweepwell", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 680)
                .onAppear { AppearanceMode.stored.apply() }
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

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
