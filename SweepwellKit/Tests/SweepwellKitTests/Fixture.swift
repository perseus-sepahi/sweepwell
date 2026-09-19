import Foundation
import XCTest
@testable import SweepwellKit

/// A disposable home folder. Every test works in here, never in the real account.
final class Fixture {
    let home: URL
    var environment: ScanEnvironment { .fixture(home: home) }

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweepwell-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func url(_ relativePath: String) -> URL { home.appendingPathComponent(relativePath) }

    @discardableResult
    func file(_ relativePath: String, bytes: Int = 4096, fill: UInt8 = 0x5A) throws -> URL {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func app(_ relativePath: String, bundleID: String, name: String? = nil, payload: Int = 8192) throws -> URL {
        let bundle = url(relativePath)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.2"]
        if let name { plist["CFBundleName"] = name }
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 1, count: payload).write(to: contents.appendingPathComponent("MacOS/main"))
        return bundle
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }
}
