import SwiftUI
import SweepwellKit

/// The main window, built the macOS 26 way: a `NavigationSplitView` whose sidebar floats as a
/// pane of Liquid Glass over the content, a glass toolbar, and the module's colours extending
/// underneath the sidebar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 214, ideal: 232, max: 300)
        } detail: {
            moduleView
                .id(model.selection)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    // The module's colours reach under the floating sidebar, mirrored and
                    // blurred, so the glass has something to pick up, like the hero art in
                    // Apple's own apps.
                    AuroraBackground(module: model.selection)
                        .backgroundExtensionEffect()
                        .ignoresSafeArea()
                }
            .safeAreaBar(edge: .top) {
                if !model.hasFullDiskAccess { AccessBanner() }
            }
            .animation(.easeInOut(duration: 0.3), value: model.selection)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.selection = .overview
                        model.smartScan()
                    } label: {
                        Label("Smart Scan", systemImage: "sparkles")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Module.overview.accent)
                    .help("Check for junk, large files and startup items (⌘R)")
                    .disabled(model.smartScanRunning)
                }
            }
        }
        .navigationTitle("Sweepwell")
        // The desktop, blurred, behind everything: how much of it shows is the Glass dial.
        .containerBackground(for: .window) { VibrantBackground() }
        .onAppear {
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            AppDelegate.openSettingsWindow = { openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    @ViewBuilder private var moduleView: some View {
        switch model.selection {
        case .overview: OverviewView()
        case .junk: JunkView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .spaceLens: SpaceLensView()
        case .uninstaller: UninstallerView()
        case .startup: StartupView()
        case .maintenance: MaintenanceView()
        case .storageAudit: StorageAuditView()
        }
    }
}

/// A standard source list: the system draws it on the floating glass sidebar and handles
/// selection, keyboard navigation and accessibility.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<Module?>(get: { model.selection }, set: { if let module = $0 { model.selection = module } })) {
            ForEach(Module.sections, id: \.0) { title, modules in
                Section {
                    ForEach(modules) { module in
                        Label {
                            Text(module.title)
                        } icon: {
                            Image(systemName: module.symbol).foregroundStyle(module.gradient)
                        }
                        .tag(module)
                    }
                } header: {
                    if !title.isEmpty { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if model.environment.isFixture {
                    Label("Demo folder", systemImage: "testtube.2")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.warning)
                        .help(model.environment.home.path)
                }
                DiskSummary()
                    .padding(12)
                    .panelGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                GlassSlider(compact: true)
                    .padding(12)
                    .panelGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                AppearanceSwitch()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

/// Day / Auto / Night. A system segmented control, so it is drawn in glass like every other
/// control on macOS 26. Auto follows the macOS appearance, including its sunset schedule.
private struct AppearanceSwitch: View {
    @AppStorage(Preferences.appearanceKey) private var stored = AppearanceMode.auto.rawValue

    var body: some View {
        Picker("Appearance", selection: $stored) {
            ForEach(AppearanceMode.allCases) { mode in
                Image(systemName: mode.symbol).help(mode == .auto ? "Follow macOS" : "\(mode.title) theme").tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: stored) { _, new in AppearanceMode(rawValue: new)?.apply() }
    }
}

private struct DiskSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconDisc(symbol: "internaldrive.fill", color: Module.spaceLens.colors[1], size: 26)
                Text("Macintosh HD").font(.caption.weight(.semibold))
            }
            ProgressView(value: snapshot.diskFraction).tint(snapshot.diskFraction > 0.9 ? Color.danger : Module.spaceLens.accent)
            Text("\(Format.bytes(snapshot.diskAvailable)) free of \(Format.bytes(snapshot.diskTotal))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Floats under the toolbar as a tinted pane of glass until access is granted.
struct AccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            IconDisc(symbol: "lock.shield.fill", color: Color.warning, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sweepwell can only see part of your disk").font(.callout.weight(.semibold))
                Text("Grant Full Disk Access to include the Trash, Mail downloads, Safari caches and protected app data in scans.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                .buttonStyle(PillButtonStyle(prominent: true, tint: .warning, labelColor: .black))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .panelGlass(Capsule(), tint: Color.warning.opacity(0.12))
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }
}
