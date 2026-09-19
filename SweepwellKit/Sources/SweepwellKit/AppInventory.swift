import Foundation
import CoreServices

public struct AppLeftover: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// The `~/Library` area it was found in, e.g. "Caches".
    public let location: String
    public let size: Int64
}

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let bundleSize: Int64
    public let lastUsed: Date?
    public let leftovers: [AppLeftover]

    public var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    public var totalSize: Int64 { bundleSize + leftoverSize }
}

public struct AppInventory: Sendable {
    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment) { self.environment = environment }

    /// Areas of `~/Library` searched for an app's support files, and whether an entry named
    /// after the app (not just its bundle identifier) counts as a match there.
    private static let locations: [(folder: String, matchesAppName: Bool)] = [
        ("Application Support", true), ("Caches", true), ("Logs", true),
        ("Preferences", false), ("Containers", false), ("Group Containers", false),
        ("Saved Application State", false), ("HTTPStorages", false), ("WebKit", false),
        ("Cookies", false), ("Application Scripts", false)
    ]

    private struct Bundle {
        let url: URL
        let name: String
        let bundleID: String
        let version: String
    }

    public func scan(control: ScanControl = ScanControl()) -> [InstalledApp] {
        let bundles = findBundles()
        let allIDs = bundles.map { $0.bundleID.lowercased() }

        // One listing per Library area, shared by every app.
        let listings: [(folder: String, matchesAppName: Bool, entries: [String])] = Self.locations.map { location in
            let directory = environment.library.appendingPathComponent(location.folder)
            let names = (try? FastDirectoryReader.read(directory.path))?.map(\.name) ?? []
            return (location.folder, location.matchesAppName, names)
        }

        var apps = [InstalledApp?](repeating: nil, count: bundles.count)
        apps.withUnsafeMutableBufferPointer { buffer in
            let slots = UnsafeSendableBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
                if control.isCancelled { return }
                let bundle = bundles[i]
                let leftovers = findLeftovers(for: bundle, listings: listings, allBundleIDs: allIDs, control: control)
                slots.base[i] = InstalledApp(url: bundle.url, name: bundle.name, bundleID: bundle.bundleID,
                                             version: bundle.version,
                                             bundleSize: DiskScanner.measure(bundle.url, control: control).bytes,
                                             lastUsed: Self.lastUsedDate(bundle.url), leftovers: leftovers)
            }
        }
        return apps.compactMap { $0 }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Bundles

    private func findBundles() -> [Bundle] {
        var result: [Bundle] = []
        var seen = Set<String>()
        for directory in environment.applicationDirectories {
            collect(in: directory, depth: 0, into: &result, seen: &seen)
        }
        return result
    }

    /// Vendors nest apps one or two folders deep ("/Applications/Utilities", suites).
    private func collect(in directory: URL, depth: Int, into result: inout [Bundle], seen: inout Set<String>) {
        guard depth <= 2, let entries = try? FastDirectoryReader.read(directory.path) else { return }
        for entry in entries where entry.kind == .directory && !entry.name.hasPrefix(".") {
            let url = directory.appendingPathComponent(entry.name, isDirectory: true)
            if url.pathExtension == "app" {
                if let bundle = readBundle(url), seen.insert(url.path).inserted { result.append(bundle) }
            } else {
                collect(in: url, depth: depth + 1, into: &result, seen: &seen)
            }
        }
    }

    private func readBundle(_ url: URL) -> Bundle? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        // Apple's own apps are part of the system install even when they sit in /Applications.
        if bundleID.hasPrefix("com.apple.") { return nil }
        if url.resolvingSymlinksInPath().path == Foundation.Bundle.main.bundleURL.resolvingSymlinksInPath().path { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? ""
        return Bundle(url: url, name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                      bundleID: bundleID, version: version)
    }

    // MARK: Leftovers

    private func findLeftovers(for bundle: Bundle,
                               listings: [(folder: String, matchesAppName: Bool, entries: [String])],
                               allBundleIDs: [String], control: ScanControl) -> [AppLeftover] {
        let id = bundle.bundleID.lowercased()
        // "com.vendor" style identifiers are too broad to match on safely.
        guard id.split(separator: ".").count >= 3 else { return [] }

        // Identifiers of *other* installed apps that extend ours ("…Chrome" vs "…Chrome.canary"):
        // anything matching those belongs to them.
        let siblings = allBundleIDs.filter { $0 != id && $0.hasPrefix(id + ".") }
        let appName = bundle.name.lowercased()
        let fileName = bundle.url.deletingPathExtension().lastPathComponent.lowercased()

        var result: [AppLeftover] = []
        for listing in listings {
            for entry in listing.entries {
                let lower = entry.lowercased()
                if siblings.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { continue }

                var matches = lower == id || lower.hasPrefix(id + ".")
                if !matches, listing.folder == "Group Containers" {
                    matches = lower.hasSuffix("." + id)
                }
                if !matches, listing.matchesAppName {
                    // Short names ("Go", "Notes") collide with unrelated folders.
                    matches = (appName.count >= 4 && lower == appName) || (fileName.count >= 4 && lower == fileName)
                }
                guard matches else { continue }

                let url = environment.library.appendingPathComponent(listing.folder).appendingPathComponent(entry)
                let size = DiskScanner.measure(url, control: control).bytes
                result.append(AppLeftover(url: url, location: listing.folder, size: size))
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    private static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Uninstall

    /// Removes the bundle first: if that fails nothing else is touched, so the app never ends
    /// up half-uninstalled with its settings gone.
    public func uninstall(_ app: InstalledApp, leftovers: [AppLeftover], mode: RemovalMode) -> RemovalReport {
        let remover = Remover(environment: environment)
        var report = remover.remove([RemovalRequest(url: app.url, size: app.bundleSize, purpose: .application)], mode: mode)
        if let failure = report.failures.first, mode == .trash, !environment.isFixture,
           (try? SafetyGuard(environment: environment).validate(app.url, purpose: .application)) != nil {
            // App Store and installer-placed apps are owned by root. Finder can still trash
            // them after asking the user for an administrator password.
            if FinderTrash.moveToTrash(app.url) {
                report = RemovalReport()
                report.removed = [app.url]
                report.bytesFreed = app.bundleSize
            } else {
                report.failures = [.init(url: failure.url, message: failure.message)]
            }
        }
        guard report.failures.isEmpty else { return report }
        report.merge(remover.remove(leftovers.map { RemovalRequest(url: $0.url, size: $0.size, purpose: .appLeftover) }, mode: mode))
        return report
    }
}

enum FinderTrash {
    /// Asks Finder to trash an item, which brings up the system authentication dialog when
    /// the item needs administrator rights. The path travels as an argument, never as script text.
    static func moveToTrash(_ url: URL) -> Bool {
        let result = Shell.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
            "-e", "end run",
            url.path
        ])
        return result.succeeded && !FileManager.default.fileExists(atPath: url.path)
    }
}
