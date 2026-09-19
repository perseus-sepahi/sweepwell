import Foundation

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        case userAgent = "Your account"
        case globalAgent = "All users"
        case daemon = "System daemon"
    }

    public var id: String { plistURL.path }
    public let plistURL: URL
    public let label: String
    public let program: String?
    public let scope: Scope
    public let runsAtLoad: Bool
    public let isLoaded: Bool
    /// The executable it points at no longer exists: a leftover of a removed app.
    public let isBroken: Bool

    /// Only per-user agents can be removed without administrator rights.
    public var isRemovable: Bool { scope == .userAgent }
}

public struct LaunchItemScanner: Sendable {
    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment) { self.environment = environment }

    public func scan() -> [LaunchItem] {
        var sources: [(URL, LaunchItem.Scope)] = [(environment.library.appendingPathComponent("LaunchAgents"), .userAgent)]
        if !environment.isFixture {
            sources.append((URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent))
            sources.append((URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon))
        }
        let loaded = environment.isFixture ? [] : Self.loadedLabels()

        var items: [LaunchItem] = []
        for (directory, scope) in sources {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                let label = (plist["Label"] as? String) ?? (name as NSString).deletingPathExtension
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                var broken = false
                if let program, program.hasPrefix("/") {
                    broken = !FileManager.default.fileExists(atPath: program)
                }
                items.append(LaunchItem(plistURL: url, label: label, program: program, scope: scope,
                                        runsAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
                                        isLoaded: loaded.contains(label), isBroken: broken))
            }
        }
        // Broken items first: they are the ones worth acting on.
        return items.sorted {
            ($0.isBroken ? 0 : 1, $0.scope.rawValue, $0.label) < ($1.isBroken ? 0 : 1, $1.scope.rawValue, $1.label)
        }
    }

    /// Stops the agent if it is running, then removes its plist so it never starts again.
    public func remove(_ item: LaunchItem, mode: RemovalMode) -> RemovalReport {
        if item.isLoaded, !environment.isFixture {
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
        }
        return Remover(environment: environment)
            .remove([RemovalRequest(url: item.plistURL, size: 0, purpose: .launchAgent)], mode: mode)
    }

    private static func loadedLabels() -> Set<String> {
        guard let output = Shell.run("/bin/launchctl", ["list"]).output else { return [] }
        // Columns: PID, last exit status, label.
        return Set(output.split(separator: "\n").dropFirst().compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        })
    }
}

public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String?
        public var succeeded: Bool { status == 0 }
    }

    /// Runs a fixed executable with an argument vector; nothing is ever passed through a shell.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(data: data, encoding: .utf8))
    }
}
