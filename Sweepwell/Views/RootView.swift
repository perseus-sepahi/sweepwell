import SwiftUI
import SweepwellKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ZStack {
                AuroraBackground(module: model.selection)
                VStack(spacing: 0) {
                    if !model.hasFullDiskAccess { AccessBanner() }
                    moduleView
                        .id(model.selection)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: model.selection)
        }
        .ignoresSafeArea()
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
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image("BroomGlyph").resizable().renderingMode(.template).foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .frame(width: 26, height: 26)
                    .background(Module.overview.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Module.overview.accent.opacity(0.5), radius: 6, y: 2)
                Text("Sweepwell").font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.leading, 12)
            .padding(.top, 44)
            .padding(.bottom, 14)

            ForEach(Module.sections, id: \.0) { title, modules in
                if !title.isEmpty {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12).padding(.top, 14).padding(.bottom, 2)
                }
                ForEach(modules) { module in SidebarRow(module: module) }
            }
            Spacer()
            if model.environment.isFixture {
                Label("Demo folder", systemImage: "testtube.2")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.warning)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.warning.opacity(0.14), in: Capsule())
                    .help(model.environment.home.path)
                    .padding(.leading, 8)
            }
            DiskSummary().padding(.horizontal, 8).padding(.top, 8)
            GlassSlider(compact: true).padding(.horizontal, 14).padding(.top, 8)
            AppearanceSwitch().padding(8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(width: 228)
        .background {
            ZStack {
                VibrantBackground()
                Color.sidebarTint
            }
        }
        .overlay(alignment: .trailing) { Color.hairline.frame(width: 1) }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let module: Module
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == module
        Button { model.selection = module } label: {
            HStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(module.gradient))
                    .frame(width: 26, height: 26)
                    .background(selected ? AnyShapeStyle(module.gradient) : AnyShapeStyle(Color.hoverFill),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: selected ? module.accent.opacity(0.5) : .clear, radius: 5, y: 2)
                Text(module.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.selectionFill : (hovering ? Color.hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(duration: 0.3), value: selected)
    }
}

/// Day / Auto / Night. Auto follows the macOS appearance, including its sunset schedule.
private struct AppearanceSwitch: View {
    @AppStorage(Preferences.appearanceKey) private var stored = AppearanceMode.auto.rawValue
    @Namespace private var thumb

    var body: some View {
        let current = AppearanceMode(rawValue: stored) ?? .auto
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    withAnimation(.spring(duration: 0.3)) { stored = mode.rawValue }
                    mode.apply()
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(current == mode ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if current == mode {
                                Capsule().fill(Color.surfaceRaised)
                                    .shadow(color: .cardShadow, radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(mode == .auto ? "Follow macOS: light by day, dark at night" : "\(mode.title) theme")
            }
        }
        .padding(3)
        .background(Color.track, in: Capsule())
    }
}

private struct DiskSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Macintosh HD", systemImage: "internaldrive").font(.caption.weight(.semibold))
                Spacer()
            }
            ProgressView(value: snapshot.diskFraction).tint(snapshot.diskFraction > 0.9 ? Color.danger : Module.spaceLens.accent)
            Text("\(Format.bytes(snapshot.diskAvailable)) free of \(Format.bytes(snapshot.diskTotal))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .card(cornerRadius: 12)
    }
}

struct AccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(Color.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sweepwell can only see part of your disk").font(.callout.weight(.semibold))
                Text("Grant Full Disk Access to include the Trash, Mail downloads, Safari caches and protected app data in scans.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                .buttonStyle(PillButtonStyle(prominent: true, tint: .warning))
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .background(Color.warning.opacity(0.10))
        .overlay(alignment: .bottom) { Color.warning.opacity(0.25).frame(height: 1) }
    }
}
