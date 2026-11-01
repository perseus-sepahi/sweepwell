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
    /// Recent samples, oldest first, for the menu bar panel's graphs. Cleared after a gap so a
    /// graph never draws a line straight across the minutes the panel was closed.
    var networkHistory: [(down: Double, up: Double)] = []
    var cpuHistory: [Double] = []
    var pressureHistory: [Double] = []
    private var lastSample: Date?
    var panelMessage: String?

    // Menu bar panel
    /// Set by the status item while its panel is on screen; per-app figures are only
    /// gathered then.
    var panelVisible = false
    /// The vital whose row is opened up into its per-app breakdown, if any.
    var expandedVital: Vital?
    var appUsage: [AppUsage] = []
    private let usageSampler = AppUsageSampler()
    let keepAwake = KeepAwake()
    /// Bumped when Keep Awake starts or stops, since KeepAwake itself is not observable.
    var keepAwakeRevision = 0
    var trash = TrashStatus()
    /// The Memory module's two actions: freeing RAM and clearing app caches.
    var memoryTask = MemoryTask()
    /// True while something the panel started needs it to stay open, such as the password
    /// prompt macOS shows for freeing RAM.
    var panelBusy = false
    var ledger = SweepLedger.load()

    let junk: JunkModel
    let largeFiles: LargeFilesModel
    let duplicates: DuplicatesModel
    let spaceLens: SpaceLensModel
    let uninstaller: UninstallerModel
    let startup: StartupModel
    let maintenance = MaintenanceModel()
    let audit = StorageAuditModel()
    let shredder = ShredderModel()

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
        // UI check: preload the shredder (colon-separated paths). Only inside a fixture home.
        if environment.isFixture, let paths = arguments["SWEEPWELL_SHRED_PATHS"] {
            shredder.add(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        // End-to-end check of the destructive path. Only ever honoured inside a fixture home.
        if arguments["SWEEPWELL_AUTOCLEAN"] == "1", environment.isFixture { autoCleanWhenReady() }

        refreshAccess()
        startup.refresh()   // cheap, and the health score wants to know about broken items
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A resident app with nothing on screen has nobody to sample for. Every sample
                // also invalidates views, so idling here is what keeps background CPU at zero.
                if Self.isAnythingVisible { await self.sampleNow() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// True while the main window, Settings or the menu bar panel is actually showing.
    static var isAnythingVisible: Bool {
        #if DEBUG
        // Screenshots for the website: keep the readings live while the window is covered.
        if ProcessInfo.processInfo.environment["SWEEPWELL_SCREENSHOT"] == "1" { return true }
        #endif
        return NSApp?.windows.contains { window in
            window.isVisible && window.occlusionState.contains(.visible)
                && (window.canBecomeMain || window is NSPanel) && window.frame.height > 100
        } ?? false
    }

    /// One sample, off the main thread. Also called when the panel opens, so it never shows
    /// numbers from before the app went quiet.
    func sampleNow() async {
        let sampler = sampler
        let (snapshot, volumes) = await Task.detached { (sampler.sample(), ExternalVolume.mounted()) }.value
        if let lastSample, Date().timeIntervalSince(lastSample) > 10 {
            networkHistory = []
            cpuHistory = []
            pressureHistory = []
        }
        lastSample = Date()
        self.snapshot = snapshot
        self.volumes = volumes
        networkHistory = Array((networkHistory + [(snapshot.networkIn, snapshot.networkOut)]).suffix(45))
        cpuHistory = Array((cpuHistory + [snapshot.cpuUsage]).suffix(45))
        pressureHistory = Array((pressureHistory + [snapshot.memoryPressure]).suffix(45))
        if panelVisible { await sampleAppUsage(includeNetwork: expandedVital == .network) }
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
                case .shredder where !shredder.items.isEmpty && shredder.sizes.count == shredder.items.count:
                    shredder.shred()
                    return
                case .storageAudit where audit.phase == .results:
                    audit.pickLowRegret()
                    audit.remove()
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
        case .storageAudit: audit.scan()
        case .shredder: break
        }
    }

    // MARK: Menu bar panel

    func sampleAppUsage(includeNetwork: Bool) async {
        let sampler = usageSampler
        appUsage = await Task.detached { sampler.sample(includeNetwork: includeNetwork) }.value
    }

    func eject(_ volume: ExternalVolume) {
        Task {
            let error = await background { () -> String? in
                do { try volume.eject(); return nil } catch { return error.localizedDescription }
            }
            panelMessage = error.map { "Could not eject \(volume.name): \($0)" }
            if error == nil { volumes.removeAll { $0.id == volume.id } }
        }
    }

    func ejectAll() {
        let targets = volumes
        guard !targets.isEmpty else { return }
        Task {
            let failures = await background { targets.compactMap { volume -> String? in
                do { try volume.eject(); return nil } catch { return volume.name }
            } }
            volumes.removeAll { volume in !failures.contains(volume.name) }
            panelMessage = failures.isEmpty
                ? "Ejected \(targets.count) volume\(targets.count == 1 ? "" : "s"). Safe to unplug."
                : "Still in use, not ejected: \(failures.joined(separator: ", "))"
        }
    }

    func toggleKeepAwake(for duration: TimeInterval?) {
        if keepAwake.isActive, duration == nil || keepAwake.endsAt == nil {
            keepAwake.stop()
        } else {
            keepAwake.start(for: duration)
        }
        keepAwakeRevision += 1
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
