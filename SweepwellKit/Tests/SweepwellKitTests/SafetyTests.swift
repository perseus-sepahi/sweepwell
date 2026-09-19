import XCTest
@testable import SweepwellKit

final class SafetyTests: XCTestCase {
    private func assertRefused(_ guardian: SafetyGuard, _ url: URL, _ purpose: RemovalPurpose,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try guardian.validate(url, purpose: purpose), "\(url.path) as \(purpose)", file: file, line: line)
    }

    func testJunkPurposeOnlyReachesRegenerableAreas() throws {
        let fixture = try Fixture()
        let guardian = SafetyGuard(environment: fixture.environment)

        XCTAssertNoThrow(try guardian.validate(fixture.url("Library/Caches/com.vendor.app"), purpose: .junk))
        XCTAssertNoThrow(try guardian.validate(fixture.url("Library/Developer/Xcode/DerivedData/App-abc"), purpose: .junk))
        XCTAssertNoThrow(try guardian.validate(fixture.url(".npm/_cacache"), purpose: .junk))
        XCTAssertNoThrow(try guardian.validate(fixture.url("Downloads/movie.crdownload"), purpose: .junk))

        assertRefused(guardian, fixture.home, .junk)
        assertRefused(guardian, fixture.url("Library"), .junk)
        assertRefused(guardian, fixture.url("Library/Caches"), .junk)
        assertRefused(guardian, fixture.url("Library/Keychains/login.keychain-db"), .junk)
        assertRefused(guardian, fixture.url("Library/Mobile Documents/com~apple~CloudDocs/thesis.tex"), .junk)
        assertRefused(guardian, fixture.url("Library/Mail/V10/MailData"), .junk)
        assertRefused(guardian, fixture.url("Documents/thesis/chapter1.tex"), .junk)
        assertRefused(guardian, fixture.url("Pictures/Photos.photoslibrary"), .junk)
        assertRefused(guardian, fixture.url(".ssh"), .junk)
        assertRefused(guardian, fixture.url(".Trash/old.zip"), .junk)
        assertRefused(guardian, URL(fileURLWithPath: "/usr/local/bin/tool"), .junk)
        assertRefused(guardian, URL(fileURLWithPath: "/"), .junk)
        assertRefused(guardian, fixture.url("Library/Caches/../../Documents/thesis"), .junk)
    }

    func testSymlinkedParentCannotRedirectARemoval() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/thesis.tex")
        try fixture.directory("Library/Caches")
        try FileManager.default.createSymbolicLink(at: fixture.url("Library/Caches/innocent"),
                                                   withDestinationURL: fixture.url("Documents"))
        let guardian = SafetyGuard(environment: fixture.environment)

        // Through the link the path *looks* like a cache file but lands in Documents.
        assertRefused(guardian, fixture.url("Library/Caches/innocent/thesis.tex"), .junk)

        // Removing the link itself is fine, and must leave the target alone.
        let report = Remover(environment: fixture.environment)
            .remove([RemovalRequest(url: fixture.url("Library/Caches/innocent"), size: 0, purpose: .junk)], mode: .permanent)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(fixture.exists("Library/Caches/innocent"))
        XCTAssertTrue(fixture.exists("Documents/thesis.tex"))
    }

    func testOtherPurposes() throws {
        let fixture = try Fixture()
        try fixture.file("loose-file.zip")
        try fixture.directory("Projects")
        try fixture.app("Applications/Tool.app", bundleID: "com.vendor.tool")
        let guardian = SafetyGuard(environment: fixture.environment)

        XCTAssertNoThrow(try guardian.validate(fixture.url("Movies/holiday.mov"), purpose: .userFile))
        XCTAssertNoThrow(try guardian.validate(fixture.url("loose-file.zip"), purpose: .userFile))
        assertRefused(guardian, fixture.url("Projects"), .userFile)
        assertRefused(guardian, fixture.url("Library/Application Support/App/data.db"), .userFile)
        assertRefused(guardian, URL(fileURLWithPath: "/Volumes/Backup"), .userFile)
        XCTAssertNoThrow(try guardian.validate(URL(fileURLWithPath: "/Volumes/Backup/old.dmg"), purpose: .userFile))

        XCTAssertNoThrow(try guardian.validate(fixture.url(".Trash/old.zip"), purpose: .trashContents))
        assertRefused(guardian, fixture.url(".Trash"), .trashContents)
        assertRefused(guardian, fixture.url("Documents/old.zip"), .trashContents)

        XCTAssertNoThrow(try guardian.validate(fixture.url("Applications/Tool.app"), purpose: .application))
        assertRefused(guardian, fixture.url("Applications/Tool.app/Contents/Helper.app"), .application)
        assertRefused(guardian, fixture.url("Applications"), .application)
        assertRefused(guardian, fixture.url("Documents/Tool.app"), .application)
        assertRefused(guardian, URL(fileURLWithPath: "/System/Applications/Mail.app"), .application)

        XCTAssertNoThrow(try guardian.validate(fixture.url("Library/Preferences/com.vendor.tool.plist"), purpose: .appLeftover))
        assertRefused(guardian, fixture.url("Library/Keychains/com.vendor.tool"), .appLeftover)
        assertRefused(guardian, fixture.url("Library/Preferences"), .appLeftover)

        XCTAssertNoThrow(try guardian.validate(fixture.url("Library/LaunchAgents/com.vendor.agent.plist"), purpose: .launchAgent))
        assertRefused(guardian, URL(fileURLWithPath: "/Library/LaunchDaemons/com.vendor.daemon.plist"), .launchAgent)
    }

    func testRemoverReportsRefusalsWithoutTouchingAnything() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/keep.txt")
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 9000)
        try fixture.file(".Trash/old.zip", bytes: 5000)

        let report = Remover(environment: fixture.environment).remove([
            RemovalRequest(url: fixture.url("Documents/keep.txt"), size: 1, purpose: .junk),
            RemovalRequest(url: fixture.url("Library/Caches/com.vendor.app"), size: 9000, purpose: .junk),
            RemovalRequest(url: fixture.url(".Trash/old.zip"), size: 5000, purpose: .trashContents),
            RemovalRequest(url: fixture.url("Library/Caches/already-gone"), size: 7, purpose: .junk)
        ], mode: .permanent)

        XCTAssertEqual(report.failures.map(\.url.lastPathComponent), ["keep.txt"])
        XCTAssertEqual(report.bytesFreed, 14000)
        XCTAssertTrue(fixture.exists("Documents/keep.txt"))
        XCTAssertFalse(fixture.exists("Library/Caches/com.vendor.app"))
        XCTAssertFalse(fixture.exists(".Trash/old.zip"))
    }

    func testTrashModeStaysInsideAFixtureHome() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.vendor.app/blob", bytes: 9000)
        try fixture.file(".Trash/com.vendor.app", bytes: 10)

        let report = Remover(environment: fixture.environment)
            .remove([RemovalRequest(url: fixture.url("Library/Caches/com.vendor.app"), size: 9000, purpose: .junk)], mode: .trash)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(fixture.exists("Library/Caches/com.vendor.app"))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.url(".Trash").path)
        XCTAssertEqual(trashed.count, 2, "moved next to the existing item under a unique name: \(trashed)")
    }
}
