import SwiftUI
import AppKit
import SweepwellKit

/// A tile of the menu bar panel, opened up into "which apps are using this".
enum PanelDetail: String, Identifiable {
    case processor, memory, storage, battery, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processor: "Processor"
        case .memory: "Memory"
        case .storage: "Disk Activity"
        case .battery: "Energy"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .processor: "cpu.fill"
        case .memory: "memorychip.fill"
        case .storage: "internaldrive.fill"
        case .battery: "bolt.fill"
        case .network: "network"
        }
    }

    var module: Module {
        switch self {
        case .processor: .startup
        case .memory: .largeFiles
        case .storage: .spaceLens
        case .battery: .maintenance
        case .network: .overview
        }
    }

    /// What is being ranked, and what the list cannot tell you.
    var footnote: String {
        switch self {
        case .processor:
            "100% is one full core; this Mac has \(ProcessInfo.processInfo.activeProcessorCount). Helpers are counted with their app."
        case .memory:
            "Real memory footprint, as in Activity Monitor. Helpers are counted with their app."
        case .storage:
            "Live reads and writes, not space taken. For what fills the disk, open Space Lens."
        case .battery:
            "Power drawn right now, from the system's energy accounting. System processes are not included."
        case .network:
            "Live traffic per app. Apps with no open connections are not listed."
        }
    }

    /// Where the matching full-size tool lives in the main window.
    var destination: (title: String, module: Module) {
        switch self {
        case .processor, .memory, .battery: ("Open Startup & Activity", .startup)
        case .storage: ("Open Space Lens", .spaceLens)
        case .network: ("Open Sweepwell", .overview)
        }
    }

    func value(of app: AppUsage) -> Double {
        switch self {
        case .processor: app.cpu
        case .memory: Double(app.memory)
        case .storage: app.diskRead + app.diskWrite
        case .battery: app.power
        case .network: app.networkIn + app.networkOut
        }
    }

    /// Below this an app is noise, not a consumer.
    var floor: Double {
        switch self {
        case .processor: 0.5
        case .memory: Double(30 << 20)
        case .storage: 4096
        case .battery: 0.02
        case .network: 512
        }
    }

    func describe(_ app: AppUsage) -> String {
        switch self {
        case .processor: "\(String(format: app.cpu < 10 ? "%.1f" : "%.0f", app.cpu))%"
        case .memory: Format.bytes(app.memory)
        case .storage: "R \(Self.rate(app.diskRead)) · W \(Self.rate(app.diskWrite))"
        case .battery: app.power < 1 ? "\(Int((app.power * 1000).rounded())) mW" : String(format: "%.1f W", app.power)
        case .network: "↓ \(Self.rate(app.networkIn)) · ↑ \(Self.rate(app.networkOut))"
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1024 ? "0 KB/s" : "\(Format.bytes(Int64(bytesPerSecond)))/s"
    }
}

struct PanelDetailView: View {
    @Environment(AppModel.self) private var app
    let detail: PanelDetail
    let openModule: (Module) -> Void
    @State private var hasRates = false

    private static let rowLimit = 8

    private var rows: [AppUsage] {
        app.appUsage.filter { detail.value(of: $0) >= detail.floor }
            .sorted { detail.value(of: $0) > detail.value(of: $1) }
            .prefix(Self.rowLimit).map { $0 }
    }

    var body: some View {
        let rows = rows
        let peak = rows.first.map(detail.value) ?? 1
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { app.panelDetail = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28).background(Color.quietButton, in: Circle())
                }
                .buttonStyle(.plain).focusable(false).help("Back to the overview")
                .keyboardShortcut(.cancelAction)

                Image(systemName: detail.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(detail.module.gradient)
                Text(detail.title).font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Text(summary).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text(hasRates ? "Nothing is using this right now." : "Measuring…")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(rows) { usage in
                        UsageRow(usage: usage, detail: detail, fraction: detail.value(of: usage) / max(peak, 0.0001))
                    }
                }
            }
            .padding(6)
            // Tall enough for a full list from the start, so the panel does not resize as the
            // first measurements arrive.
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.panelTile)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline)))

            Text(detail.footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(detail.destination.title) { openModule(detail.destination.module) }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Module.overview.accent).focusable(false)
            }
        }
        .task(id: detail) {
            // Rates are differences between two readings: take one, wait, and only then show
            // numbers. After that, refresh at the pace of the rest of the panel, and only
            // while the panel is really on screen and still showing this breakdown.
            hasRates = false
            await app.sampleAppUsage(includeNetwork: detail == .network)
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled, app.panelDetail == detail {
                if AppModel.isAnythingVisible {
                    await app.sampleAppUsage(includeNetwork: detail == .network)
                    hasRates = true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The machine-wide figure this list breaks down.
    private var summary: String {
        let s = app.snapshot
        switch detail {
        case .processor: return "\(Int((s.cpuUsage * 100).rounded()))% load"
        case .memory: return "\(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal))"
        case .storage: return "\(Format.bytes(s.diskAvailable)) free"
        case .battery: return s.batteryLevel.map { "\(Int(($0 * 100).rounded()))% charged" } ?? ""
        case .network: return "↓ \(PanelDetail.rate(s.networkIn))  ↑ \(PanelDetail.rate(s.networkOut))"
        }
    }
}

private struct UsageRow: View {
    @Environment(AppModel.self) private var app
    let usage: AppUsage
    let detail: PanelDetail
    let fraction: Double
    @State private var hovering = false

    /// Only regular apps get a Quit button: ending a daemon by hand is never the fix.
    private var quittable: NSRunningApplication? {
        guard hovering else { return nil }
        return usage.pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    var body: some View {
        HStack(spacing: 9) {
            if let bundle = usage.bundleURL { FileIcon(url: bundle, size: 24) } else {
                Image(systemName: "gearshape.2.fill").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(usage.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if usage.processCount > 1 {
                        Text("\(usage.processCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).background(Color.track, in: Capsule())
                            .help("\(usage.processCount) processes")
                    }
                    Spacer(minLength: 4)
                    if let running = quittable {
                        Button("Quit") { running.terminate() }.buttonStyle(.plain)
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.danger).focusable(false)
                    }
                    Text(detail.describe(usage)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    Capsule().fill(Color.track).overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: detail.module.colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(hovering ? Color.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}
