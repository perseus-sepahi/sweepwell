import SwiftUI
import AppKit
import SweepwellKit

/// The panel behind the menu bar broom: a plain-language status line, anything that needs a
/// look, a stack of live vitals that open up into the apps behind each number, and a row of
/// one-tap chores.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.glassKey) private var glass = Glassiness.default
    /// Closes the panel; every action that leaves for a window calls it first.
    var dismiss: () -> Void = {}
    /// The content changed size; the hosting panel resizes itself to match.
    var sizeChanged: (CGSize) -> Void = { _ in }

    /// Which chore has its little confirmation tray open under the keys.
    @State private var tray: Tray?
    enum Tray { case awake, trash }

    var body: some View {
        let alerts = app.alerts
        VStack(alignment: .leading, spacing: 12) {
            header(alerts)
            if !alerts.isEmpty { alertList(alerts) }
            vitals
            chores
            if let message = app.panelMessage {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 384)
        .background { PanelBackground(glass: glass).shadow(color: .black.opacity(0.28), radius: 14, y: 8) }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 30)   // room for that shadow
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
        .onChange(of: app.panelVisible) { _, visible in if !visible { tray = nil } }
    }

    // MARK: Header

    private func header(_ alerts: [PanelAlert]) -> some View {
        let s = app.snapshot
        let worst = alerts.first?.severity
        let headline = switch worst {
        case nil: "All clear"
        case .urgent?: "Needs a look"
        default: "Worth a glance"
        }
        var facts = [MacModel.name, "up \(Format.uptime(s.uptime))"]
        if let watts = s.power.systemWatts { facts.append("drawing \(Int(watts.rounded())) W") }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("BroomGlyph").resizable().renderingMode(.template).foregroundStyle(.white)
                    .frame(width: 13, height: 13).frame(width: 22, height: 22)
                    .background(Module.overview.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("Sweepwell").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                iconButton("gearshape", help: "Settings") { dismiss(); AppDelegate.showSettings() }
                iconButton("macwindow", help: "Open Sweepwell") { show(app.selection, scan: false) }
                iconButton("power", help: "Quit Sweepwell") { NSApp.terminate(nil) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(worst?.color ?? Module.overview.accent)
                Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24).background(Color.quietButton, in: Circle())
        }
        .buttonStyle(.plain).focusable(false).help(help)
    }

    // MARK: Heads-up

    private func alertList(_ alerts: [PanelAlert]) -> some View {
        VStack(spacing: 6) {
            ForEach(alerts.prefix(app.expandedVital == nil ? 3 : 1)) { alert in AlertRow(alert: alert, perform: perform) }
            if alerts.count > (app.expandedVital == nil ? 3 : 1) {
                Text("+\(alerts.count - (app.expandedVital == nil ? 3 : 1)) more").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func perform(_ action: PanelAlert.Action) {
        switch action {
        case .quit(let running): running.terminate()
        case .expand(let vital): app.expandedVital = vital
        case .open(let module, let scan): show(module, scan: scan)
        }
    }

    // MARK: Vitals

    private var vitals: some View {
        let rows = Vital.allCases.filter { $0 != .battery || app.snapshot.batteryLevel != nil }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, vital in
                if index > 0 { Color.hairline.frame(height: 1).padding(.leading, 48) }
                VitalRow(vital: vital, expanded: app.expandedVital == vital) {
                    app.expandedVital = app.expandedVital == vital ? nil : vital
                } openModule: { show($0, scan: false) }
            }
        }
        .padding(.vertical, 4)
        .background(PanelCard())
    }

    // MARK: Chores

    private var chores: some View {
        let awake = app.keepAwake
        _ = app.keepAwakeRevision
        let awakeTitle: String = {
            guard awake.isActive else { return "Keep Awake" }
            guard let end = awake.endsAt else { return "Awake · ∞" }
            let minutes = max(1, Int(end.timeIntervalSinceNow / 60))
            return minutes >= 60 ? "Awake · \(minutes / 60) h \(minutes % 60) m" : "Awake · \(minutes) m"
        }()
        let trashCaption: String = {
            if let size = app.trash.size { return size == 0 ? "Empty" : Format.bytes(size) }
            return "Finder"
        }()
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                ChoreKey(symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", title: awakeTitle,
                         caption: awake.isActive ? "Tap to stop" : "No sleep", active: awake.isActive, tint: Module.startup.colors[0]) {
                    if awake.isActive { app.toggleKeepAwake(for: nil); tray = nil } else { tray = tray == .awake ? nil : .awake }
                }
                ChoreKey(symbol: "trash", title: "Empty Trash", caption: trashCaption, active: tray == .trash,
                         tint: Module.uninstaller.colors[0], disabled: app.trash.size == 0 || app.trash.phase == .emptying) {
                    tray = tray == .trash ? nil : .trash
                }
                ChoreKey(symbol: "eject", title: "Eject All",
                         caption: app.volumes.isEmpty ? "Nothing mounted" : "\(app.volumes.count) volume\(app.volumes.count == 1 ? "" : "s")",
                         active: false, tint: Module.spaceLens.colors[0], disabled: app.volumes.isEmpty) {
                    tray = nil
                    app.ejectAll()
                }
                ChoreKey(symbol: "sparkles", title: "Smart Scan", caption: "Opens Sweepwell", active: false,
                         tint: Module.overview.colors[0]) {
                    show(.overview, scan: true)
                }
            }
            if let tray { trayView(tray) }
        }
    }

    @ViewBuilder private func trayView(_ tray: Tray) -> some View {
        HStack(spacing: 8) {
            switch tray {
            case .awake:
                Text("Keep this Mac awake for").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach([("30 m", 1800.0), ("1 h", 3600.0), ("3 h", 10_800.0)], id: \.0) { label, seconds in
                    trayButton(label) { app.toggleKeepAwake(for: seconds); self.tray = nil }
                }
                trayButton("∞") { app.toggleKeepAwake(for: nil); self.tray = nil }
                    .help("Until you turn it off or quit Sweepwell")
            case .trash:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning).font(.caption)
                Text(trashQuestion).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                trayButton("Cancel") { self.tray = nil }
                trayButton("Empty", prominent: true) { app.emptyTrash(); self.tray = nil }
            }
        }
        .padding(10)
        .background(PanelCard())
    }

    private var trashQuestion: String {
        if let size = app.trash.size, let items = app.trash.items {
            return "Delete \(items) item\(items == 1 ? "" : "s") (\(Format.bytes(size))) for good?"
        }
        return "Delete everything in the Trash for good?"
    }

    private func trayButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).focusable(false)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.danger) : AnyShapeStyle(Color.quietButton), in: Capsule())
    }

    // MARK: Footer

    private var footer: some View {
        let ledger = app.ledger
        let since = ledger.since.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
        return HStack(spacing: 6) {
            Image("BroomGlyph").resizable().renderingMode(.template).frame(width: 11, height: 11).foregroundStyle(.tertiary)
            if ledger.sweeps == 0 {
                Text("Nothing swept yet").foregroundStyle(.secondary)
            } else {
                Text("\(Format.bytes(ledger.bytes)) swept since \(since ?? "")").foregroundStyle(.secondary)
            }
            Spacer()
            if let last = ledger.last {
                Text("last \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 2)
    }

    // MARK: Helpers

    private func show(_ module: Module, scan: Bool) {
        app.selection = module
        dismiss()
        AppDelegate.showMainWindow()
        if scan { app.startScan(for: module) }
    }
}

// MARK: - Rows

private struct VitalRow: View {
    @Environment(AppModel.self) private var app
    let vital: Vital
    let expanded: Bool
    let toggle: () -> Void
    let openModule: (Module) -> Void
    @State private var hovering = false

    var body: some View {
        let s = app.snapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: vital.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(vital.module.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(vital.title).font(.callout.weight(.semibold))
                        Spacer(minLength: 6)
                        Text(value(s)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(valueColor(s))
                    }
                    Text(caption(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    graph(s).frame(height: 16).padding(.top, 2)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering || expanded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(hovering && !expanded ? Color.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovering = $0 }
            .help(expanded ? "" : "Show what is using it")

            if expanded {
                VitalDetail(vital: vital, openModule: openModule)
                    .padding(.horizontal, 11).padding(.bottom, 10)
            }
        }
    }

    private func value(_ s: SystemSnapshot) -> String {
        switch vital {
        case .processor: "\(Int((s.cpuUsage * 100).rounded()))%"
        case .memory: "\(Int((s.memoryPressure * 100).rounded()))% pressure"
        case .disk: "\(Format.bytes(s.diskAvailable)) free"
        case .battery: s.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        case .network: "↓ \(Vital.rate(s.networkIn))"
        }
    }

    private func valueColor(_ s: SystemSnapshot) -> Color {
        switch vital {
        case .disk where s.diskTotal > 0 && Double(s.diskAvailable) / Double(s.diskTotal) < 0.1: .warning
        case .memory where s.memoryPressure > 0.8: .danger
        case .processor where (s.cpuTemperature ?? 0) >= 90: .danger
        default: .primary
        }
    }

    /// One line of context, led by the biggest consumer once per-app figures are in.
    private func caption(_ s: SystemSnapshot) -> String {
        let top = vital.top(app.appUsage, limit: 1).first
        func lead(_ tail: [String]) -> String {
            ((top.map { ["\($0.name) \(vital.describe($0))"] } ?? []) + tail).joined(separator: " · ")
        }
        switch vital {
        case .processor:
            return lead([s.cpuTemperature.map { "\(Int($0.rounded())) °C" }, s.loadAverage.first.map { String(format: "load %.1f", $0) }].compactMap { $0 })
        case .memory:
            var tail = ["\(Format.bytes(s.memoryUsed)) in use"]
            if let swap = s.swap, swap.used > 256 << 20 { tail.append("\(Format.bytes(swap.used)) swap") }
            return lead(tail)
        case .disk:
            var parts = ["of \(Format.bytes(s.diskTotal))"]
            if s.diskPurgeable > 256 << 20 { parts.append("\(Format.bytes(s.diskPurgeable)) purgeable") }
            if !app.volumes.isEmpty { parts.append("\(app.volumes.count) mounted") }
            return parts.joined(separator: " · ")
        case .battery:
            let p = s.power
            var parts: [String] = []
            if p.charging { parts.append(p.minutesRemaining.map { "full in \(Self.duration($0))" } ?? "Charging") }
            else if p.onAdapter { parts.append("On power adapter") }
            else { parts.append(p.minutesRemaining.map { "\(Self.duration($0)) left" } ?? "On battery") }
            if let watts = p.systemWatts { parts.append(String(format: "Mac draws %.1f W", watts)) }
            return parts.joined(separator: " · ")
        case .network:
            var parts = ["↑ \(Vital.rate(s.networkOut))"]
            if let link = s.link { parts.insert(link.kind.rawValue, at: 0); if link.vpnActive { parts.insert("VPN on", at: 1) } }
            else { parts.insert("Offline", at: 0) }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder private func graph(_ s: SystemSnapshot) -> some View {
        switch vital {
        case .processor: Sparkline(values: app.cpuHistory, color: vital.module.colors[1], ceiling: 1)
        case .memory: Sparkline(values: app.pressureHistory, color: vital.module.colors[0], ceiling: 1)
        case .network: Sparkline(values: app.networkHistory.map(\.down), color: Module.overview.accent, ceiling: nil)
        case .disk: DiskBar(snapshot: s).frame(height: 6).frame(maxHeight: .infinity)
        case .battery: MeterBar(value: s.batteryLevel ?? 0, colors: vital.module.colors).frame(maxHeight: .infinity)
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

/// What opens under a vital: the facts behind the number, then the apps behind it.
private struct VitalDetail: View {
    @Environment(AppModel.self) private var app
    let vital: Vital
    let openModule: (Module) -> Void

    var body: some View {
        let s = app.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(facts(s), id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value).monospacedDigit().textSelection(.enabled)
                    }
                }
            }
            .font(.caption)

            if vital == .disk, !app.volumes.isEmpty { volumes }

            Text(vital.rankingLabel.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(0.6).foregroundStyle(.tertiary)
            let rows = vital.top(app.appUsage, limit: 4)
            if rows.isEmpty {
                Text(app.appUsage.isEmpty ? "Measuring…" : "Nothing right now.").font(.caption).foregroundStyle(.tertiary)
            } else {
                let peak = rows.first.map(vital.value) ?? 1
                VStack(spacing: 1) {
                    ForEach(rows) { usage in
                        UsageRow(usage: usage, vital: vital, fraction: vital.value(of: usage) / max(peak, 0.0001))
                    }
                }
            }
            HStack {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(vital == .disk ? "Space Lens" : "Details") { openModule(vital == .disk ? .spaceLens : .startup) }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Module.overview.accent).focusable(false)
            }
        }
        .padding(.leading, 36)
    }

    private var volumes: some View {
        VStack(spacing: 4) {
            ForEach(app.volumes) { volume in
                HStack(spacing: 8) {
                    Image(systemName: volume.isDiskImage ? "opticaldiscdrive" : "externaldrive").foregroundStyle(.secondary).frame(width: 16)
                    Text(volume.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Format.bytes(volume.available)) free").foregroundStyle(.tertiary).monospacedDigit()
                    Button { app.eject(volume) } label: { Image(systemName: "eject.fill") }
                        .buttonStyle(.plain).foregroundStyle(Module.overview.accent).help("Eject \(volume.name)")
                }
                .font(.caption)
            }
        }
    }

    private var footnote: String {
        switch vital {
        case .processor: "100% is one core of \(ProcessInfo.processInfo.activeProcessorCount). Helpers count with their app."
        case .memory: "Real footprint, as Activity Monitor shows it."
        case .disk: "Live reads and writes, not space used."
        case .battery: "Estimated per app; macOS services are not included."
        case .network: "Live traffic. Idle apps are not listed."
        }
    }

    private func facts(_ s: SystemSnapshot) -> [(String, String)] {
        switch vital {
        case .processor:
            var rows: [(String, String)] = []
            if s.loadAverage.count == 3 { rows.append(("Load 1 · 5 · 15 min", s.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: " · "))) }
            if let t = s.cpuTemperature { rows.append(("Hottest core", "\(Int(t.rounded())) °C")) }
            rows.append(("Thermal state", thermal(s.thermalState)))
            return rows
        case .memory:
            var rows = [("In use", "\(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal))"),
                        ("Compressed", Format.bytes(s.memoryCompressed))]
            if let swap = s.swap { rows.append(("Swap", "\(Format.bytes(swap.used)) of \(Format.bytes(swap.total))")) }
            return rows
        case .disk:
            return [("Used", Format.bytes(max(0, s.diskTotal - s.diskAvailable))),
                    ("Purgeable", "\(Format.bytes(s.diskPurgeable)), freed by macOS when needed"),
                    ("Free now", Format.bytes(s.diskFree))]
        case .battery:
            let p = s.power
            var rows: [(String, String)] = []
            if let watts = p.systemWatts { rows.append(("Whole Mac draws", String(format: "%.1f W", watts))) }
            if let adapter = p.adapterWatts, p.onAdapter { rows.append(("Adapter", "\(adapter) W\(p.charging ? ", charging" : ", holding charge")")) }
            if let health = s.batteryHealth { rows.append(("Battery health", "\(Int((health * 100).rounded()))%\(s.batteryCycles.map { " · \($0) cycles" } ?? "")")) }
            if let t = p.batteryTemperature { rows.append(("Battery temperature", String(format: "%.0f °C", t))) }
            return rows
        case .network:
            var rows: [(String, String)] = []
            if let link = s.link {
                rows.append(("Connection", "\(link.kind.rawValue) (\(link.interface))"))
                rows.append(("Address", link.address))
                rows.append(("VPN", link.vpnActive ? "Connected" : "Off"))
            }
            let totals = NetworkCounters.current()
            rows.append(("Since startup", "↓ \(Format.bytes(Int64(totals.received))) · ↑ \(Format.bytes(Int64(totals.sent)))"))
            return rows
        }
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot, throttling"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

private struct UsageRow: View {
    let usage: AppUsage
    let vital: Vital
    let fraction: Double
    @State private var hovering = false

    /// Only regular apps get a Quit button: ending a daemon by hand is never the fix.
    private var quittable: NSRunningApplication? {
        guard hovering else { return nil }
        return usage.pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let bundle = usage.bundleURL { FileIcon(url: bundle, size: 18) } else {
                Image(systemName: "gearshape.2.fill").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 18, height: 18)
            }
            Text(usage.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if usage.processCount > 1 {
                Text("\(usage.processCount)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .help("\(usage.processCount) processes")
            }
            Spacer(minLength: 4)
            if let running = quittable {
                Button("Quit") { running.terminate() }.buttonStyle(.plain)
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.danger).focusable(false)
            }
            Text(vital.describe(usage)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(alignment: .leading) {
            // The bar sits behind the row, so the list reads as a chart at a glance.
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(vital.module.colors[0].opacity(0.14))
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct AlertRow: View {
    let alert: PanelAlert
    let perform: (PanelAlert.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(alert.severity.color).frame(width: 3)
            Image(systemName: alert.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(alert.severity.color)
                .frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(alert.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let action = alert.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.plain).focusable(false)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(alert.severity.color.opacity(0.16), in: Capsule())
                    .foregroundStyle(alert.severity.color)
            }
        }
        .padding(.vertical, 7).padding(.trailing, 10).padding(.leading, 6)
        .background(PanelCard())
        .help(alert.title + "\n" + alert.detail)
    }
}

// MARK: - Chore keys

private struct ChoreKey: View {
    let symbol: String
    let title: String
    let caption: String
    let active: Bool
    let tint: Color
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(tint))
                    .frame(height: 20)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(active ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
                Text(caption).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(active ? AnyShapeStyle(Color.onAccent.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(hovering ? Color.panelTileHover : Color.panelTile))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).focusable(false)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - Small pieces

/// Content sits *on* the panel's glass. Glass on glass turns to mud, so cards are plain
/// translucent fills with a hairline.
private struct PanelCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.panelTile)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
    }
}

/// Used, purgeable and free space as one bar: purgeable is the part people misread as used.
private struct DiskBar: View {
    let snapshot: SystemSnapshot

    var body: some View {
        let total = Double(max(snapshot.diskTotal, 1))
        let used = Double(max(0, snapshot.diskTotal - snapshot.diskAvailable)) / total
        let purgeable = Double(snapshot.diskPurgeable) / total
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                Capsule().fill(LinearGradient(colors: Module.spaceLens.colors.reversed(), startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * used)
                if purgeable > 0.002 {
                    Capsule().fill(Module.spaceLens.colors[0].opacity(0.35)).frame(width: max(2, proxy.size.width * purgeable))
                }
                Capsule().fill(Color.track)
            }
        }
    }
}

/// Values change every sample, so nothing here eases between them: an animation per sample
/// means dozens of frames of re-rasterised glass for a bar moving two pixels.
private struct MeterBar: View {
    let value: Double
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Color.track)
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                }
        }
        .frame(height: 6)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color
    /// Fixed top of the scale (1 for fractions); nil scales to the data, with a floor so idle
    /// chatter does not look like a spike.
    let ceiling: Double?

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else {
                context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(color.opacity(0.3)))
                return
            }
            let peak = ceiling ?? max(values.max() ?? 0, 50_000)
            // Newest sample on the right; the line fills in from the right as history builds.
            let step = size.width / 44
            let start = size.width - CGFloat(values.count - 1) * step
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + CGFloat(index) * step,
                                    y: size.height - 1 - CGFloat(min(1, value / max(peak, 0.0001))) * (size.height - 2))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
