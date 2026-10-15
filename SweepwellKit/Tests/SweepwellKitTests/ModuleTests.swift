import XCTest
@testable import SweepwellKit

final class ModuleTests: XCTestCase {
    func testJunkScanSortsFindingsIntoGroups() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.vendor.editor/data", bytes: 50_000)
        try fixture.file("Library/Caches/com.vendor.running/data", bytes: 20_000)
        try fixture.file("Library/Caches/Homebrew/downloads/pkg.tar", bytes: 70_000)
        try fixture.file("Library/Caches/CloudKit/state.db", bytes: 10_000)
        try fixture.directory("Library/Caches/empty-cache")
        try fixture.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 8_000)
        try fixture.file("Library/Developer/Xcode/DerivedData/MyApp-abcdefgh/Build/out.o", bytes: 90_000)
        try fixture.file("Library/Developer/Xcode/Archives/2026-01-01/MyApp.xcarchive/Info.plist", bytes: 9_000)
        try fixture.file(".npm/_cacache/content/blob", bytes: 30_000)
        try fixture.file("Downloads/film.mkv.crdownload", bytes: 40_000)
        try fixture.file("Downloads/keep-me.pdf", bytes: 40_000)
        try fixture.file(".Trash/old.zip", bytes: 12_000)
        try fixture.file("Library/Application Support/MobileSync/Backup/0000-DEVICE/Manifest.db", bytes: 60_000)

        let groups = JunkScanner(environment: fixture.environment, runningBundleIDs: ["com.vendor.running"]).scan()
        let byKind = Dictionary(uniqueKeysWithValues: groups.map { ($0.kind, $0) })

        XCTAssertEqual(byKind[.userCaches]?.items.map(\.name), ["com.vendor.editor", "com.vendor.running"],
                       "Homebrew is a developer cache, CloudKit is deny-listed, empty folders are dropped")
        XCTAssertEqual(byKind[.userCaches]?.items.map(\.selectedByDefault), [true, false])
        XCTAssertEqual(Set(byKind[.developerCaches]?.items.map(\.name) ?? []), ["Homebrew downloads", "npm cache"])
        XCTAssertEqual(byKind[.xcode]?.items.map(\.name), ["MyApp build data", "Archives from 2026-01-01"])
        XCTAssertEqual(byKind[.xcode]?.items.map(\.selectedByDefault), [true, false])
        XCTAssertEqual(byKind[.incompleteDownloads]?.items.map(\.name), ["film.mkv.crdownload"])
        XCTAssertEqual(byKind[.iosBackups]?.items.first?.selectedByDefault, false)
        XCTAssertEqual(byKind[.trash]?.items.map(\.name), ["old.zip"])
        XCTAssertEqual(byKind[.userLogs]?.items.count, 1)

        // Whatever the scanner offers, the guard must accept: the two may never drift apart.
        let guardian = SafetyGuard(environment: fixture.environment)
        for item in groups.flatMap(\.items) {
            XCTAssertNoThrow(try guardian.validate(item.url, purpose: item.kind.removalPurpose), item.url.path)
        }
    }

    func testUninstallerFindsLeftoversButNotSiblingApps() throws {
        let fixture = try Fixture()
        try fixture.app("Applications/Browser.app", bundleID: "com.vendor.Browser", name: "Browser")
        try fixture.app("Applications/Suite/Browser Canary.app", bundleID: "com.vendor.Browser.canary", name: "Browser Canary")
        try fixture.app("Applications/Go.app", bundleID: "org.tools.go", name: "Go")
        try fixture.app("Applications/Notes.app", bundleID: "com.apple.Notes")

        try fixture.file("Library/Application Support/Browser/profile.db", bytes: 50_000)
        try fixture.file("Library/Caches/com.vendor.Browser/cache.bin", bytes: 20_000)
        try fixture.file("Library/Preferences/com.vendor.Browser.plist", bytes: 500)
        try fixture.file("Library/Saved Application State/com.vendor.Browser.savedState/window.data", bytes: 500)
        try fixture.file("Library/Group Containers/ABCDE12345.com.vendor.Browser/shared.db", bytes: 500)
        try fixture.file("Library/Preferences/com.vendor.Browser.canary.plist", bytes: 500)
        try fixture.file("Library/Caches/com.vendor.BrowserHelperUnrelated/x", bytes: 500)
        try fixture.file("Library/Application Support/Go/unrelated-folder-with-short-name", bytes: 500)

        let inventory = AppInventory(environment: fixture.environment)
        let apps = inventory.scan()
        XCTAssertEqual(apps.map(\.name), ["Browser", "Browser Canary", "Go"], "Apple apps are not offered")

        let browser = try XCTUnwrap(apps.first { $0.name == "Browser" })
        XCTAssertEqual(Set(browser.leftovers.map(\.url.lastPathComponent)),
                       ["Browser", "com.vendor.Browser", "com.vendor.Browser.plist",
                        "com.vendor.Browser.savedState", "ABCDE12345.com.vendor.Browser"])
        XCTAssertEqual(apps.first { $0.name == "Browser Canary" }?.leftovers.map(\.url.lastPathComponent),
                       ["com.vendor.Browser.canary.plist"])
        XCTAssertEqual(apps.first { $0.name == "Go" }?.leftovers.count, 0)

        let report = inventory.uninstall(browser, leftovers: browser.leftovers, mode: .permanent)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(fixture.exists("Applications/Browser.app"))
        XCTAssertFalse(fixture.exists("Library/Application Support/Browser"))
        XCTAssertTrue(fixture.exists("Library/Preferences/com.vendor.Browser.canary.plist"))
        XCTAssertTrue(fixture.exists("Applications/Suite/Browser Canary.app"))
    }

    func testLaunchAgentsFlagMissingExecutables() throws {
        let fixture = try Fixture()
        let agents = try fixture.directory("Library/LaunchAgents")
        func write(_ name: String, program: String) throws {
            let plist: [String: Any] = ["Label": name, "ProgramArguments": [program, "--daemon"], "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: agents.appendingPathComponent(name + ".plist"))
        }
        try write("com.vendor.alive", program: "/bin/ls")
        try write("com.vendor.orphan", program: "/Applications/Removed.app/Contents/MacOS/helper")

        let scanner = LaunchItemScanner(environment: fixture.environment)
        let items = scanner.scan()
        XCTAssertEqual(items.map(\.label), ["com.vendor.orphan", "com.vendor.alive"])
        XCTAssertEqual(items.map(\.isBroken), [true, false])

        XCTAssertTrue(scanner.remove(items[0], mode: .permanent).failures.isEmpty)
        XCTAssertFalse(fixture.exists("Library/LaunchAgents/com.vendor.orphan.plist"))
    }

    func testSystemSamplerProducesPlausibleNumbers() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        let snapshot = sampler.sample()
        XCTAssertGreaterThan(snapshot.memoryTotal, 1 << 30)
        XCTAssertTrue((0.01...1).contains(snapshot.memoryFraction))
        XCTAssertGreaterThan(snapshot.diskTotal, snapshot.diskAvailable)
        XCTAssertTrue((0...1).contains(snapshot.cpuUsage))
        XCTAssertGreaterThan(ProcessList.sample().count, 10)
    }

    func testExtraReadingsArePlausibleOnThisMac() throws {
        let pressure = try XCTUnwrap(MemoryPressure.current())
        XCTAssertTrue((0...1).contains(pressure))

        let first = NetworkCounters.current()
        XCTAssertGreaterThan(first.received, 0, "a Mac that has been online has received something on en*")
        XCTAssertGreaterThanOrEqual(NetworkCounters.current().received, first.received)

        if let temperature = ThermalSensors()?.cpuTemperature() {
            print("CPU temperature: \(temperature) °C")
            XCTAssertTrue((15...115).contains(temperature), "\(temperature)")
        } else {
            print("CPU temperature: sensors not available")
        }
        if let battery = BatteryHealth.current() {
            print("Battery: \(battery.cycleCount) cycles, \(Int(battery.capacity * 100))% capacity")
            XCTAssertTrue((0.3...1).contains(battery.capacity))
        }
        print("Volumes:", ExternalVolume.mounted().map(\.name))
    }

    func testHealthScoreReflectsTheWorstProblems() {
        var snapshot = SystemSnapshot()
        snapshot.diskTotal = 1000; snapshot.diskAvailable = 500
        XCTAssertEqual(HealthAssessment.assess(snapshot).grade, .good)
        XCTAssertEqual(HealthAssessment.assess(snapshot).score, 100)

        snapshot.diskAvailable = 50
        snapshot.memoryPressure = 0.9
        let bad = HealthAssessment.assess(snapshot, brokenLaunchItems: 1)
        XCTAssertEqual(bad.score, 40)
        XCTAssertEqual(bad.grade, .poor)
        XCTAssertEqual(bad.concerns.first, "Startup disk is almost full")
    }

    func testAppUsageGroupsProcessesAndProducesSaneRates() throws {
        XCTAssertEqual(AppUsageSampler.bundlePath(in: "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                       "/Applications/Chrome.app", "helpers roll up into the outermost bundle")
        XCTAssertNil(AppUsageSampler.bundlePath(in: "/usr/sbin/cfprefsd"))

        let sampler = AppUsageSampler()
        let mine = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(sampler.sample().first { $0.pids.contains(mine) }?.cpu, 0, "no rate without a previous sample")

        // Burn a core for the interval so there is a known consumer to find: this test process.
        let deadline = Date().addingTimeInterval(1.0)
        var spin = 0.0
        while Date() < deadline { spin += sqrt(Double.random(in: 1...2)) }
        XCTAssertGreaterThan(spin, 0)

        let apps = sampler.sample(includeNetwork: true)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let totalCPU = apps.reduce(0) { $0 + $1.cpu }
        XCTAssertLessThan(totalCPU, cores * 100 * 1.2, "sum of per-app CPU cannot exceed the machine")

        let me = try XCTUnwrap(apps.first { $0.pids.contains(mine) })
        print("This test process: \(Int(me.cpu))% CPU, \(Format.bytes(me.memory)), \(String(format: "%.2f", me.power)) W")
        XCTAssertTrue((0.3...25).contains(me.power), "a busy core draws on the order of watts, got \(me.power)")
        XCTAssertTrue((60...140).contains(me.cpu), "one busy thread is about 100% of a core, got \(me.cpu)")

        let byMemory = apps.sorted { $0.memory > $1.memory }.prefix(4)
        print("Top memory:", byMemory.map { "\($0.name) \(Format.bytes($0.memory)) (\($0.processCount) procs)" })
        XCTAssertGreaterThan(byMemory.first?.memory ?? 0, 100 << 20)
        print("Top CPU:", apps.sorted { $0.cpu > $1.cpu }.prefix(3).map { "\($0.name) \(Int($0.cpu))%" })
        print("Top power:", apps.sorted { $0.power > $1.power }.prefix(3).map { "\($0.name) \(String(format: "%.2f", $0.power)) W" })
    }

    func testVitalsReadPlausibleValuesOnThisMac() throws {
        let swap = try XCTUnwrap(SwapUsage.current())
        XCTAssertLessThanOrEqual(swap.used, max(swap.total, 1))
        XCTAssertEqual(LoadAverage.current().count, 3)

        let disk = try XCTUnwrap(DiskSpace.startupVolume())
        XCTAssertGreaterThan(disk.total, disk.available)
        XCTAssertGreaterThanOrEqual(disk.available, disk.free)
        print("Disk: \(Format.bytes(disk.free)) free + \(Format.bytes(disk.purgeable)) purgeable of \(Format.bytes(disk.total))")

        let power = PowerDetails.current()
        print("Power: system \(power.systemWatts.map { String(format: "%.1f W", $0) } ?? "–"), adapter \(power.adapterWatts.map { "\($0) W" } ?? "–"), battery \(power.batteryTemperature.map { String(format: "%.1f °C", $0) } ?? "–"), remaining \(power.minutesRemaining.map(String.init) ?? "–") min")
        if let watts = power.systemWatts { XCTAssertTrue((0.5...300).contains(watts), "\(watts)") }
        if let temperature = power.batteryTemperature { XCTAssertTrue((5...70).contains(temperature)) }

        let link = try XCTUnwrap(NetworkLink.current(), "this Mac is online")
        print("Link: \(link.kind.rawValue) on \(link.interface) \(link.address), VPN \(link.vpnActive)")
        XCTAssertTrue(link.address.split(separator: ".").count == 4)

        let snapshot = { let s = SystemSampler(); _ = s.sample(); return s.sample() }()
        XCTAssertEqual(snapshot.loadAverage.count, 3)
        XCTAssertGreaterThanOrEqual(snapshot.diskAvailable, snapshot.diskFree)
    }

    func testKeepAwakeHoldsAndReleasesASystemAssertion() throws {
        func assertionListed() -> Bool {
            (Shell.run("/usr/bin/pmset", ["-g", "assertions"]).output ?? "").contains(KeepAwake.assertionName)
        }
        let awake = KeepAwake()
        XCTAssertTrue(awake.start(for: 120))
        XCTAssertTrue(awake.isActive)
        XCTAssertTrue(assertionListed(), "macOS should list the assertion")
        let end = try XCTUnwrap(awake.endsAt)
        XCTAssertEqual(end.timeIntervalSinceNow, 120, accuracy: 3)
        awake.stop()
        XCTAssertFalse(awake.isActive)
        XCTAssertFalse(assertionListed(), "released on stop")
    }

    func testEjectsAMountedDiskImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sweepwell-eject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("SweepwellEjectTest.dmg")
        XCTAssertTrue(Shell.run("/usr/bin/hdiutil", ["create", "-size", "4m", "-fs", "HFS+", "-volname", "SweepwellEjectTest", image.path]).succeeded)
        XCTAssertTrue(Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", image.path]).succeeded)

        // -nobrowse hides it from Finder but it is still an ejectable volume.
        let volume = try XCTUnwrap(ExternalVolume.mounted().first { $0.name == "SweepwellEjectTest" }
            ?? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
                .first { $0.lastPathComponent == "SweepwellEjectTest" }
                .map { ExternalVolume(url: $0, name: "SweepwellEjectTest", total: 0, available: 0) })
        XCTAssertTrue(volume.isDiskImage)
        try volume.eject()
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.url.path), "unmounted")
    }

    func testMemoryBreakdownIsPlausible() throws {
        let memory = try XCTUnwrap(MemoryBreakdown.current())
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        print("RAM: \(Format.bytes(memory.free)) free, \(Format.bytes(memory.cachedFiles)) cached files, \(Format.bytes(memory.inactive)) inactive")
        XCTAssertGreaterThan(memory.free, 0)
        XCTAssertLessThan(memory.free + memory.cachedFiles, total)
        XCTAssertLessThan(memory.inactive, total)
    }

    func testJunkScanCanBeLimitedToAppCaches() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.vendor.editor/data", bytes: 50_000)
        try fixture.file("Library/Caches/com.vendor.running/data", bytes: 20_000)
        try fixture.file("Library/Logs/app.log", bytes: 8_000)
        try fixture.file(".Trash/old.zip", bytes: 12_000)
        let groups = JunkScanner(environment: fixture.environment, runningBundleIDs: ["com.vendor.running"]).scan(kinds: [.userCaches])
        XCTAssertEqual(groups.map(\.kind), [.userCaches])
        XCTAssertEqual(groups.first?.items.filter(\.selectedByDefault).map(\.name), ["com.vendor.editor"],
                       "a running app's cache is listed but not chosen")
    }
}
