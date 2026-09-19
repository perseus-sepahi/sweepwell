import SwiftUI
import SweepwellKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ZStack {
                LinearGradient(colors: [.canvasTop, .canvasBottom], startPoint: .top, endPoint: .bottom)
                // A soft glow in the module's colour gives each section its own mood.
                RadialGradient(colors: [model.selection.accent.opacity(0.22), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 620)
                VStack(spacing: 0) {
                    if !model.hasFullDiskAccess { AccessBanner() }
                    moduleView
                }
            }
            .animation(.easeInOut(duration: 0.35), value: model.selection)
        }
        .ignoresSafeArea()
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
                Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).foregroundStyle(Module.overview.gradient)
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
                    .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.yellow.opacity(0.12), in: Capsule())
                    .help(model.environment.home.path)
                    .padding(.leading, 8)
            }
            DiskSummary().padding(8)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(width: 224)
        .background(Color.sidebar)
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
                    .background(selected ? AnyShapeStyle(module.gradient) : AnyShapeStyle(.white.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(module.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(selected ? 0.10 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
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
            ProgressView(value: snapshot.diskFraction).tint(snapshot.diskFraction > 0.9 ? .red : Module.spaceLens.accent)
            Text("\(Format.bytes(snapshot.diskAvailable)) free of \(Format.bytes(snapshot.diskTotal))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .card(cornerRadius: 10)
    }
}

struct AccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title3).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sweepwell can only see part of your disk").font(.callout.weight(.semibold))
                Text("Grant Full Disk Access to include the Trash, Mail downloads, Safari caches and protected app data in scans.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                .buttonStyle(PillButtonStyle(prominent: true, tint: .yellow))
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .background(.yellow.opacity(0.08))
    }
}
