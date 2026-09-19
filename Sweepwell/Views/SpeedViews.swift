import SwiftUI
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
                await model.refreshProcesses()
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
            Circle().fill(item.isBroken ? Color.red : (item.isLoaded ? Color.green : Color.gray.opacity(0.5))).frame(width: 8, height: 8)
                .help(item.isBroken ? "Program is missing" : (item.isLoaded ? "Loaded" : "Not loaded"))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1).truncationMode(.middle)
                    if item.isBroken { badge("Broken", .red) }
                    badge(item.scope.rawValue, .white)
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

    var body: some View {
        let status = app.maintenance.status[task]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.symbol).font(.title3).foregroundStyle(Module.maintenance.gradient).frame(width: 28)
                Text(task.title).font(.callout.weight(.semibold))
                Spacer()
                if task.requiresAdministrator {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Asks for an administrator password")
                }
            }
            Text(task.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                switch status {
                case .running: ProgressView().controlSize(.small)
                case .finished(let ok, let message):
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption).foregroundStyle(ok ? Module.maintenance.accent : .orange).lineLimit(2)
                case nil: EmptyView()
                }
                Spacer()
                Button("Run") { app.maintenance.run(task) }.buttonStyle(PillButtonStyle()).disabled(status == .running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .card()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.removalModeKey) private var removalMode = RemovalMode.trash.rawValue
    @AppStorage(Preferences.largeFileThresholdKey) private var threshold = 100
    @AppStorage(Preferences.showMenuBarKey) private var showMenuBar = true

    var body: some View {
        Form {
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
            Section("Menu bar") {
                Toggle("Show the Sweepwell monitor in the menu bar", isOn: $showMenuBar)
            }
            Section("Privacy") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(app.hasFullDiskAccess ? "Granted" : "Not granted").foregroundStyle(app.hasFullDiskAccess ? .green : .yellow)
                        Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    }
                }
                Text("Sweepwell works entirely on this Mac. It has no account, no analytics and makes no network connections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 430)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = app.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Module.overview.gradient)
                Text("Sweepwell").font(.headline)
                Spacer()
                Text("up \(Format.uptime(s.uptime))").font(.caption).foregroundStyle(.secondary)
            }
            meter("Processor", s.cpuUsage, "\(Int((s.cpuUsage * 100).rounded()))%", Module.startup)
            meter("Memory", s.memoryFraction, "\(Format.bytes(s.memoryUsed)) used", Module.largeFiles)
            meter("Storage", s.diskFraction, "\(Format.bytes(s.diskAvailable)) free", Module.spaceLens)
            if let battery = s.batteryLevel {
                meter("Battery", battery, "\(Int((battery * 100).rounded()))%\(s.batteryCharging ? " · charging" : "")", Module.maintenance)
            }
            Divider()
            HStack {
                Button("Open Sweepwell") { show(.overview, scan: false) }
                Spacer()
                Button("Smart Scan") { show(.overview, scan: true) }.buttonStyle(.borderedProminent).tint(Module.overview.colors[1])
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func show(_ module: Module, scan: Bool) {
        app.selection = module
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if scan { app.smartScan() }
    }

    private func meter(_ title: String, _ value: Double, _ caption: String, _ module: Module) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, value))).tint(module.accent)
        }
    }
}
