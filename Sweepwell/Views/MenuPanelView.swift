import SwiftUI
import AppKit
import IOKit
import SweepwellKit

/// The at-a-glance summary behind the menu bar icon.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.glassKey) private var glass = Glassiness.default
    /// Closes the panel; every action that leaves for a window calls it first.
    var dismiss: () -> Void = {}
    /// The content changed size; the hosting panel resizes itself to match.
    var sizeChanged: (CGSize) -> Void = { _ in }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let s = app.snapshot
        VStack(alignment: .leading, spacing: 14) {
            if let detail = app.panelDetail {
                PanelDetailView(detail: detail) { module in show(module, scan: false) }
            } else {
                overview(s)
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .background { PanelBackground(glass: glass).shadow(color: .black.opacity(0.28), radius: 14, y: 8) }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 30)   // room for that shadow
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
    }

    @ViewBuilder private func overview(_ s: SystemSnapshot) -> some View {
            header
            LazyVGrid(columns: columns, spacing: 10) {
                storageTile(s)
                memoryTile(s)
                batteryOrUptimeTile(s)
                processorTile(s)
                networkTile(s)
                devicesTile
            }
            if let message = app.panelMessage {
                Text(message).font(.caption).foregroundStyle(Color.warning).fixedSize(horizontal: false, vertical: true)
            }
            recommendationCard
    }

    // MARK: Header

    private var header: some View {
        let health = app.health
        let color = gradeColor(health.grade)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                (Text("Mac health: ").foregroundStyle(.primary) + Text(health.grade.rawValue).foregroundStyle(color))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(health.concerns.first ?? MacModel.name)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ZStack {
                Circle().stroke(Color.track, lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(health.score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 5)
                Text("\(health.score)").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 46, height: 46)
            .help(health.concerns.isEmpty ? "Nothing is holding your Mac back." : health.concerns.joined(separator: "\n"))
        }
        .padding(.horizontal, 4)
    }

    private func gradeColor(_ grade: HealthAssessment.Grade) -> Color {
        switch grade {
        case .good: .success
        case .fair: .warning
        case .poor: .danger
        }
    }

    // MARK: Tiles

    private func storageTile(_ s: SystemSnapshot) -> some View {
        PanelTile(symbol: "internaldrive.fill", title: "Macintosh HD", module: .spaceLens, open: { app.panelDetail = .storage }) {
            Text("\(Format.bytes(s.diskAvailable)) available")
                .foregroundStyle(s.diskFraction > 0.85 ? Color.warning : .secondary)
            MeterBar(value: s.diskFraction, colors: Module.spaceLens.colors, alarm: s.diskFraction > 0.9)
        } action: {
            TileLink("Free Up") { show(.junk, scan: true) }
        }
    }

    private func memoryTile(_ s: SystemSnapshot) -> some View {
        PanelTile(symbol: "memorychip.fill", title: "Memory", module: .largeFiles, open: { app.panelDetail = .memory }) {
            Text("Pressure \(percent(s.memoryPressure)) · \(Format.bytes(s.memoryUsed)) used").foregroundStyle(.secondary)
            MeterBar(value: s.memoryPressure, colors: Module.largeFiles.colors, alarm: s.memoryPressure > 0.8)
        } action: {
            TileLink("See Apps") { show(.startup, scan: false) }
        }
    }

    @ViewBuilder private func batteryOrUptimeTile(_ s: SystemSnapshot) -> some View {
        if let level = s.batteryLevel {
            PanelTile(symbol: s.batteryCharging ? "battery.100percent.bolt" : "battery.75percent", title: "Battery",
                      trailing: percent(level), module: .maintenance, open: { app.panelDetail = .battery }) {
                Text(s.batteryCharging ? "Charging" : "On battery").foregroundStyle(.secondary)
                if let health = s.batteryHealth, let cycles = s.batteryCycles {
                    Text("Health \(percent(health)) · \(cycles) cycles").foregroundStyle(.tertiary)
                }
            } action: { EmptyView() }
        } else {
            PanelTile(symbol: "clock.fill", title: "Uptime", module: .maintenance) {
                Text(Format.uptime(s.uptime)).foregroundStyle(.secondary)
            } action: { EmptyView() }
        }
    }

    private func processorTile(_ s: SystemSnapshot) -> some View {
        let hot = (s.cpuTemperature ?? 0) > 85
        return PanelTile(symbol: "cpu.fill", title: "Processor",
                         trailing: s.cpuTemperature.map { "\(Int($0.rounded())) °C" },
                         trailingColor: hot ? .danger : ((s.cpuTemperature ?? 0) > 65 ? .warning : .secondary), module: .startup,
                         open: { app.panelDetail = .processor }) {
            Text("Load \(percent(s.cpuUsage))").foregroundStyle(.secondary)
            MeterBar(value: s.cpuUsage, colors: Module.startup.colors, alarm: false)
        } action: { EmptyView() }
    }

    private func networkTile(_ s: SystemSnapshot) -> some View {
        PanelTile(symbol: "network", title: "Network", module: .overview, open: { app.panelDetail = .network }) {
            HStack(spacing: 10) {
                Label(rate(s.networkOut), systemImage: "arrow.up").labelStyle(.titleAndIcon)
                Label(rate(s.networkIn), systemImage: "arrow.down").labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.secondary).monospacedDigit()
            Sparkline(values: app.networkHistory.map(\.down), color: Module.overview.accent).frame(height: 22)
        } action: { EmptyView() }
    }

    private var devicesTile: some View {
        PanelTile(symbol: "externaldrive.fill", title: "Connected", module: .uninstaller) {
            if app.volumes.isEmpty {
                Text("No external drives").foregroundStyle(.tertiary)
            } else {
                ForEach(app.volumes.prefix(3)) { volume in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(volume.name).lineLimit(1).truncationMode(.middle)
                            Text("\(Format.bytes(volume.available)) free").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button { app.eject(volume) } label: { Image(systemName: "eject.fill") }
                            .buttonStyle(.plain).foregroundStyle(Module.overview.accent)
                            .help("Eject \(volume.name)")
                    }
                }
                if app.volumes.count > 3 { Text("+\(app.volumes.count - 3) more").foregroundStyle(.tertiary) }
            }
        } action: { EmptyView() }
    }

    // MARK: Recommendation and footer

    private var recommendationCard: some View {
        let item = app.recommendation
        return VStack(alignment: .leading, spacing: 8) {
            Text("SUGGESTED").font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(item.module.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: item.module.accent.opacity(0.45), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.callout.weight(.semibold))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let title = item.actionTitle {
                HStack {
                    Spacer()
                    Button(title) { show(item.module, scan: item.startsScan) }
                        .buttonStyle(PillButtonStyle(prominent: true, tint: item.module.accent))
                }
            }
        }
        .padding(12)
        .background(PanelTileBackground())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Sweepwell") { show(app.selection, scan: false) }.buttonStyle(PillButtonStyle()).focusable(false)
            Spacer()
            iconButton("gearshape.fill", help: "Settings") {
                dismiss()
                AppDelegate.showSettings()
            }
            iconButton("power", help: "Quit Sweepwell") { NSApp.terminate(nil) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30).background(Color.quietButton, in: Circle())
        }
        .buttonStyle(.plain).focusable(false).help(help)
    }

    // MARK: Helpers

    private func show(_ module: Module, scan: Bool) {
        app.selection = module
        dismiss()
        AppDelegate.showMainWindow()
        if scan { app.startScan(for: module) }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1024 ? "0 KB/s" : "\(Format.bytes(Int64(bytesPerSecond)))/s"
    }
}

// MARK: - Pieces

private struct PanelTile<Content: View, Action: View>: View {
    let symbol: String
    let title: String
    var trailing: String?
    var trailingColor: Color = .secondary
    let module: Module
    /// Opens the per-app breakdown. Tiles without one (connected drives) are not clickable.
    var open: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(module.gradient).frame(width: 18)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(trailingColor) }
                if open != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
            }
            content.font(.caption)
            Spacer(minLength: 0)
            HStack { Spacer(); action }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(PanelTileBackground(highlighted: hovering && open != nil))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        // A tap gesture rather than a wrapping Button, so the links inside a tile
        // ("Free Up", eject) keep their own clicks.
        .onTapGesture { open?() }
        .help(open == nil ? "" : "Show which apps are using it")
    }
}

/// Tiles sit *on* the panel's glass. Glass stacked on glass turns to mud, so they are plain
/// translucent fills with a hairline, which is also what Apple's own panels do.
private struct PanelTileBackground: View {
    var highlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(highlighted ? Color.panelTileHover : Color.panelTile)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
    }
}

private struct TileLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(.caption.weight(.semibold)).foregroundStyle(Module.overview.accent).focusable(false)
    }
}

/// Values change every sample, so nothing here eases between them: an animation per sample
/// means dozens of frames of re-rasterised glass and shadow for a bar moving two pixels.
private struct MeterBar: View {
    let value: Double
    let colors: [Color]
    let alarm: Bool

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Color.track)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(alarm ? AnyShapeStyle(Color.danger) : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
                        .frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                }
        }
        .frame(height: 4)
        .padding(.top, 2)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            // A floor on the scale keeps idle chatter from looking like a spike.
            let peak = max(values.max() ?? 0, 50_000)
            let step = size.width / CGFloat(max(values.count - 1, 1))
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(value / peak) * (size.height - 2))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The panel is one sheet of glass. The dial blends a tinted solid over it, exactly like the
/// cards in the main window, so both respond to the same control.
private struct PanelBackground: View {
    let glass: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let wash = LinearGradient(colors: [Module.overview.colors[1].opacity(0.22), Module.duplicates.colors[0].opacity(0.16)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        if #available(macOS 26.0, *), glass >= 0.05 {
            ZStack {
                // The panel floats over arbitrary windows and their text. Clear glass does not
                // blur, so here the dial only thins the tint and the glass itself stays frosted.
                shape.fill(Color.panelSolid.opacity(max(0.1, 1 - glass)))
                shape.fill(wash)
            }
            .glassEffect(.regular, in: shape)
        } else {
            ZStack {
                VibrantBackground(material: .popover).clipShape(shape)
                shape.fill(Color.panelSolid.opacity(1 - glass * 0.8))
                shape.fill(wash)
                shape.strokeBorder(Color.hairline)
            }
        }
    }
}

enum MacModel {
    /// "MacBook Pro (14-inch, Nov 2024)" from the device tree; the computer's name otherwise.
    static let name: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)), !name.isEmpty {
            return name
        }
        return Host.current().localizedName ?? "This Mac"
    }()
}

/// The "how glassy" dial, shared by the sidebar and Settings.
struct GlassSlider: View {
    @AppStorage(Preferences.glassKey) private var glass = Glassiness.default
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Glass", systemImage: "drop.halffull").font(compact ? .caption.weight(.semibold) : .body)
                Spacer()
                Text(Glassiness.label(glass)).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: Glassiness.label(glass))
            }
            Slider(value: $glass, in: 0...1) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "square.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Image(systemName: "square.dashed").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .controlSize(compact ? .mini : .regular)
            .tint(Module.spaceLens.accent)
            if !compact {
                Text("From solid cards to clear Liquid Glass that lets your desktop through. Applies to the window and the menu bar panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
