import CryptoKit
import XCTest
@testable import SweepwellKit

final class LicensingTests: XCTestCase {
    private var home: URL!
    private let signer = Curve25519.Signing.PrivateKey()
    private var publicKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }
    private var ledger: ProLedger {
        ProLedger(environment: ScanEnvironment(home: home, applicationDirectories: [], isFixture: true), publicKey: publicKey)
    }
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func key(product: String = LicenceKey.product, id: String = "pi_1") throws -> String {
        let payload = Data(#"{"p":"\#(product)","id":"\#(id)","t":1800000000}"#.utf8).base64URL
        return "KGP1.\(payload).\(try signer.signature(for: Data(payload.utf8)).base64URL)"
    }

    // MARK: Keys

    /// The exact key the licence Worker's own test produces, so both sides agree on the format.
    func testVerifiesAKeyMadeByTheLicenceWorker() throws {
        let fixture = "KGP1.eyJwIjoia2lub2dsb3QtcHJvIiwiaWQiOiJwaV90ZXN0MTIzIiwidCI6MTc2MTE3NzYwMH0.ba83T7KobZfC_l8mBI4rYAJSNc3rYd_sBf43-9Ca5WQoD2TqKFWhv8gNcUmwMsPrryhAnxMpjrZU9zqosk2fAQ"
        let key = try LicenceKey.verify(fixture, publicKey: "LgigH1J2/SofiqCvecXEdYiRLHhg9DOf9fm24yH1AEU=", product: "kinoglot-pro")
        XCTAssertEqual(key.id, "pi_test123")
    }

    func testRefusesTamperedKeysAndOtherProducts() throws {
        let good = try key()
        XCTAssertEqual(try LicenceKey.verify(good, publicKey: publicKey).id, "pi_1")
        XCTAssertEqual(try LicenceKey.verify(" \(good)\n", publicKey: publicKey).id, "pi_1", "pasting with spaces works")

        let parts = good.split(separator: ".").map(String.init)
        let forged = Data(#"{"p":"sweepwell-pro","id":"pi_2","t":1}"#.utf8).base64URL
        XCTAssertThrowsError(try LicenceKey.verify("KGP1.\(forged).\(parts[2])", publicKey: publicKey)) {
            XCTAssertEqual($0 as? LicenceKey.Problem, .signature)
        }
        XCTAssertThrowsError(try LicenceKey.verify(try key(product: "kinoglot-pro"), publicKey: publicKey)) {
            XCTAssertEqual($0 as? LicenceKey.Problem, .product)
        }
        XCTAssertThrowsError(try LicenceKey.verify("not a key", publicKey: publicKey))
    }

    // MARK: Trial

    func testTrialCountsDownSevenDaysThenEnds() {
        XCTAssertEqual(ledger.status(now: start), .trial(daysLeft: 7))
        XCTAssertEqual(ledger.status(now: start + day * 0.5), .trial(daysLeft: 7))
        XCTAssertEqual(ledger.status(now: start + day * 6.5), .trial(daysLeft: 1))
        XCTAssertTrue(ledger.status(now: start + day * 6.99).unlocked)
        XCTAssertEqual(ledger.status(now: start + day * 7), .expired)
        XCTAssertFalse(ledger.status(now: start + day * 30).unlocked)
    }

    func testDeletingOneCopyDoesNotRestartTheTrial() throws {
        _ = ledger.status(now: start)
        for index in ledger.copies.indices {
            try FileManager.default.removeItem(at: ledger.copies[index])
            XCTAssertEqual(ledger.status(now: start + day * 3), .trial(daysLeft: 4), "copy \(index) was restored")
            XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.copies[index].path))
        }
    }

    func testMovingTheClockBackAddsNoDays() {
        _ = ledger.status(now: start)
        _ = ledger.status(now: start + day * 8)
        XCTAssertEqual(ledger.status(now: start + day), .expired)
    }

    // MARK: Purchase

    func testPurchaseUnlocksSurvivesRelaunchAndRefundRemovesIt() throws {
        _ = ledger.status(now: start)
        XCTAssertEqual(ledger.status(now: start + day * 9), .expired)
        let good = try key()

        try ledger.activate(good, now: start + day * 9)
        guard case .licensed(let licence) = ledger.status(now: start + day * 400) else { return XCTFail("not licensed") }
        XCTAssertEqual(licence.id, "pi_1")

        XCTAssertTrue(ledger.revocationCheckDue(now: start + day * 400))
        ledger.applyRevocations(["pi_other"], now: start + day * 400)
        XCTAssertFalse(ledger.revocationCheckDue(now: start + day * 401), "checked this week")
        XCTAssertTrue(ledger.revocationCheckDue(now: start + day * 408))
        XCTAssertTrue(ledger.status(now: start + day * 401).unlocked, "someone else's refund changes nothing")

        ledger.applyRevocations(["pi_1"], now: start + day * 408)
        XCTAssertEqual(ledger.status(now: start + day * 408), .expired)
    }

    func testABadKeyIsNotStoredAndNoCheckRunsWithoutOne() {
        XCTAssertThrowsError(try ledger.activate("KGP1.a.b"))
        XCTAssertEqual(ledger.status(now: start), .trial(daysLeft: 7))
        XCTAssertFalse(ledger.revocationCheckDue(now: start), "a trial never touches the network")
    }
}

private extension ContiguousBytes {
    var base64URL: String {
        withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
