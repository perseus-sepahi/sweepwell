import Foundation
import Darwin

/// Resource use of one app: all of its processes (helpers, renderers, XPC services) rolled
/// into a single row, which is the level people think at.
public struct AppUsage: Identifiable, Sendable, Hashable {
    public var id: String { bundleURL?.path ?? "proc:" + name }
    public let name: String
    /// The enclosing .app, when the processes belong to one.
    public let bundleURL: URL?
    public var processCount = 0
    public var pids: [Int32] = []
    /// Percent of one core, summed over the app's processes (so it can exceed 100).
    public var cpu: Double = 0
    /// Physical footprint where readable (what Activity Monitor shows), resident size otherwise.
    public var memory: Int64 = 0
    /// Bytes per second.
    public var diskRead: Double = 0
    public var diskWrite: Double = 0
    public var networkIn: Double = 0
    public var networkOut: Double = 0
    /// Watts, from the kernel's per-process energy accounting. Own processes only.
    public var power: Double = 0
}

/// Samples every process and aggregates by app. Rates are deltas between two calls, so keep
/// one sampler alive and call `sample()` on a timer; the first call reports zero rates.
public final class AppUsageSampler: @unchecked Sendable {
    private struct Counters {
        var cpuNanoseconds: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var energy: UInt64
    }

    private let lock = NSLock()
    private var previous: [Int32: Counters] = [:]
    private var previousNetwork: [Int32: (received: UInt64, sent: UInt64)] = [:]
    private var previousTime: Date?
    private var pathCache: [Int32: String] = [:]

    /// `rusage` reports CPU time in Mach absolute time units; on Apple silicon one unit is
    /// 125/3 ns, so skipping this conversion makes every figure wrong by about 41×.
    private let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(max(timebase.denom, 1))
    }()

    public init() {}

    /// - Parameter includeNetwork: per-process traffic needs a `nettop` run, so it is only
    ///   gathered when a view is actually showing it.
    public func sample(includeNetwork: Bool = false) -> [AppUsage] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        previousTime = now

        var capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        capacity = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let live = pids.prefix(max(0, capacity)).filter { $0 > 0 }

        var apps: [String: AppUsage] = [:]
        var current: [Int32: Counters] = [:]
        var unreadable: Set<Int32> = []

        for pid in live {
            guard let path = path(of: pid) else { continue }
            var info = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            var usage = apps[Self.key(for: path)] ?? Self.emptyUsage(for: path)
            usage.processCount += 1
            usage.pids.append(pid)
            if status == 0 {
                let counters = Counters(cpuNanoseconds: UInt64(Double(info.ri_user_time + info.ri_system_time) * nanosecondsPerTick),
                                        diskRead: info.ri_diskio_bytesread, diskWrite: info.ri_diskio_byteswritten,
                                        // V6's own meter. The older `ri_billed_energy` only counts work billed
                                        // to a process by others and stays near zero.
                                        energy: info.ri_energy_nj)
                current[pid] = counters
                usage.memory += Int64(info.ri_phys_footprint)
                if let before = previous[pid], elapsed > 0.2, counters.cpuNanoseconds >= before.cpuNanoseconds {
                    usage.cpu += Double(counters.cpuNanoseconds - before.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100
                    usage.diskRead += Double(counters.diskRead &- before.diskRead) / elapsed
                    usage.diskWrite += Double(counters.diskWrite &- before.diskWrite) / elapsed
                    // Nanojoules per second ÷ 1e9 = watts.
                    if counters.energy >= before.energy {
                        usage.power += Double(counters.energy - before.energy) / elapsed / 1_000_000_000
                    }
                }
            } else {
                unreadable.insert(pid)
            }
            apps[usage.id] = usage
        }
        previous = current
        pathCache = pathCache.filter { current[$0.key] != nil || unreadable.contains($0.key) }

        // System-owned processes refuse `rusage`. `ps` can still see their CPU and resident
        // size, which is enough to keep WindowServer and friends on the list.
        if !unreadable.isEmpty { mergeSystemProcesses(unreadable, into: &apps) }
        if includeNetwork { mergeNetwork(elapsed: elapsed, into: &apps) } else { previousNetwork = [:] }
        return Array(apps.values)
    }

    // MARK: Pieces

    private func path(of pid: Int32) -> String? {
        if let cached = pathCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        pathCache[pid] = path
        return path
    }

    /// The outermost bundle wins: a helper at `Chrome.app/…/Helper.app/…` counts as Chrome.
    static func bundlePath(in executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    private static func key(for path: String) -> String {
        bundlePath(in: path) ?? "proc:" + (path as NSString).lastPathComponent
    }

    private static func emptyUsage(for path: String) -> AppUsage {
        if let bundle = bundlePath(in: path) {
            let url = URL(fileURLWithPath: bundle)
            return AppUsage(name: url.deletingPathExtension().lastPathComponent, bundleURL: url)
        }
        return AppUsage(name: (path as NSString).lastPathComponent, bundleURL: nil)
    }

    private func mergeSystemProcesses(_ pids: Set<Int32>, into apps: inout [String: AppUsage]) {
        guard let output = Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss="]).output else { return }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), pids.contains(pid),
                  let cpu = Double(fields[1]), let rssKB = Int64(fields[2]), let path = pathCache[pid] else { continue }
            let key = Self.key(for: path)
            apps[key]?.cpu += cpu
            apps[key]?.memory += rssKB * 1024
        }
    }

    /// `nettop` prints cumulative bytes per process as "name.pid,bytes_in,bytes_out,".
    private func mergeNetwork(elapsed: TimeInterval, into apps: inout [String: AppUsage]) {
        guard let output = Shell.run("/usr/bin/nettop", ["-P", "-x", "-L", "1", "-n", "-J", "bytes_in,bytes_out"]).output else { return }
        var current: [Int32: (received: UInt64, sent: UInt64)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { continue }
            current[pid] = (received, sent)
            guard let before = previousNetwork[pid], elapsed > 0.2, let path = pathCache[pid],
                  received >= before.received, sent >= before.sent else { continue }
            let key = Self.key(for: path)
            apps[key]?.networkIn += Double(received - before.received) / elapsed
            apps[key]?.networkOut += Double(sent - before.sent) / elapsed
        }
        previousNetwork = current
    }
}
