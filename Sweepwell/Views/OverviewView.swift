import SwiftUI
import SweepwellKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ModuleScaffold(module: .overview) {
            ScrollView {
                VStack(spacing: 22) {
                    gauges
                    if model.smartScanRunning {
                        ScanningView(module: .overview, control: model.junk.control, title: "Looking around your Mac…")
                            .frame(height: 330)
                    } else if model.smartScanDone {
                        results
                    } else {
                        VStack(spacing: 18) {
                            Text("Ready when you are").font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("Smart Scan checks for junk, heavy forgotten files and broken startup items in one pass. Nothing is removed until you say so.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                            OrbButton(title: "Smart\nScan", module: .overview, diameter: 150) { model.smartScan() }
                        }
                        .padding(.top, 26)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var gauges: some View {
        let s = model.snapshot
        return HStack(spacing: 14) {
            GaugeTile(title: "Processor", value: s.cpuUsage, caption: thermalCaption(s.thermalState),
                      symbol: "cpu", colors: Module.startup.colors)
            GaugeTile(title: "Memory", value: s.memoryFraction,
                      caption: "\(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal))",
                      symbol: "memorychip", colors: Module.largeFiles.colors)
            GaugeTile(title: "Storage", value: s.diskFraction, caption: "\(Format.bytes(s.diskAvailable)) available",
                      symbol: "internaldrive", colors: Module.spaceLens.colors)
            if let battery = s.batteryLevel {
                GaugeTile(title: "Battery", value: battery, caption: s.batteryCharging ? "Charging" : "On battery",
                          symbol: s.batteryCharging ? "battery.100.bolt" : "battery.75", colors: Module.maintenance.colors)
            } else {
                GaugeTile(title: "Uptime", value: nil, caption: "since last restart", symbol: "clock",
                          colors: Module.maintenance.colors, centerText: Format.uptime(s.uptime))
            }
        }
    }

    private func thermalCaption(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Running cool"
        case .fair: "Slightly warm"
        case .serious: "Hot: macOS is throttling"
        case .critical: "Critical heat"
        @unknown default: ""
        }
    }

    private var results: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ResultTile(module: .junk, value: Format.bytes(model.junk.selectedSize),
                           caption: model.junk.groups.isEmpty ? "No junk found" : "safe to clean, of \(Format.bytes(model.junk.totalSize)) found")
                ResultTile(module: .largeFiles, value: Format.bytes(model.largeFiles.totalSize),
                           caption: "\(model.largeFiles.files.count) files over \(Format.bytes(Preferences.largeFileThreshold))")
                ResultTile(module: .startup, value: "\(model.startup.items.count)",
                           caption: model.startup.brokenCount == 0 ? "background items, all healthy"
                               : "background items, \(model.startup.brokenCount) broken")
            }
            HStack(spacing: 12) {
                Button("Scan Again") { model.smartScan() }.buttonStyle(PillButtonStyle())
                Button("Review & Clean Junk") { model.selection = .junk }
                    .buttonStyle(PillButtonStyle(prominent: true, tint: Module.overview.accent))
                    .disabled(model.junk.groups.isEmpty)
            }
            .padding(.top, 8)
        }
    }
}

/// One reading, as a square glass module like the menu bar panel's processor square: white
/// badge and gauge ring on top, the number large, then what it is and a line of context.
private struct GaugeTile: View {
    let title: String
    let value: Double?
    let caption: String
    let symbol: String
    let colors: [Color]
    var centerText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                IconDisc(symbol: symbol, color: colors[1], size: 36)
                Spacer()
                if let value {
                    ZStack {
                        Circle().stroke(Color.track, lineWidth: 6)
                        Circle().trim(from: 0, to: max(0.002, min(1, value)))
                            // Linear, not angular: CoreGraphics shades conic gradients on the CPU
                            // with an atan2 per pixel, and this ring is redrawn on every sample.
                            .stroke(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 46, height: 46)
                }
            }
            Spacer(minLength: 10)
            Text(centerText ?? "\(Int(((value ?? 0) * 100).rounded()))%")
                .font(.system(size: centerText == nil ? 32 : 24, weight: .bold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .card(cornerRadius: 17)
    }
}

private struct ResultTile: View {
    @Environment(AppModel.self) private var model
    let module: Module
    let value: String
    let caption: String
    @State private var hovering = false

    var body: some View {
        Button { model.selection = module } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    IconDisc(symbol: module.symbol, color: module.colors[1], size: 32)
                    Text(module.title).font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(module.gradient)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .card(highlighted: hovering)
            .contentShape(Rectangle())
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.3), value: hovering)
    }
}
