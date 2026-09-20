import Foundation
import Darwin
import IOKit.ps

public struct SystemSnapshot: Sendable {
    /// 0…1 across all cores since the previous sample.
    public var cpuUsage: Double = 0
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    /// Bytes held by the memory compressor; a rising share means memory pressure.
    public var memoryCompressed: Int64 = 0
    public var diskTotal: Int64 = 0
    /// Includes purgeable space macOS frees on demand, matching Finder's "available".
    public var diskAvailable: Int64 = 0
    public var batteryLevel: Double?
    public var batteryCharging = false
    public var uptime: TimeInterval = 0
    public var thermalState: ProcessInfo.ThermalState = .nominal
    /// 0…1, the kernel's own view of how squeezed memory is (not the same as "used").
    public var memoryPressure: Double = 0
    /// °C, nil when the sensors are not readable on this Mac.
    public var cpuTemperature: Double?
    /// Bytes per second over the physical network interfaces.
    public var networkIn: Double = 0
    public var networkOut: Double = 0
    public var batteryCycles: Int?
    public var batteryHealth: Double?

    public init() {}

    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    public var diskUsed: Int64 { max(0, diskTotal - diskAvailable) }
    public var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
}

/// Samples machine-wide counters. CPU load is a delta between two reads, so keep one
/// sampler alive and call `sample()` on a timer.
public final class SystemSampler: @unchecked Sendable {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (counters: NetworkCounters, time: Date)?
    private var cachedBattery: (health: BatteryHealth?, time: Date)?
    private var cachedDisk: (total: Int64, available: Int64, time: Date)?
    private let thermal = ThermalSensors()
    private let lock = NSLock()

    public init() {}

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = cpuUsage()
        readMemory(into: &snapshot)
        readDisk(into: &snapshot)
        readBattery(into: &snapshot)
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.thermalState = ProcessInfo.processInfo.thermalState
        snapshot.memoryPressure = MemoryPressure.current() ?? snapshot.memoryFraction
        snapshot.cpuTemperature = thermal?.cpuTemperature()
        readNetwork(into: &snapshot)
        readBatteryHealth(into: &snapshot)
        return snapshot
    }

    private func readNetwork(into snapshot: inout SystemSnapshot) {
        let now = Date()
        let counters = NetworkCounters.current()
        lock.withLock {
            defer { previousNetwork = (counters, now) }
            guard let previous = previousNetwork else { return }
            let elapsed = now.timeIntervalSince(previous.time)
            // Counters restart when an interface is re-created; never report that as traffic.
            guard elapsed > 0.2, counters.received >= previous.counters.received,
                  counters.sent >= previous.counters.sent else { return }
            snapshot.networkIn = Double(counters.received - previous.counters.received) / elapsed
            snapshot.networkOut = Double(counters.sent - previous.counters.sent) / elapsed
        }
    }

    /// Cycle count and capacity move over weeks, so one registry read a minute is plenty.
    private func readBatteryHealth(into snapshot: inout SystemSnapshot) {
        let health: BatteryHealth? = lock.withLock {
            if let cached = cachedBattery, Date().timeIntervalSince(cached.time) < 60 { return cached.health }
            let fresh = BatteryHealth.current()
            cachedBattery = (fresh, Date())
            return fresh
        }
        snapshot.batteryCycles = health?.cycleCount
        snapshot.batteryHealth = health?.capacity
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        return lock.withLock {
            defer { previousTicks = (busy, total) }
            guard let previous = previousTicks, total > previous.total else { return 0 }
            return Double(busy - previous.busy) / Double(total - previous.total)
        }
    }

    private func readMemory(into snapshot: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        snapshot.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let wired = Int64(stats.wire_count)
        let compressed = Int64(stats.compressor_page_count)
        snapshot.memoryUsed = max(0, app + wired + compressed) * page
        snapshot.memoryCompressed = compressed * page
    }

    /// "Available for important usage" makes the system tally purgeable space, which is by far
    /// the costliest reading here, and free space does not move second to second.
    private func readDisk(into snapshot: inout SystemSnapshot) {
        let cached: (total: Int64, available: Int64)? = lock.withLock {
            guard let disk = cachedDisk, Date().timeIntervalSince(disk.time) < 20 else { return nil }
            return (disk.total, disk.available)
        }
        if let cached {
            snapshot.diskTotal = cached.total
            snapshot.diskAvailable = cached.available
            return
        }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        snapshot.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        snapshot.diskAvailable = values.volumeAvailableCapacityForImportantUsage ?? 0
        let (total, available) = (snapshot.diskTotal, snapshot.diskAvailable)
        lock.withLock { cachedDisk = (total, available, Date()) }
    }

    private func readBattery(into snapshot: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            snapshot.batteryLevel = Double(current) / Double(maximum)
            snapshot.batteryCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
        }
    }
}

public struct ProcessSample: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let executablePath: String
    /// Percent of one core, as `ps` reports it.
    public let cpu: Double
    public let memory: Int64

    /// The enclosing .app bundle, when the process belongs to one.
    public var appBundleURL: URL? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(executablePath[..<range.lowerBound]) + ".app")
    }
}

public enum ProcessList {
    public static func sample() -> [ProcessSample] {
        guard let output = Shell.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="]).output else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2]) else { return nil }
            let path = String(fields[3])
            return ProcessSample(pid: pid, name: (path as NSString).lastPathComponent,
                                 executablePath: path, cpu: cpu, memory: rssKB * 1024)
        }
    }
}
