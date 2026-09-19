import SwiftUI
import AppKit
import SweepwellKit

enum Preferences {
    static let removalModeKey = "removalMode"
    static let largeFileThresholdKey = "largeFileThresholdMB"
    static let appearanceKey = "appearance"
    static let glassKey = "glassiness"

    static var removalMode: RemovalMode {
        RemovalMode(rawValue: UserDefaults.standard.string(forKey: removalModeKey) ?? "") ?? .trash
    }

    static var largeFileThreshold: Int64 {
        let megabytes = UserDefaults.standard.integer(forKey: largeFileThresholdKey)
        return Int64(megabytes > 0 ? megabytes : 100) << 20
    }
}

/// What a module is doing right now. Every scanning module moves through the same phases.
enum Phase: Equatable {
    case idle, scanning, results, working, finished
}

@MainActor @Observable
final class AppModel {
    /// One model for the window and the menu bar panel, which lives outside SwiftUI's scenes.
    static let shared = AppModel()

    let environment = ScanEnvironment.live
    var selection: Module = .overview
    var hasFullDiskAccess = true
    var snapshot = SystemSnapshot()
    var volumes: [ExternalVolume] = []
    /// Recent network samples (bytes/s), oldest first, for the menu bar panel's sparkline.
    var networkHistory: [(down: Double, up: Double)] = []
    var panelMessage: String?

    let junk: JunkModel
    let largeFiles: LargeFilesModel
    let duplicates: DuplicatesModel
    let spaceLens: SpaceLensModel
    let uninstaller: UninstallerModel
    let startup: StartupModel
    let maintenance = MaintenanceModel()

    private let sampler = SystemSampler()
    private var monitor: Task<Void, Never>?

    init() {
        junk = JunkModel(environment: environment)
        largeFiles = LargeFilesModel(environment: environment)
        duplicates = DuplicatesModel(environment: environment)
        spaceLens = SpaceLensModel(environment: environment)
        uninstaller = UninstallerModel(environment: environment)
        startup = StartupModel(environment: environment)

        // Launch hooks used for UI checks: open a module and optionally start its scan.
        let arguments = ProcessInfo.processInfo.environment
        if let module = arguments["SWEEPWELL_MODULE"].flatMap(Module.init(rawValue:)) { selection = module }
        if arguments["SWEEPWELL_AUTOSCAN"] == "1" { startScan(for: selection) }
        // End-to-end check of the destructive path. Only ever honoured inside a fixture home.
        if arguments["SWEEPWELL_AUTOCLEAN"] == "1", environment.isFixture { autoCleanWhenReady() }

        refreshAccess()
        startup.refresh()   // cheap, and the health score wants to know about broken items
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sampler = self.sampler
                let (snapshot, volumes) = await Task.detached { (sampler.sample(), ExternalVolume.mounted()) }.value
                self.snapshot = snapshot
                self.volumes = volumes
                self.networkHistory = Array((self.networkHistory + [(snapshot.networkIn, snapshot.networkOut)]).suffix(40))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func autoCleanWhenReady() {
        Task {
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(200))
                switch selection {
                case .junk where junk.phase == .results:
                    junk.clean()
                    return
                case .uninstaller where uninstaller.phase == .results:
                    if let first = uninstaller.selectedApp { uninstaller.uninstall(first) }
                    return
                case .duplicates where duplicates.phase == .results:
                    duplicates.removeSelected()
                    return
                default:
                    continue
                }
            }
        }
    }

    func refreshAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted(environment)
    }

    func startScan(for module: Module) {
        switch module {
        case .overview: smartScan()
        case .junk: junk.scan()
        case .largeFiles: largeFiles.scan()
        case .duplicates: duplicates.scan()
        case .spaceLens: spaceLens.scan(spaceLens.root)
        case .uninstaller: uninstaller.scan()
        case .startup: startup.refresh()
        case .maintenance: break
        }
    }

    // MARK: Menu bar panel

    var health: HealthAssessment { .assess(snapshot, brokenLaunchItems: startup.brokenCount) }

    struct Recommendation {
        let symbol: String
        let title: String
        let detail: String
        let actionTitle: String?
        let module: Module
        var startsScan = false
    }

    /// One suggestion, from what Sweepwell can see locally. Most urgent rule wins.
    var recommendation: Recommendation {
        let s = snapshot
        if s.diskTotal > 0, s.diskFraction > 0.85 {
            return .init(symbol: "internaldrive.fill", title: "Make room on your disk",
                         detail: "Only \(Format.bytes(s.diskAvailable)) is left. A junk scan usually finds the quickest savings.",
                         actionTitle: "Find Junk", module: .junk, startsScan: true)
        }
        if junk.phase == .results, junk.selectedSize > 500 << 20 {
            return .init(symbol: "bubbles.and.sparkles", title: "Clean \(Format.bytes(junk.selectedSize)) of junk",
                         detail: "Your last scan found caches and leftovers that are safe to remove.",
                         actionTitle: "Review & Clean", module: .junk)
        }
        if startup.brokenCount > 0 {
            return .init(symbol: "bolt.slash.fill", title: "Remove \(startup.brokenCount) broken startup item\(startup.brokenCount == 1 ? "" : "s")",
                         detail: "They belong to apps that are gone, and macOS still tries to launch them.",
                         actionTitle: "Show Them", module: .startup)
        }
        if s.memoryPressure > 0.75 {
            return .init(symbol: "memorychip.fill", title: "Memory is under pressure",
                         detail: "See which apps are using the most and quit the ones you do not need.",
                         actionTitle: "Show Apps", module: .startup)
        }
        if s.uptime > 10 * 86_400 {
            return .init(symbol: "arrow.clockwise.circle.fill", title: "Restart your Mac",
                         detail: "It has been up for \(Format.uptime(s.uptime)). A restart clears swap and stuck background processes.",
                         actionTitle: nil, module: .overview)
        }
        if junk.phase == .idle {
            return .init(symbol: "sparkles", title: "Run a Smart Scan",
                         detail: "Nothing has been checked this session. It takes a moment and removes nothing on its own.",
                         actionTitle: "Smart Scan", module: .overview, startsScan: true)
        }
        return .init(symbol: "checkmark.seal.fill", title: "Everything looks tidy",
                     detail: "No junk worth cleaning, no broken startup items, and plenty of room.",
                     actionTitle: nil, module: .overview)
    }

    func eject(_ volume: ExternalVolume) {
        Task {
            let error = await background { () -> String? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url); return nil }
                catch { return error.localizedDescription }
            }
            panelMessage = error.map { "Could not eject \(volume.name): \($0)" }
            if error == nil { volumes.removeAll { $0.id == volume.id } }
        }
    }

    // MARK: Smart Scan

    var smartScanRunning: Bool {
        junk.phase == .scanning || largeFiles.phase == .scanning || startup.isLoading
    }

    var smartScanDone: Bool {
        !smartScanRunning && junk.phase != .idle && largeFiles.phase != .idle
    }

    func smartScan() {
        junk.scan()
        largeFiles.scan()
        startup.refresh()
    }
}

/// App icons and file icons come from Launch Services; caching keeps list scrolling smooth.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let hit = cache[url.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}

extension NSWorkspace {
    func reveal(_ url: URL) { activateFileViewerSelecting([url]) }
}

func runningBundleIDs() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
}
