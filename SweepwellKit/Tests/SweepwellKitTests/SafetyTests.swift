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

    func testShredderOverwritesBeforeDeletingAndLeavesNoTrace() throws {
        let fixture = try Fixture()
        let secret = Data("PASSWORD=hunter2 ".utf8)
        var payload = Data()
        while payload.count < 3_000_000 { payload.append(secret) }
        try fixture.directory("Documents/secrets/inner")
        try payload.write(to: fixture.url("Documents/secrets/notes.txt"))
        try payload.prefix(5000).write(to: fixture.url("Documents/secrets/inner/small.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.url("Documents/secrets/link"),
                                                   withDestinationURL: fixture.url("Documents/keep.txt"))
        try fixture.file("Documents/keep.txt", bytes: 100)

        // Read each file between its last overwrite pass and its truncation: full length, and
        // not one copy of the secret left. Three passes end on zeros.
        var checked: [String: Bool] = [:]
        let report = Shredder(environment: fixture.environment).shred([fixture.url("Documents/secrets")], passes: .three) { seen in
            checked[seen.name] = !seen.contents.isEmpty && seen.contents.range(of: secret) == nil
                && seen.contents.allSatisfy { $0 == 0 }
        }
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(checked, ["notes.txt": true, "small.txt": true])
        XCTAssertEqual(report.bytesOverwritten, Int64(payload.count + 5000) * 3, "three full passes")
        XCTAssertFalse(fixture.exists("Documents/secrets"))
        XCTAssertTrue(fixture.exists("Documents/keep.txt"), "a symlink's target is never touched")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.url("Documents").path) == ["keep.txt"],
                      "no renamed leftovers")
    }

    func testOnePassWritesRandomBytesOverTheWholeFile() throws {
        let fixture = try Fixture()
        let original = Data(repeating: 0x41, count: 2_000_000)
        try fixture.directory("Documents")
        try original.write(to: fixture.url("Documents/a.bin"))
        var onDisk = Data()
        let report = Shredder(environment: fixture.environment).shred([fixture.url("Documents/a.bin")], passes: .one) { seen in
            onDisk = seen.contents
        }
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(onDisk.count, original.count, "every byte was rewritten, none appended or skipped")
        XCTAssertNil(onDisk.range(of: Data(repeating: 0x41, count: 16)), "no run of the original is left")
        // Random data: all 256 byte values show up and none dominates.
        var counts = [Int](repeating: 0, count: 256)
        for byte in onDisk { counts[Int(byte)] += 1 }
        XCTAssertTrue(counts.allSatisfy { $0 > 6000 && $0 < 9700 }, "looks uniformly random")
        XCTAssertFalse(fixture.exists("Documents/a.bin"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.url("Documents").path), [])
    }

    func testShredderRefusesHardLinksAndDangerousTargets() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/a.txt", bytes: 1000)
        try FileManager.default.linkItem(at: fixture.url("Documents/a.txt"), to: fixture.url("Documents/b.txt"))
        let report = Shredder(environment: fixture.environment).shred([fixture.url("Documents/a.txt")], passes: .one)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(fixture.exists("Documents/a.txt") && fixture.exists("Documents/b.txt"), "nothing touched")

        let guardian = SafetyGuard(environment: fixture.environment)
        try fixture.directory("Projects")
        for path in ["", "Documents", "Desktop", "Projects", "Library/Keychains/login.keychain-db", "Library/Caches/x",
                     ".ssh", ".zshrc", ".Trash"] {
            XCTAssertThrowsError(try guardian.validate(fixture.url(path), purpose: .shred), path.isEmpty ? "home" : path)
        }
        XCTAssertThrowsError(try guardian.validate(URL(fileURLWithPath: "/etc/hosts"), purpose: .shred))
        for path in ["Documents/a.txt", "Projects/old", ".Trash/old.zip", ".ssh/id_old", "Desktop/scan.pdf"] {
            XCTAssertNoThrow(try guardian.validate(fixture.url(path), purpose: .shred), path)
        }
        XCTAssertNoThrow(try guardian.validate(URL(fileURLWithPath: "/Volumes/USB/tax.pdf"), purpose: .shred))
    }

    func testShredConditionsReadOnThisMac() {
        let conditions = ShredConditions.current()
        print("Shred conditions: FileVault \(String(describing: conditions.fileVaultOn)), SSD \(String(describing: conditions.solidState)), snapshots \(conditions.localSnapshots)")
        XCTAssertNotNil(conditions.fileVaultOn)
        XCTAssertNotNil(conditions.solidState)
    }

    func testShredderWipesExtendedAttributesAndResourceFork() throws {
        let fixture = try Fixture()
        let file = try fixture.file("Documents/tagged.txt", bytes: 4096)
        let secret = Array("PASSWORD=hunter2".utf8)
        XCTAssertEqual(setxattr(file.path, "com.example.secret", secret, secret.count, 0, 0), 0)
        XCTAssertEqual(setxattr(file.path, XATTR_RESOURCEFORK_NAME, secret, secret.count, 0, 0), 0)
        var remaining: [String]?
        let report = Shredder(environment: fixture.environment).shred([file], passes: .one) {
            remaining = $0.remainingAttributes.filter { !Shredder.systemAttributes.contains($0) }
        }
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(remaining, [], "every attribute, the resource fork included, is gone before the file is")
        XCTAssertFalse(fixture.exists("Documents/tagged.txt"))
    }

    func testShredderNeverFollowsASymlinkSwappedInForAFolder() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/outside/precious.txt", bytes: 1000)
        try fixture.file("Documents/target/inner.txt", bytes: 1000)
        try FileManager.default.createSymbolicLink(at: fixture.url("Documents/target/sub"),
                                                   withDestinationURL: fixture.url("Documents/outside"))
        let report = Shredder(environment: fixture.environment).shred([fixture.url("Documents/target")], passes: .one)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(fixture.exists("Documents/target"))
        XCTAssertTrue(fixture.exists("Documents/outside/precious.txt"), "the link's target is untouched")
        XCTAssertEqual(try Data(contentsOf: fixture.url("Documents/outside/precious.txt")).count, 1000)
    }
}
