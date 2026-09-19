import SwiftUI
import AppKit
import SweepwellKit

enum Preferences {
    static let removalModeKey = "removalMode"
    static let largeFileThresholdKey = "largeFileThresholdMB"
    static let showMenuBarKey = "showMenuBarMonitor"

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
    let environment = ScanEnvironment.live
    var selection: Module = .overview
    var hasFullDiskAccess = true
    var snapshot = SystemSnapshot()

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
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sampler = self.sampler
                self.snapshot = await Task.detached { sampler.sample() }.value
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
