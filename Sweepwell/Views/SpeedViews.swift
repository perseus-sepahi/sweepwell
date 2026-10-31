import SwiftUI
import ServiceManagement
import SweepwellKit

// MARK: - Startup & Activity

struct StartupView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming: LaunchItem?

    var body: some View {
        let model = app.startup
        ModuleScaffold(module: .startup) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Background items", detail: "Helpers that start on their own. “Broken” ones point at a program that no longer exists: leftovers of removed apps.") {
                        Button("Open Login Items Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }.buttonStyle(PillButtonStyle())
                        Button("Refresh") { model.refresh() }.buttonStyle(PillButtonStyle())
                    }
                    if let message = model.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.items.isEmpty {
                        Text(model.isLoading ? "Loading…" : "No background items found.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24).card()
                    } else {
                        VStack(spacing: 2) {
                            ForEach(model.items) { item in LaunchItemRow(item: item) { confirming = item } }
                        }.padding(6).card()
                    }

                    section("Heaviest right now", detail: "The processes using the most memory. Quitting is the polite kind: apps get to save first.") { EmptyView() }
                    VStack(spacing: 2) {
                        ForEach(model.processes) { process in ProcessRow(process: process) }
                    }.padding(6).card()
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .task {
            if !model.hasLoaded { model.refresh() }
            // Live while the view is on screen; SwiftUI cancels this when it goes away.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if AppModel.isAnythingVisible { await model.refreshProcesses() }
            }
        }
        .confirmationDialog("Remove \(confirming?.label ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { item in
            Button("Remove", role: .destructive) { model.remove(item) }
        } message: { _ in
            Text("The helper is stopped and its launch file is removed, so it no longer starts with your Mac.")
        }
    }

    private func section<Trailing: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

private struct LaunchItemRow: View {
    let item: LaunchItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(item.isBroken ? Color.danger : (item.isLoaded ? Color.success : Color.gray.opacity(0.5))).frame(width: 8, height: 8)
                .help(item.isBroken ? "Program is missing" : (item.isLoaded ? "Loaded" : "Not loaded"))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1).truncationMode(.middle)
                    if item.isBroken { badge("Broken", .danger) }
                    badge(item.scope.rawValue, .secondary)
                }
                Text(item.program ?? "No program listed").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { NSWorkspace.shared.reveal(item.plistURL) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            if item.isRemovable {
                Button("Remove", action: remove).buttonStyle(PillButtonStyle())
            } else {
                Image(systemName: "lock").foregroundStyle(.tertiary).frame(width: 74)
                    .help("Installed for all users. Remove it with the app's own uninstaller, or reveal it and delete it as an administrator.")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }
}

private struct ProcessRow: View {
    @Environment(AppModel.self) private var app
    let process: ProcessSample

    var body: some View {
        let bundle = process.appBundleURL
        HStack(spacing: 10) {
            if let bundle { FileIcon(url: bundle, size: 22) } else {
                Image(systemName: "gearshape.2").frame(width: 22, height: 22).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(process.name).lineLimit(1)
                if let bundle { Text(bundle.deletingPathExtension().lastPathComponent).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("\(process.cpu, specifier: "%.0f")% CPU").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(Format.bytes(process.memory)).font(.callout.monospacedDigit()).frame(width: 84, alignment: .trailing)
            // Only regular apps: quitting a system daemon by hand is never the fix.
            if NSRunningApplication(processIdentifier: process.pid)?.activationPolicy == .regular,
               process.pid != ProcessInfo.processInfo.processIdentifier {
                Button("Quit") { app.startup.quit(process) }.buttonStyle(PillButtonStyle())
            } else {
                Color.clear.frame(width: 58, height: 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ModuleScaffold(module: .maintenance) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(MaintenanceTask.allCases) { task in TaskCard(task: task) }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
    }
}

private struct TaskCard: View {
    @Environment(AppModel.self) private var app
    let task: MaintenanceTask
    @State private var hovering = false

    var body: some View {
        let status = app.maintenance.status[task]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconDisc(symbol: task.symbol, color: Module.maintenance.colors[1], size: 32)
                Text(task.title).font(.callout.weight(.semibold))
                Spacer()
                if task.requiresAdministrator {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Asks for an administrator password")
                }
            }
            Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                switch status {
                case .running: ProgressView().controlSize(.small)
                case .finished(let ok, let message):
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption).foregroundStyle(ok ? Color.success : Color.warning).lineLimit(2)
                case nil: EmptyView()
                }
                Spacer()
                Button("Run") { app.maintenance.run(task) }.buttonStyle(PillButtonStyle()).disabled(status == .running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .card(highlighted: hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.removalModeKey) private var removalMode = RemovalMode.trash.rawValue
    @AppStorage(Preferences.largeFileThresholdKey) private var threshold = 100
    @AppStorage(Preferences.appearanceKey) private var appearance = AppearanceMode.auto.rawValue

    var body: some View {
        Form {
            Section("Sweepwell Pro") {
                LabeledContent(app.pro.summary) {
                    Button(app.pro.status.unlockedForGood || app.pro.isOwnerBuild ? "Details" : "Get Pro") { app.pro.showPaywall() }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in AppearanceMode(rawValue: new)?.apply() }
                Text("Auto follows macOS, so Sweepwell turns dark when your Mac does.")
                    .font(.caption).foregroundStyle(.secondary)
                GlassSlider()
            }
            Section("Removing files") {
                Picker("When cleaning", selection: $removalMode) {
                    Text("Move to Trash (can be undone)").tag(RemovalMode.trash.rawValue)
                    Text("Delete immediately").tag(RemovalMode.permanent.rawValue)
                }
                Text("Moving to the Trash is the safe default: space is reclaimed when you empty it. Items that are already in the Trash are always deleted for good.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Large & Old Files") {
                Picker("List files larger than", selection: $threshold) {
                    ForEach([50, 100, 250, 500, 1024], id: \.self) { Text(Format.bytes(Int64($0) << 20)).tag($0) }
                }
            }
            Section("Startup") {
                let login = AppDelegate.loginItem
                Toggle("Open Sweepwell when I log in", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                    .disabled(!LoginItem.isInstalled)
                if !LoginItem.isInstalled {
                    Text("Move Sweepwell to the Applications folder first. A login item remembers where the app lives.")
                        .font(.caption).foregroundStyle(Color.warning)
                } else if login.needsApproval {
                    HStack {
                        Text("macOS is waiting for you to allow this in Login Items.").font(.caption).foregroundStyle(Color.warning)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                } else if let error = login.lastError {
                    Text(error).font(.caption).foregroundStyle(Color.danger)
                }
                Text("At login Sweepwell starts quietly in the menu bar. Closing the window keeps it there; choose Quit from the menu bar icon to stop it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(app.hasFullDiskAccess ? "Granted" : "Not granted").foregroundStyle(app.hasFullDiskAccess ? Color.success : Color.warning)
                        Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    }
                }
                Text("Sweepwell works entirely on this Mac. It has no account and no analytics. Its only network use: once you buy Pro, a weekly check of the public list of refunded licences. Your licence is checked offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear { AppDelegate.loginItem.refresh() }
    }
}
