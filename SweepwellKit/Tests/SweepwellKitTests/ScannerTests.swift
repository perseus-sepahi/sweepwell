import XCTest
@testable import SweepwellKit

final class ScannerTests: XCTestCase {
    func testBulkReaderAgreesWithLstatFallback() throws {
        let fixture = try Fixture()
        for i in 0..<300 { try fixture.file("many/file-\(i).bin", bytes: 100 + i * 37) }
        try fixture.directory("many/sub")
        try FileManager.default.createSymbolicLink(at: fixture.url("many/link"), withDestinationURL: fixture.url("many/file-1.bin"))

        let path = fixture.url("many").path
        let fast = try FastDirectoryReader.read(path).sorted { $0.name < $1.name }
        let slow = try FastDirectoryReader.readSlow(path).sorted { $0.name < $1.name }

        XCTAssertEqual(fast.count, 302)
        XCTAssertEqual(fast.map(\.name), slow.map(\.name))
        XCTAssertEqual(fast.map(\.kind), slow.map(\.kind))
        XCTAssertEqual(fast.map(\.allocatedSize), slow.map(\.allocatedSize))
        XCTAssertEqual(fast.map(\.logicalSize), slow.map(\.logicalSize))
        XCTAssertEqual(fast.map(\.fileID), slow.map(\.fileID))
        for (a, b) in zip(fast, slow) {
            XCTAssertEqual(a.modified.timeIntervalSince1970, b.modified.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testMeasureMatchesDu() throws {
        let fixture = try Fixture()
        for i in 0..<40 { try fixture.file("tree/a/b\(i % 5)/f\(i)", bytes: 1000 * (i + 1)) }
        try fixture.file("tree/big.bin", bytes: 3 << 20)

        let du = Shell.run("/usr/bin/du", ["-sk", fixture.url("tree").path]).output ?? ""
        let duBytes = Int64(du.split(separator: "\t").first.flatMap { Int($0) } ?? -1) * 1024
        let measured = DiskScanner.measure(fixture.url("tree"))

        XCTAssertEqual(measured.files, 41)
        // du also charges the directories' own blocks, which are zero on APFS.
        XCTAssertEqual(measured.bytes, duBytes)
    }

    func testTreeAggregatesSmallFilesAndCountsHardLinksOnce() throws {
        let fixture = try Fixture()
        try fixture.file("root/big.bin", bytes: 2 << 20)
        try fixture.file("root/small1", bytes: 5000)
        try fixture.file("root/small2", bytes: 5000)
        try fixture.file("root/nested/deep/large.bin", bytes: 4 << 20)
        try FileManager.default.linkItem(at: fixture.url("root/big.bin"), to: fixture.url("root/nested/hardlink.bin"))
        // A symlink to a big folder elsewhere must not be followed.
        try fixture.file("elsewhere/huge.bin", bytes: 8 << 20)
        try FileManager.default.createSymbolicLink(at: fixture.url("root/shortcut"), withDestinationURL: fixture.url("elsewhere"))

        let tree = DiskScanner.scanTree(root: fixture.url("root"), control: ScanControl())

        XCTAssertEqual(tree.fileCount, 4, "hard link counted once, symlink ignored")
        XCTAssertEqual(tree.size, DiskScanner.measure(fixture.url("root")).bytes)
        XCTAssertEqual(tree.children.first?.name, "nested")
        let aggregate = try XCTUnwrap(tree.children.first { $0.isAggregate })
        XCTAssertEqual(aggregate.fileCount, 2)
        XCTAssertEqual(tree.children.first?.children.first?.children.first?.path,
                       fixture.url("root/nested/deep/large.bin").resolvingSymlinksInPath().path)

        let before = tree.size
        let nested = try XCTUnwrap(tree.children.first)
        tree.removeChild(nested)
        XCTAssertEqual(tree.size, before - nested.size)
    }

    func testLargeFilesReportBundlesWholeAndSkipMediaLibraries() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/movie.mov", bytes: 3 << 20)
        try fixture.file("Documents/note.txt", bytes: 100)
        try fixture.file("Documents/.hidden/secret.bin", bytes: 3 << 20)
        try fixture.file("Documents/VM.utm/disk.img", bytes: 2 << 20)
        try fixture.file("Documents/VM.utm/nvram.bin", bytes: 2 << 20)
        try fixture.file("Pictures/Photos.photoslibrary/originals/a.heic", bytes: 5 << 20)

        let found = DiskScanner.findLargeFiles(in: [fixture.url("Documents"), fixture.url("Pictures")],
                                               minimumSize: 1 << 20, control: ScanControl())

        XCTAssertEqual(found.map(\.url.lastPathComponent), ["VM.utm", "movie.mov"])
        XCTAssertTrue(found[0].isPackage)
        XCTAssertGreaterThanOrEqual(found[0].size, 4 << 20)
    }

    func testCancelledScanStopsEarly() throws {
        let fixture = try Fixture()
        for i in 0..<20 { try fixture.file("c/d\(i)/f", bytes: 10) }
        let control = ScanControl()
        control.cancel()
        XCTAssertEqual(DiskScanner.scanTree(root: fixture.url("c"), control: control).fileCount, 0)
    }

    func testDuplicatesNeedIdenticalContent() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/original.bin", bytes: 200_000, fill: 1)
        try fixture.file("Documents/copies/copy.bin", bytes: 200_000, fill: 1)
        try fixture.file("Downloads/another copy.bin", bytes: 200_000, fill: 1)
        try fixture.file("Documents/same-size-other-content.bin", bytes: 200_000, fill: 2)
        try fixture.file("Documents/tiny-a", bytes: 10, fill: 1)
        try fixture.file("Documents/tiny-b", bytes: 10, fill: 1)
        // Differs only after the first 64 KB: must survive the head-hash pass and fail the full one.
        var tail = Data(repeating: 1, count: 200_000)
        tail[199_999] = 9
        try tail.write(to: fixture.url("Documents/late-difference.bin"))
        try FileManager.default.linkItem(at: fixture.url("Documents/original.bin"), to: fixture.url("Documents/hardlink.bin"))

        let groups = DuplicateFinder.find(in: [fixture.url("Documents"), fixture.url("Downloads"), fixture.url("Documents/copies")],
                                          minimumSize: 1000, control: ScanControl())

        XCTAssertEqual(groups.count, 1)
        let names = Set(groups[0].files.map(\.url.lastPathComponent))
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.isSuperset(of: ["copy.bin", "another copy.bin"]))
        XCTAssertFalse(names.contains("late-difference.bin"))
        XCTAssertEqual(groups[0].wastedBytes, groups[0].size * 2)
    }

    func testTreemapTilesTheBoundsProportionally() {
        let values: [Double] = [500, 300, 120, 50, 20, 6, 3, 1]
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 360)
        let rects = Treemap.layout(values, in: bounds)
        let scale = Double(bounds.width * bounds.height) / values.reduce(0, +)

        for (value, rect) in zip(values, rects) {
            XCTAssertEqual(Double(rect.width * rect.height), value * scale, accuracy: 0.01)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect), "\(rect)")
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.001, "\(i) overlaps \(j)")
            }
        }
        // The point of squarifying: the big blocks must not be slivers.
        XCTAssertLessThan(max(rects[0].width / rects[0].height, rects[0].height / rects[0].width), 3)
        XCTAssertEqual(Treemap.layout([], in: bounds).count, 0)
        XCTAssertEqual(Treemap.layout([0, 0], in: bounds), [.zero, .zero])
    }
}
