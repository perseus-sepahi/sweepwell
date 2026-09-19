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
}
