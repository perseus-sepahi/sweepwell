import SwiftUI
import AppKit
import SweepwellKit

/// Scans block on disk I/O, so they run off the main actor and hand back a finished value.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}

// MARK: - System Junk

@MainActor @Observable
final class JunkModel {
    let environment: ScanEnvironment
    var phase: Phase = .idle
    var groups: [JunkGroup] = []
    var selected: Set<String> = []
    var report: RemovalReport?
    var reportMode: RemovalMode = .trash
    var control = ScanControl()

    init(environment: ScanEnvironment) { self.environment = environment }

    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [JunkItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func scan() {
        guard phase != .scanning, phase != .working else { return }
        phase = .scanning
        report = nil
        let control = ScanControl()
        self.control = control
        let scanner = JunkScanner(environment: environment, runningBundleIDs: runningBundleIDs())
        Task {
            let found = await background { scanner.scan(control: control) }
            guard !control.isCancelled else { phase = .idle; return }
            groups = found
            selected = Set(found.flatMap(\.items).filter(\.selectedByDefault).map(\.id))
            phase = .results
        }
    }

    func selectionState(of group: JunkGroup) -> (selected: Int, total: Int) {
        (group.items.filter { selected.contains($0.id) }.count, group.items.count)
    }

    func setGroup(_ group: JunkGroup, selected isOn: Bool) {
        let ids = group.items.map(\.id)
        if isOn { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func clean() {
        let items = selectedItems
        guard !items.isEmpty, phase == .results else { return }
        phase = .working
        let mode = Preferences.removalMode
        let remover = Remover(environment: environment)
        let requests = items.map { RemovalRequest(url: $0.url, size: $0.size, purpose: $0.kind.removalPurpose) }
        Task {
            let result = await background { remover.remove(requests, mode: mode) }
            let gone = Set(result.removed.map(\.path))
            groups = groups.compactMap { group in
                var group = group
                group.items.removeAll { gone.contains($0.id) }
                return group.items.isEmpty ? nil : group
            }
            selected.subtract(gone)
            report = result
            reportMode = mode
            phase = .finished
        }
    }
}

// MARK: - Large & Old Files

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age", sixMonths = "Unopened 6+ months", year = "Unopened 1+ year"
    var id: String { rawValue }
    var cutoff: Date? {
        switch self {
        case .any: nil
        case .sixMonths: Calendar.current.date(byAdding: .month, value: -6, to: .now)
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: .now)
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case all = "All sizes", huge = "Over 1 GB", big = "250 MB – 1 GB", medium = "Under 250 MB"
    var id: String { rawValue }
    func matches(_ size: Int64) -> Bool {
        switch self {
        case .all: true
        case .huge: size >= 1 << 30
        case .big: size >= 250 << 20 && size < 1 << 30
        case .medium: size < 250 << 20
        }
    }
}

@MainActor @Observable
final class LargeFilesModel {
    let environment: ScanEnvironment
    var phase: Phase = .idle
    var files: [LargeFile] = []
    var selected: Set<String> = []
    var ageFilter: AgeFilter = .any
    var sizeFilter: SizeFilter = .all
    var report: RemovalReport?
    var reportMode: RemovalMode = .trash
    var control = ScanControl()

    init(environment: ScanEnvironment) { self.environment = environment }

    var visibleFiles: [LargeFile] {
        files.filter { file in
            sizeFilter.matches(file.size) && (ageFilter.cutoff.map { file.accessed < $0 } ?? true)
        }
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard phase != .scanning, phase != .working else { return }
        phase = .scanning
        report = nil
        let control = ScanControl()
        self.control = control
        let roots = environment.userFolders
        let threshold = Preferences.largeFileThreshold
        Task {
            let found = await background { DiskScanner.findLargeFiles(in: roots, minimumSize: threshold, control: control) }
            guard !control.isCancelled else { phase = .idle; return }
            files = found
            selected = []
            phase = .results
        }
    }

    func removeSelected() {
        let targets = files.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        phase = .working
        let mode = Preferences.removalMode
        let remover = Remover(environment: environment)
        let requests = targets.map { RemovalRequest(url: $0.url, size: $0.size, purpose: .userFile) }
        Task {
            let result = await background { remover.remove(requests, mode: mode) }
            let gone = Set(result.removed.map(\.path))
            files.removeAll { gone.contains($0.id) }
            selected.subtract(gone)
            report = result
            reportMode = mode
            phase = .results
        }
    }
}

// MARK: - Duplicates

@MainActor @Observable
final class DuplicatesModel {
    let environment: ScanEnvironment
    var phase: Phase = .idle
    var roots: [URL]
    var groups: [DuplicateGroup] = []
    var selected: Set<String> = []
    var report: RemovalReport?
    var reportMode: RemovalMode = .trash
    var control = ScanControl()

    init(environment: ScanEnvironment) {
        self.environment = environment
        roots = environment.userFolders
    }

    var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    var selectedSize: Int64 {
        groups.reduce(0) { total, group in
            total + group.size * Int64(group.files.filter { selected.contains($0.id) }.count)
        }
    }

    func scan() {
        guard phase != .scanning, phase != .working, !roots.isEmpty else { return }
        phase = .scanning
        report = nil
        let control = ScanControl()
        self.control = control
        let roots = roots
        Task {
            let found = await background { DuplicateFinder.find(in: roots, minimumSize: 1 << 20, control: control) }
            guard !control.isCancelled else { phase = .idle; return }
            groups = found
            selectAllButOriginals()
            phase = .results
        }
    }

    /// Keeps the oldest copy of every group, which is nearly always the original.
    func selectAllButOriginals() {
        selected = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selected.contains(file.id) {
            selected.remove(file.id)
        } else {
            // Never let a whole group be ticked: one copy always survives.
            let others = group.files.filter { $0.id != file.id }
            guard !others.allSatisfy({ selected.contains($0.id) }) else { return }
            selected.insert(file.id)
        }
    }

    func removeSelected() {
        var requests: [RemovalRequest] = []
        for group in groups {
            for file in group.files where selected.contains(file.id) {
                requests.append(RemovalRequest(url: file.url, size: group.size, purpose: .userFile))
            }
        }
        guard !requests.isEmpty else { return }
        phase = .working
        let mode = Preferences.removalMode
        let remover = Remover(environment: environment)
        let batch = requests
        Task {
            let result = await background { remover.remove(batch, mode: mode) }
            let gone = Set(result.removed.map(\.path))
            groups = groups.compactMap { group in
                let remaining = group.files.filter { !gone.contains($0.id) }
                return remaining.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: remaining) : nil
            }
            selected.subtract(gone)
            report = result
            reportMode = mode
            phase = .results
        }
    }
}

// MARK: - Space Lens

@MainActor @Observable
final class SpaceLensModel {
    let environment: ScanEnvironment
    var phase: Phase = .idle
    var root: URL
    var tree: DiskNode?
    var current: DiskNode?
    var highlighted: DiskNode?
    var message: String?
    var inaccessible = 0
    var control = ScanControl()
    /// Bumped after a deletion, because the tree is a reference type SwiftUI cannot observe.
    var revision = 0

    init(environment: ScanEnvironment) {
        self.environment = environment
        root = environment.home
    }

    func scan(_ url: URL) {
        guard phase != .scanning else { return }
        root = url
        phase = .scanning
        message = nil
        let control = ScanControl()
        self.control = control
        Task {
            let result = await background { DiskScanner.scanTree(root: url, control: control) }
            guard !control.isCancelled else { phase = tree == nil ? .idle : .results; return }
            tree = result
            current = result
            highlighted = nil
            inaccessible = control.inaccessibleDirectories
            phase = .results
        }
    }

    var breadcrumbs: [DiskNode] {
        var chain: [DiskNode] = []
        var node = current
        while let n = node { chain.insert(n, at: 0); node = n.parent }
        return chain
    }

    func open(_ node: DiskNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        current = node
        highlighted = nil
    }

    func remove(_ node: DiskNode) {
        guard !node.isAggregate, let parent = node.parent else { return }
        let mode = Preferences.removalMode
        let remover = Remover(environment: environment)
        let request = RemovalRequest(url: node.url, size: node.size, purpose: .userFile)
        Task {
            let result = await background { remover.remove([request], mode: mode) }
            if let failure = result.failures.first {
                message = "Could not remove “\(node.name)”: \(failure.message)"
            } else {
                parent.removeChild(node)
                highlighted = nil
                revision += 1
                message = "\(mode == .trash ? "Moved to Trash" : "Deleted"): \(node.name) (\(Format.bytes(node.size)))"
            }
        }
    }
}

// MARK: - Uninstaller

enum AppSort: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", lastUsed = "Last used"
    var id: String { rawValue }
}

@MainActor @Observable
final class UninstallerModel {
    let environment: ScanEnvironment
    var phase: Phase = .idle
    var apps: [InstalledApp] = []
    var selectedAppID: String?
    var keptLeftovers: Set<String> = []
    var search = ""
    var sort: AppSort = .size
    var report: RemovalReport?
    var reportTitle = ""
    var control = ScanControl()

    init(environment: ScanEnvironment) { self.environment = environment }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    var visibleApps: [InstalledApp] {
        let filtered = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .size: return filtered.sorted { $0.totalSize > $1.totalSize }
        case .name: return filtered
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    func scan() {
        guard phase != .scanning, phase != .working else { return }
        phase = .scanning
        report = nil
        let control = ScanControl()
        self.control = control
        let inventory = AppInventory(environment: environment)
        Task {
            let found = await background { inventory.scan(control: control) }
            guard !control.isCancelled else { phase = .idle; return }
            apps = found
            if selectedApp == nil { selectedAppID = visibleApps.first?.id }
            phase = .results
        }
    }

    func runningInstance(of app: InstalledApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == app.bundleID }
    }

    func uninstall(_ app: InstalledApp) {
        phase = .working
        let mode = Preferences.removalMode
        let inventory = AppInventory(environment: environment)
        let leftovers = app.leftovers.filter { !keptLeftovers.contains($0.id) }
        Task {
            let result = await background { inventory.uninstall(app, leftovers: leftovers, mode: mode) }
            if result.removed.contains(app.url) {
                apps.removeAll { $0.id == app.id }
                selectedAppID = visibleApps.first?.id
            }
            keptLeftovers = []
            report = result
            reportTitle = app.name
            phase = .results
        }
    }
}

// MARK: - Startup & Activity

@MainActor @Observable
final class StartupModel {
    let environment: ScanEnvironment
    var items: [LaunchItem] = []
    var processes: [ProcessSample] = []
    var isLoading = false
    var hasLoaded = false
    var message: String?

    init(environment: ScanEnvironment) { self.environment = environment }

    var brokenCount: Int { items.filter(\.isBroken).count }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let scanner = LaunchItemScanner(environment: environment)
        Task {
            items = await background { scanner.scan() }
            await refreshProcesses()
            isLoading = false
            hasLoaded = true
        }
    }

    func refreshProcesses() async {
        let all = await background { ProcessList.sample() }
        processes = Array(all.sorted { $0.memory > $1.memory }.prefix(12))
    }

    func remove(_ item: LaunchItem) {
        let scanner = LaunchItemScanner(environment: environment)
        let mode = Preferences.removalMode
        Task {
            let result = await background { scanner.remove(item, mode: mode) }
            if let failure = result.failures.first {
                message = "Could not remove \(item.label): \(failure.message)"
            } else {
                items.removeAll { $0.id == item.id }
                message = "Removed \(item.label)"
            }
        }
    }

    func quit(_ process: ProcessSample) {
        NSRunningApplication(processIdentifier: process.pid)?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshProcesses()
        }
    }
}

// MARK: - Maintenance

@MainActor @Observable
final class MaintenanceModel {
    enum Status: Equatable {
        case running
        case finished(succeeded: Bool, message: String)
    }

    var status: [MaintenanceTask: Status] = [:]

    func run(_ task: MaintenanceTask) {
        guard status[task] != .running else { return }
        status[task] = .running
        Task {
            let outcome = await background { MaintenanceRunner.run(task) }
            status[task] = .finished(succeeded: outcome.succeeded, message: outcome.message)
        }
    }
}
