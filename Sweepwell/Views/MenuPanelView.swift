import SwiftUI
import AppKit
import SweepwellKit

/// The panel behind the menu bar broom, in the language of Control Center: no container,
/// just separate pieces of Liquid Glass on a four-column grid. Capsules for the vitals,
/// circles for one-tap chores, a large square for the processor, and full-width modules for
/// the status, the glass dial and anything that opens up.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Closes the panel; every action that leaves for a window calls it first.
    var dismiss: () -> Void = {}
    /// The content changed size; the hosting panel resizes itself to match.
    var sizeChanged: (CGSize) -> Void = { _ in }

    /// Which chore has its row open under the grid.
    @State private var tray: Tray?
    enum Tray { case awake, trash }
    @Namespace private var glassSpace

    var body: some View {
        let alerts = app.alerts
        // The container lets modules morph as they open and close. Its spacing is smaller than
        // the gaps, so neighbouring modules stay visibly separate instead of melting together.
        GlassEffectContainer(spacing: PanelGrid.gap / 3) {
            VStack(spacing: PanelGrid.gap) {
                statusModule(alerts)
                HStack(alignment: .top, spacing: PanelGrid.gap) {
                    VStack(spacing: PanelGrid.gap) {
                        vitalCapsule(.disk)
                        vitalCapsule(.memory)
                    }
                    ProcessorSquare(expanded: app.expandedVital == .processor) { toggle(.processor) }
                }
                detailIfExpanded(in: [.disk, .memory, .processor])
                HStack(spacing: PanelGrid.gap) {
                    vitalCapsule(.network)
                    awakeCircle
                    CircleModule(symbol: "eject.fill", help: app.volumes.isEmpty ? "Nothing to eject" : "Eject all \(app.volumes.count) mounted volumes",
                                 caption: app.volumes.isEmpty ? "None" : "\(app.volumes.count) mounted",
                                 disabled: app.volumes.isEmpty) { tray = nil; app.ejectAll() }
                }
                if tray == .awake { awakeTray.morphing("tray-awake", in: glassSpace) }
                detailIfExpanded(in: [.network])
                HStack(spacing: PanelGrid.gap) {
                    CircleModule(symbol: "trash.fill", help: trashHelp, caption: trashCaption, active: tray == .trash, tint: Color.danger,
                                 disabled: app.trash.size == 0 || app.trash.phase == .emptying) {
                        tray = tray == .trash ? nil : .trash
                    }
                    CircleModule(symbol: "sparkles", help: "Smart Scan: opens Sweepwell and looks for junk", caption: "Scan") {
                        show(.overview, scan: true)
                    }
                    if app.snapshot.batteryLevel != nil { vitalCapsule(.battery) } else { uptimeCapsule }
                }
                if tray == .trash { trashTray.morphing("tray-trash", in: glassSpace) }
                detailIfExpanded(in: [.battery])
                GlassDialModule()
                if let message = app.panelMessage {
                    WideModule {
                        Label(message, systemImage: "info.circle").font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: PanelGrid.gap) {
                    CircleModule(symbol: "gearshape.fill", help: "Settings", caption: "Settings") { registerOpeners(); dismiss(); AppDelegate.showSettings() }
                    CircleModule(symbol: "power", help: "Quit Sweepwell", caption: "Quit") { NSApp.terminate(nil) }
                    ledgerModule
                }
            }
            .animation(.spring(duration: 0.35), value: app.expandedVital)
            .animation(.spring(duration: 0.35), value: tray)
        }
        .frame(width: PanelGrid.width)
        .padding(14)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
        .onChange(of: app.panelVisible) { _, visible in
            if !visible { tray = nil; return }
            registerOpeners()
            // UI check: open a chore's row as the panel appears.
            switch ProcessInfo.processInfo.environment["SWEEPWELL_PANEL_TRAY"] {
            case "trash": tray = .trash
            case "awake": tray = .awake
            default: break
            }
        }
    }

    // MARK: Status

    /// The one full-width module up top: how things are, in words, and anything worth a look.
    private func statusModule(_ alerts: [PanelAlert]) -> some View {
        let s = app.snapshot
        let worst = alerts.first?.severity
        let headline = switch worst {
        case nil: "All clear"
        case .urgent?: "Needs a look"
        default: "Worth a glance"
        }
        var facts = [MacModel.name, "up \(Format.uptime(s.uptime))"]
        if let watts = s.power.systemWatts { facts.append("drawing \(Int(watts.rounded())) W") }

        let shownAlerts = app.expandedVital == nil ? 3 : 1
        return WideModule {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconDisc(symbol: worst == nil ? "checkmark" : "exclamationmark",
                             color: worst?.color ?? Module.overview.accent, on: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline).font(.system(size: 15, weight: .semibold))
                        Text(facts.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(facts.joined(separator: " · "))
                    }
                    Spacer(minLength: 0)
                }
                ForEach(alerts.prefix(shownAlerts)) { alert in
                    HStack(spacing: 8) {
                        Image(systemName: alert.symbol).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(alert.severity.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(alert.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(alert.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let action = alert.action {
                            Button(action.title) { perform(action) }
                                .buttonStyle(.plain).focusable(false)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.quietButton, in: Capsule())
                        }
                    }
                    .help(alert.title + "\n" + alert.detail)
                }
                if alerts.count > shownAlerts {
                    Text("+\(alerts.count - shownAlerts) more").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
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

    private func vitalCapsule(_ vital: Vital) -> some View {
        let s = app.snapshot
        let (title, subtitle) = Self.summary(vital, s, top: vital.top(app.appUsage, limit: 1).first)
        return CapsuleModule(symbol: vital.symbol, color: vital.module.accent, title: title, subtitle: subtitle,
                             expanded: app.expandedVital == vital, graph: graph(vital, s)) { toggle(vital) }
            .help(fullCaption(vital, s) + "\nClick to see what is using it.")
    }

    /// The vital's live graph or bar, as in the vitals list.
    private func graph(_ vital: Vital, _ s: SystemSnapshot) -> AnyView {
        switch vital {
        case .memory: AnyView(Sparkline(values: app.pressureHistory, color: vital.module.colors[0], ceiling: 1))
        case .network: AnyView(Sparkline(values: app.networkHistory.map(\.down), color: Module.overview.accent, ceiling: nil))
        case .disk: AnyView(DiskBar(snapshot: s).frame(height: 5).frame(maxHeight: .infinity))
        case .battery: AnyView(MeterBar(value: s.batteryLevel ?? 0, colors: vital.module.colors).frame(maxHeight: .infinity))
        case .processor: AnyView(Sparkline(values: app.cpuHistory, color: vital.module.colors[1], ceiling: 1))
        }
    }

    /// Everything the vital's row used to say on one line, led by its biggest consumer.
    private func fullCaption(_ vital: Vital, _ s: SystemSnapshot) -> String {
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
            var parts = ["\(Format.bytes(s.diskAvailable)) free of \(Format.bytes(s.diskTotal))"]
            if s.diskPurgeable > 256 << 20 { parts.append("\(Format.bytes(s.diskPurgeable)) purgeable") }
            if !app.volumes.isEmpty { parts.append("\(app.volumes.count) mounted") }
            return parts.joined(separator: " · ")
        case .battery:
            let p = s.power
            var parts: [String] = []
            if p.charging { parts.append(p.minutesRemaining.map { "full in \(VitalDuration.text($0))" } ?? "Charging") }
            else if p.onAdapter { parts.append("On power adapter") }
            else { parts.append(p.minutesRemaining.map { "\(VitalDuration.text($0)) left" } ?? "On battery") }
            if let watts = p.systemWatts { parts.append(String(format: "Mac draws %.1f W", watts)) }
            return parts.joined(separator: " · ")
        case .network:
            var parts = ["↓ \(Vital.rate(s.networkIn))", "↑ \(Vital.rate(s.networkOut))"]
            if let link = s.link { parts.insert(link.kind.rawValue, at: 0); if link.vpnActive { parts.insert("VPN on", at: 1) } }
            else { parts.insert("Offline", at: 0) }
            return parts.joined(separator: " · ")
        }
    }

    private var uptimeCapsule: some View {
        CapsuleModule(symbol: "clock.fill", color: Module.maintenance.accent, title: "Uptime",
                      subtitle: Format.uptime(app.snapshot.uptime), expanded: false) {}
    }

    /// The two lines a vital shows in its capsule.
    static func summary(_ vital: Vital, _ s: SystemSnapshot, top: AppUsage?) -> (String, String) {
        switch vital {
        case .disk:
            var tail = "of \(Format.bytes(s.diskTotal))"
            if s.diskPurgeable > 1 << 30 { tail = "\(Format.bytes(s.diskPurgeable)) purgeable" }
            return ("\(Format.bytes(s.diskAvailable)) free", tail)
        case .memory:
            let detail = top.map { "\($0.name) \(Format.bytes($0.memory))" }
                ?? (s.swap.map { $0.used > 256 << 20 ? "\(Format.bytes($0.used)) swap" : "\(Format.bytes(s.memoryUsed)) used" } ?? "")
            return ("Memory \(Int((s.memoryPressure * 100).rounded()))%", detail)
        case .network:
            let link = s.link.map { $0.vpnActive ? "VPN" : $0.kind.rawValue } ?? "Offline"
            return ("↓ \(Vital.rate(s.networkIn))", "↑ \(Vital.rate(s.networkOut)) · \(link)")
        case .battery:
            let p = s.power
            let level = s.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
            var detail = p.charging ? "Charging" : (p.onAdapter ? "Adapter" : (p.minutesRemaining.map { "\(VitalDuration.text($0)) left" } ?? "Battery"))
            if let watts = p.systemWatts { detail += String(format: " · %.0f W", watts) }
            return ("Power \(level)", detail)
        case .processor:
            return ("\(Int((s.cpuUsage * 100).rounded()))%", top.map { "\($0.name) \(vital.describe($0))" } ?? "")
        }
    }

    private func toggle(_ vital: Vital) {
        app.expandedVital = app.expandedVital == vital ? nil : vital
    }

    /// The opened-up vital, as a full-width module right under its row.
    @ViewBuilder private func detailIfExpanded(in row: [Vital]) -> some View {
        if let vital = app.expandedVital, row.contains(vital) {
            WideModule {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: vital.symbol).foregroundStyle(vital.module.gradient)
                        Text(vital.title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button { app.expandedVital = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20).background(Color.quietButton, in: Circle())
                        }
                        .buttonStyle(.plain).focusable(false).help("Close")
                    }
                    VitalDetail(vital: vital) { show($0, scan: false) }
                }
            }
            .morphing("detail-\(vital.rawValue)", in: glassSpace)
        }
    }

    // MARK: Chores

    private var awakeCircle: some View {
        let awake = app.keepAwake
        _ = app.keepAwakeRevision
        let help: String = {
            guard awake.isActive else { return "Keep Awake: stop this Mac from sleeping" }
            guard let end = awake.endsAt else { return "Awake until you turn it off. Click to stop." }
            return "Awake for \(VitalDuration.text(max(1, Int(end.timeIntervalSinceNow / 60)))) more. Click to stop."
        }()
        let caption: String = {
            guard awake.isActive else { return "No sleep" }
            guard let end = awake.endsAt else { return "Awake ∞" }
            return VitalDuration.text(max(1, Int(end.timeIntervalSinceNow / 60)))
        }()
        return CircleModule(symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", help: help, caption: caption,
                            active: awake.isActive || tray == .awake, tint: Module.startup.colors[0]) {
            if awake.isActive { app.toggleKeepAwake(for: nil); tray = nil } else { tray = tray == .awake ? nil : .awake }
        }
    }

    private var awakeTray: some View {
        WideModule(shape: .capsule) {
            HStack(spacing: 6) {
                Text("Stay awake for").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach([("30 m", 1800.0), ("1 h", 3600.0), ("3 h", 10_800.0)], id: \.0) { label, seconds in
                    trayButton(label) { app.toggleKeepAwake(for: seconds); tray = nil }
                }
                trayButton("∞") { app.toggleKeepAwake(for: nil); tray = nil }.help("Until you turn it off or quit Sweepwell")
            }
        }
    }

    private var trashTray: some View {
        WideModule {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(trashQuestion).font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This can't be undone").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                trayButton("Cancel") { tray = nil }
                trayButton("Empty", prominent: true) { app.emptyTrash(); tray = nil }
            }
        }
    }

    private var trashCaption: String {
        if let size = app.trash.size { return size == 0 ? "Empty" : Format.bytes(size) }
        return "Trash"
    }

    private var trashHelp: String {
        if let size = app.trash.size { return size == 0 ? "The Trash is empty" : "Empty Trash (\(Format.bytes(size)))" }
        return "Empty Trash"
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
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.danger) : AnyShapeStyle(Color.quietButton), in: Capsule())
    }

    // MARK: Ledger

    private var ledgerModule: some View {
        let ledger = app.ledger
        let since = ledger.since.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
        // Opens the main window; doubles as the running total of what has been swept.
        return CapsuleModule(symbol: "BroomGlyph", isAsset: true, color: Module.overview.accent,
                             title: "Open Sweepwell",
                             subtitle: ledger.sweeps == 0 ? "Nothing swept yet"
                                : "\(Format.bytes(ledger.bytes)) since \(since ?? "")" + (ledger.last.map { ", last \($0.formatted(.relative(presentation: .named)))" } ?? ""),
                             expanded: false) { show(app.selection, scan: false) }
            .help(ledger.last.map { "Last sweep \($0.formatted(.relative(presentation: .named)))" } ?? "Open the Sweepwell window")
    }

    // MARK: Helpers

    /// The panel always exists, unlike the main window (which macOS may never build when it
    /// starts Sweepwell at login), so its own window actions are the reliable ones.
    private func registerOpeners() {
        AppDelegate.panelOpenMainWindow = { openWindow(id: "main") }
        AppDelegate.panelOpenSettings = { openSettings() }
    }

    private func show(_ module: Module, scan: Bool) {
        app.selection = module
        registerOpeners()
        dismiss()
        AppDelegate.showMainWindow()
        if scan { app.startScan(for: module) }
    }
}

// MARK: - Grid and modules

/// Control Center's grid: square units with even gaps.
private enum PanelGrid {
    static let unit: CGFloat = 74
    static let gap: CGFloat = 12
    static let width = unit * 4 + gap * 3
    static let double = unit * 2 + gap
}

enum VitalDuration {
    static func text(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

/// One piece of panel glass. The dial lays a thin tint inside it: more glass, less tint.
private struct GlassModule<S: Shape>: ViewModifier {
    @AppStorage(Preferences.glassKey) private var dial = Glassiness.default
    let shape: S
    var interactive = false
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(Color.panelSolid.opacity(max(0, 1 - dial * 1.25) * 0.7), in: shape)
            .glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }
}

private extension View {
    func glassModule<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassModule(shape: shape, interactive: interactive, tint: tint))
    }

    func morphing(_ id: String, in space: Namespace.ID) -> some View {
        glassEffectID(id, in: space).glassEffectTransition(.matchedGeometry)
    }
}

/// A two-unit capsule: badge, title, one line of detail. Tapping it opens the vital.
private struct CapsuleModule: View {
    let symbol: String
    var isAsset = false
    let color: Color
    let title: String
    let subtitle: String
    let expanded: Bool
    var compact = false
    /// The vital's graph or bar, under its two lines of text.
    var graph: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconDisc(symbol: symbol, isAsset: isAsset, color: color, size: compact ? 32 : 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    if let graph { graph.frame(height: 10).padding(.top, 3) }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 11).padding(.trailing, 10)
            .frame(width: PanelGrid.double, height: PanelGrid.unit)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).focusable(false)
        .glassModule(Capsule(), interactive: true, tint: expanded ? color.opacity(0.35) : nil)
    }
}

/// A one-unit circle: a single chore. Filled white while it is on, like a Control Center toggle.
private struct CircleModule: View {
    let symbol: String
    let help: String
    /// A word or two under the icon: what the chore does, or its state.
    var caption: String? = nil
    var active = false
    var tint: Color = .primary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: caption == nil ? 20 : 17, weight: .medium))
                if let caption {
                    Text(caption).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                }
            }
                .foregroundStyle(active ? AnyShapeStyle(tint == .primary ? Color.black : tint) : AnyShapeStyle(.primary))
                .frame(width: PanelGrid.unit, height: PanelGrid.unit)
                .background(active ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).focusable(false)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .glassModule(Circle(), interactive: !disabled)
        .help(help)
    }
}

/// A four-unit-wide module: status, trays, details, the glass dial.
private struct WideModule<Content: View>: View {
    enum Shape { case rounded, capsule }
    var shape: Shape = .rounded
    @ViewBuilder var content: Content

    var body: some View {
        let padded = content
            .padding(.horizontal, shape == .capsule ? 18 : 16)
            .padding(.vertical, shape == .capsule ? 10 : 14)
            .frame(width: PanelGrid.width, alignment: .leading)
        switch shape {
        case .rounded: padded.glassModule(RoundedRectangle(cornerRadius: 30, style: .continuous))
        case .capsule: padded.glassModule(Capsule())
        }
    }
}

/// The big two-by-two square, like Now Playing: the processor, with its own graph.
private struct ProcessorSquare: View {
    @Environment(AppModel.self) private var app
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        let s = app.snapshot
        let top = Vital.processor.top(app.appUsage, limit: 1).first
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    IconDisc(symbol: Vital.processor.symbol, color: Module.startup.colors[1], on: true, size: 34)
                    Spacer()
                    if let t = s.cpuTemperature {
                        Text("\(Int(t.rounded()))°").font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(t >= 90 ? Color.danger : (t >= 70 ? Color.warning : .secondary))
                    }
                }
                Spacer(minLength: 0)
                Text("\(Int((s.cpuUsage * 100).rounded()))%").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text(top.map { "\($0.name) \(Vital.processor.describe($0))" } ?? "Processor")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                if let load = s.loadAverage.first {
                    Text(String(format: "load %.1f", load) + (s.cpuTemperature.map { " · \(Int($0.rounded())) °C" } ?? ""))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Sparkline(values: app.cpuHistory, color: Module.startup.colors[1], ceiling: 1).frame(height: 20)
            }
            .padding(14)
            .frame(width: PanelGrid.double, height: PanelGrid.double)
            .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .buttonStyle(.plain).focusable(false)
        .glassModule(RoundedRectangle(cornerRadius: 34, style: .continuous), interactive: true,
                     tint: expanded ? Module.startup.colors[1].opacity(0.35) : nil)
        .help("Processor: show what is using it")
    }
}

/// The glass dial, styled like Control Center's Display slider.
private struct GlassDialModule: View {
    @AppStorage(Preferences.glassKey) private var dial = Glassiness.default

    var body: some View {
        WideModule {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Glass").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(Glassiness.label(dial)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "square.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $dial, in: 0...1).controlSize(.small).tint(.white)
                    Image(systemName: "square.dashed").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
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

// MARK: - Small pieces

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
