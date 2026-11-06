import Foundation
import IOKit
import IOKit.ps
import Darwin

enum HealthStatus: String {
    case good = "Good", busy = "Busy", stressed = "Under stress"
}

struct Snapshot {
    var cpu: Double = 0            // 0...100
    var perCore: [Double] = []
    var memUsedGB = 0.0, memTotalGB = 0.0, memPressure = 0.0 // pressure 0...100
    var swapUsedGB = 0.0
    var diskFreeGB = 0.0, diskTotalGB = 0.0
    var batteryPct: Int? = nil, charging = false
    var thermal = ProcessInfo.ThermalState.nominal
    var plugged = false
    var justPlugged = false           // charger connected <45s ago; macOS refreshes its power reading only every ~15s
    var adapterWatts: Double? = nil   // rated output of the connected charger
    var powerInWatts: Double? = nil   // live power drawn from the charger
    var batteryHealth: Int? = nil     // maximum capacity vs. design capacity, in % (what System Settings calls Maximum Capacity)
    var systemLoadWatts: Double? = nil // live power the Mac itself is using
    var load: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0
    var netDown = 0.0, netUp = 0.0 // bytes/sec

    var status: HealthStatus {
        if cpu > 85 || memPressure > 85 || thermal == .serious || thermal == .critical { return .stressed }
        if cpu > 60 || memPressure > 65 || thermal == .fair { return .busy }
        return .good
    }
    var reason: String {
        var r: [String] = []
        if cpu > 60 { r.append("CPU \(Int(cpu))%") }
        if memPressure > 65 { r.append("Memory \(Int(memPressure))%" + (swapUsedGB > 1 ? String(format: " · %.1f GB swap", swapUsedGB) : "")) }
        if thermal != .nominal { r.append("thermals elevated") }
        return r.isEmpty ? "All systems normal" : r.joined(separator: " · ")
    }
}

final class StatsSampler {
    private var prevTicks: [[UInt32]] = []
    private var pluggedSince: Date?
    private var prevNet: (rx: UInt64, tx: UInt64, t: Date)?


    func sample() -> Snapshot {
        var s = Snapshot()
        (s.cpu, s.perCore) = cpu()
        mem(&s)
        disk(&s)
        battery(&s)
        power(&s)
        s.thermal = ProcessInfo.processInfo.thermalState
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        s.load = (l[0], l[1], l[2])
        s.uptime = ProcessInfo.processInfo.systemUptime
        network(&s)
        return s
    }

    private func cpu() -> (Double, [Double]) {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var ticks: [[UInt32]] = []
        for i in 0..<Int(n) {
            let b = i * Int(CPU_STATE_MAX)
            ticks.append([UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])])
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return (0, []) }
        var per: [Double] = []
        for (a, b) in zip(prevTicks, ticks) {
            let d = (0..<4).map { Double(b[$0] &- a[$0]) }
            let total = d.reduce(0, +)
            per.append(total > 0 ? (total - d[2]) / total * 100 : 0)
        }
        return (per.reduce(0, +) / Double(max(per.count, 1)), per)
    }

    private func mem(_ s: inout Snapshot) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // Same notion of "used" as Activity Monitor: app + wired + compressed
        let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        s.memTotalGB = total / 1_073_741_824
        s.memUsedGB = used / 1_073_741_824
        s.memPressure = min(100, used / total * 100)
        var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { s.swapUsedGB = Double(sw.xsu_used) / 1_073_741_824 }
    }

    private func disk(_ s: inout Snapshot) {
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFreeGB = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
            s.diskTotalGB = Double(v.volumeTotalCapacity ?? 0) / 1e9
        }
    }

    private func battery(_ s: inout Snapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
            s.batteryPct = cur * 100 / mx
            s.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        }
    }

    /// Live charger/system power from the AppleSmartBattery registry entry (what System Information shows, in real time).
    private func power(_ s: inout Snapshot) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        s.plugged = (d["ExternalConnected"] as? Bool) ?? false
        s.batteryHealth = Self.health(d)
        if s.plugged { if pluggedSince == nil { pluggedSince = Date() } } else { pluggedSince = nil }
        s.justPlugged = pluggedSince.map { Date().timeIntervalSince($0) < 45 } ?? false
        if let a = d["AdapterDetails"] as? [String: Any], let w = a["Watts"] as? Int, w > 0 { s.adapterWatts = Double(w) }
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            if let p = t["SystemPowerIn"] as? Int { s.powerInWatts = Double(p) / 1000 }
            if let l = t["SystemLoad"] as? Int { s.systemLoadWatts = Double(l) / 1000 }
        }
    }

    /// Battery health = full-charge capacity / design capacity from the AppleSmartBattery registry entry.
    /// Apple Silicon reports NominalChargeCapacity (inside BatteryData); older Macs report MaxCapacity in mAh.
    /// Integer division floors, which matches the figure System Settings shows.
    private static func health(_ d: [String: Any]) -> Int? {
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        let design = (bd["DesignCapacity"] as? Int) ?? (d["DesignCapacity"] as? Int) ?? 0
        guard design > 0 else { return nil }
        let full = (bd["NominalChargeCapacity"] as? Int) ?? (d["NominalChargeCapacity"] as? Int) ?? (d["AppleRawMaxCapacity"] as? Int) ?? 0
        if full > 0 { return min(100, full * 100 / design) }
        if let mx = d["MaxCapacity"] as? Int, mx > 100 { return min(100, mx * 100 / design) }
        return nil
    }

    private func network(_ s: inout Snapshot) {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return }
        defer { freeifaddrs(ifa) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard a.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = a.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(data.pointee.ifi_ibytes); tx += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        if let p = prevNet, now.timeIntervalSince(p.t) > 0, rx >= p.rx, tx >= p.tx {
            let dt = now.timeIntervalSince(p.t)
            s.netDown = Double(rx - p.rx) / dt; s.netUp = Double(tx - p.tx) / dt
        }
        prevNet = (rx, tx, now)
    }
}
