import XCTest
@testable import SweepwellKit

/// Read-only sanity check at real-world scale. Opt in with SWEEPWELL_REAL_SCAN=<folder>.
final class RealWorldTests: XCTestCase {
    func testTreeScanAgreesWithDu() throws {
        guard let path = ProcessInfo.processInfo.environment["SWEEPWELL_REAL_SCAN"] else {
            throw XCTSkip("set SWEEPWELL_REAL_SCAN to a folder to run")
        }
        let control = ScanControl()
        let start = Date()
        let tree = DiskScanner.scanTree(root: URL(fileURLWithPath: path), control: control)
        let ours = Date().timeIntervalSince(start)

        let duStart = Date()
        let du = Shell.run("/usr/bin/du", ["-skx", path]).output ?? ""
        let duTime = Date().timeIntervalSince(duStart)
        let duBytes = Int64(du.split(separator: "\n").last?.split(separator: "\t").first.flatMap { Int($0) } ?? 0) * 1024

        print("SCAN files=\(tree.fileCount) size=\(Format.bytes(tree.size)) in \(String(format: "%.2f", ours))s, denied=\(control.inaccessibleDirectories)")
        print("DU   size=\(Format.bytes(duBytes)) in \(String(format: "%.2f", duTime))s")
        XCTAssertEqual(Double(tree.size), Double(duBytes), accuracy: Double(duBytes) * 0.02)
    }

    func testAccountingOnThisMac() throws {
        guard ProcessInfo.processInfo.environment["SWEEPWELL_ACCOUNTING"] == "1" else {
            throw XCTSkip("set SWEEPWELL_ACCOUNTING=1 to run (reads the whole Data volume, a few minutes)")
        }
        let start = Date()
        let result = StorageAuditor(environment: .live).account()
        print("ACCOUNTING consumed=\(Format.bytes(result.consumed)) readable=\(Format.bytes(result.readable)) gap=\(Format.bytes(result.gap)) open-deleted=\(Format.bytes(result.heldByOpenFiles)) snapshots=\(result.localSnapshots) denied=\(result.deniedDirectories) in \(Int(Date().timeIntervalSince(start)))s")
        XCTAssertGreaterThan(result.consumed, result.readable / 2)
        XCTAssertGreaterThan(result.readable, 1 << 30)
    }
}
