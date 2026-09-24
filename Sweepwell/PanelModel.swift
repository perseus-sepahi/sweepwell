import SwiftUI
import AppKit
import SweepwellKit

// MARK: - Vitals

/// One row of the menu bar panel. Each can open up into the apps behind its number.
enum Vital: String, CaseIterable, Identifiable {
    case processor, memory, disk, battery, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processor: "Processor"
        case .memory: "Memory"
        case .disk: "Disk"
        case .battery: "Power"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .processor: "cpu.fill"
        case .memory: "memorychip.fill"
        case .disk: "internaldrive.fill"
        case .battery: "bolt.fill"
        case .network: "wifi"
        }
    }

    var module: Module {
        switch self {
        case .processor: .startup
        case .memory: .largeFiles
        case .disk: .spaceLens
        case .battery: .maintenance
        case .network: .overview
        }
    }

    /// What the per-app list ranks, in words.
    var rankingLabel: String {
        switch self {
        case .processor: "Busiest apps"
        case .memory: "Largest memory footprint"
        case .disk: "Reading and writing now"
        case .battery: "Drawing the most power"
        case .network: "Using the network"
        }
    }

    func value(of app: AppUsage) -> Double {
        switch self {
        case .processor: app.cpu
        case .memory: Double(app.memory)
        case .disk: app.diskRead + app.diskWrite
        case .battery: app.power
        case .network: app.networkIn + app.networkOut
        }
    }

    /// Below this an app is noise, not a consumer.
    var floor: Double {
        switch self {
        case .processor: 0.5
        case .memory: Double(30 << 20)
        case .disk: 4096
        case .battery: 0.02
        case .network: 512
        }
    }

    func describe(_ app: AppUsage) -> String {
        switch self {
        case .processor: "\(String(format: app.cpu < 10 ? "%.1f" : "%.0f", app.cpu))%"
        case .memory: Format.bytes(app.memory)
        case .disk: "R \(Self.rate(app.diskRead)) · W \(Self.rate(app.diskWrite))"
        case .battery: app.power < 1 ? "\(Int((app.power * 1000).rounded())) mW" : String(format: "%.1f W", app.power)
        case .network: "↓ \(Self.rate(app.networkIn)) · ↑ \(Self.rate(app.networkOut))"
        }
    }

    func top(_ apps: [AppUsage], limit: Int) -> [AppUsage] {
        Array(apps.filter { value(of: $0) >= floor }.sorted { value(of: $0) > value(of: $1) }.prefix(limit))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1024 ? "0 KB/s" : "\(Format.bytes(Int64(bytesPerSecond)))/s"
    }
}

// MARK: - Heads-up

/// Something worth a glance, phrased as what is going on rather than as a score.
struct PanelAlert: Identifiable {
    enum Severity: Int, Comparable {
        case note, warning, urgent
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var color: Color {
            switch self {
            case .note: Module.spaceLens.accent
            case .warning: .warning
            case .urgent: .danger
            }
        }
    }

    enum Action {
        case quit(NSRunningApplication)
        case expand(Vital)
        case open(Module, scan: Bool)

        var title: String {
            switch self {
            case .quit: "Quit"
            case .expand: "Details"
            case .open(let module, let scan): scan ? "Scan" : "Open \(module.title)"
            }
        }
    }

    let id: String
    let severity: Severity
    let symbol: String
    let title: String
    let detail: String
    let action: Action?
}

extension AppModel {
    var alerts: [PanelAlert] {
        let s = snapshot
        var found: [PanelAlert] = []

        if let temperature = s.cpuTemperature, temperature >= 90 {
            found.append(PanelAlert(id: "hot", severity: .urgent, symbol: "thermometer.high",
                                    title: "Running hot at \(Int(temperature)) °C",
                                    detail: "macOS slows the chip down to cool it.", action: .expand(.processor)))
        }
        if s.memoryPressure > 0.8 {
            found.append(PanelAlert(id: "pressure", severity: .urgent, symbol: "memorychip.fill",
                                    title: "Memory is under pressure",
                                    detail: "Apps are being compressed and paged out right now.", action: .expand(.memory)))
        } else if let swap = s.swap, swap.used >= 2 << 30 {
            found.append(PanelAlert(id: "swap", severity: .warning, symbol: "arrow.left.arrow.right",
                                    title: "\(Format.bytes(swap.used)) swapped to disk",
                                    detail: "RAM ran short. Quit heavy apps, or restart to clear it.",
                                    action: .expand(.memory)))
        }
        if s.diskTotal > 0, Double(s.diskAvailable) / Double(s.diskTotal) < 0.10 {
            let purgeable = s.diskPurgeable > 1 << 30 ? " \(Format.bytes(s.diskPurgeable)) of it is purgeable, which macOS frees as needed." : ""
            found.append(PanelAlert(id: "disk", severity: s.diskAvailable < 10 << 30 ? .urgent : .warning,
                                    symbol: "internaldrive.fill",
                                    title: "Only \(Format.bytes(s.diskAvailable)) free on the startup disk",
                                    detail: purgeable.isEmpty ? "macOS needs room to update and swap." : purgeable.trimmingCharacters(in: .whitespaces),
                                    action: .open(.junk, scan: true)))
        }
        if startup.brokenCount > 0 {
            found.append(PanelAlert(id: "broken", severity: .note, symbol: "bolt.slash.fill",
                                    title: "\(startup.brokenCount) broken startup item\(startup.brokenCount == 1 ? "" : "s")",
                                    detail: "Left behind by apps that are gone.", action: .open(.startup, scan: false)))
        }
        if let health = s.batteryHealth, health < 0.8 {
            found.append(PanelAlert(id: "battery", severity: .note, symbol: "battery.25percent",
                                    title: "Battery holds \(Int(health * 100))% of its original charge",
                                    detail: "Apple considers service below 80%.", action: nil))
        }
        return found.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Sweep ledger

/// What Sweepwell has cleared over time. Kept in UserDefaults; tiny and private to this Mac.
struct SweepLedger: Codable {
    var bytes: Int64 = 0
    var sweeps = 0
    var since: Date?
    var last: Date?

    private static let key = "sweepLedger"

    static func load() -> SweepLedger {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ledger = try? JSONDecoder().decode(SweepLedger.self, from: data) else { return SweepLedger() }
        return ledger
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AppModel {
    /// Called after every removal, from any module. Demo folders are never counted.
    func recordSweep(_ report: RemovalReport) {
        guard !environment.isFixture, !report.removed.isEmpty else { return }
        ledger.bytes += report.bytesFreed
        ledger.sweeps += 1
        ledger.since = ledger.since ?? Date()
        ledger.last = Date()
        ledger.save()
    }
}

// MARK: - Trash

struct TrashStatus {
    enum Phase: Equatable { case idle, confirming, emptying }
    var phase: Phase = .idle
    /// Known only with Full Disk Access (or in a demo folder); macOS hides the Trash otherwise.
    var size: Int64?
    var items: Int?
}

extension AppModel {
    /// Sweepwell can read the Trash itself only with Full Disk Access; otherwise Finder does
    /// the emptying and the size stays unknown.
    private var canReadTrash: Bool { environment.isFixture || hasFullDiskAccess }

    func refreshTrash() {
        guard canReadTrash else { trash.size = nil; trash.items = nil; return }
        let folder = environment.trash
        Task {
            let (items, size) = await background { () -> (Int, Int64) in
                let entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }
                return (entries.count, DiskScanner.measure(folder).bytes)
            }
            trash.items = items
            trash.size = items == 0 ? 0 : size
        }
    }

    func emptyTrash() {
        trash.phase = .emptying
        let environment = environment
        let readable = canReadTrash
        let knownSize = trash.size
        Task {
            let (report, message) = await background { () -> (RemovalReport, String) in
                if readable {
                    // In-process, through the same safety guard as every other removal.
                    let entries = ((try? FileManager.default.contentsOfDirectory(at: environment.trash, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.lastPathComponent != ".DS_Store" }
                    let requests = entries.map { RemovalRequest(url: $0, size: DiskScanner.measure($0).bytes, purpose: .trashContents) }
                    let report = Remover(environment: environment).remove(requests, mode: .permanent)
                    let text = report.failures.isEmpty
                        ? "Emptied the Trash: \(Format.bytes(report.bytesFreed)) freed."
                        : "Emptied most of the Trash; \(report.failures.count) item(s) are in use."
                    return (report, text)
                }
                // Without Full Disk Access only Finder can reach the Trash. macOS asks once for
                // permission to control Finder.
                let result = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
                var report = RemovalReport()
                if result.succeeded { report.removed = [environment.trash]; report.bytesFreed = knownSize ?? 0 }
                return (report, result.succeeded ? "Emptied the Trash." : "Finder could not empty the Trash. Allow Sweepwell to control Finder in System Settings → Privacy & Security → Automation.")
            }
            recordSweep(report)
            panelMessage = message
            trash = TrashStatus()
            refreshTrash()
        }
    }
}
