import Foundation
import IOKit
import Darwin

// MARK: - CPU load (public Mach API)

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info_data_t()
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let res = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    guard res == KERN_SUCCESS else { return nil }
    return CPUTicks(
        user:   UInt64(info.cpu_ticks.0),
        system: UInt64(info.cpu_ticks.1),
        idle:   UInt64(info.cpu_ticks.2),
        nice:   UInt64(info.cpu_ticks.3)
    )
}

func cpuLoadPercent(prev: CPUTicks, curr: CPUTicks) -> Double {
    // 32-bit wrap-aware deltas
    let dUser = (curr.user &- prev.user) & 0xffffffff
    let dSys  = (curr.system &- prev.system) & 0xffffffff
    let dNice = (curr.nice &- prev.nice) & 0xffffffff
    let dIdle = (curr.idle &- prev.idle) & 0xffffffff
    let active = dUser + dSys + dNice
    let total  = active + dIdle
    if total == 0 { return 0 }
    return Double(active) / Double(total) * 100.0
}

// MARK: - CPU temperature via IOHID (private framework symbols)
// Same technique used by Stats / iStat Menus / TG Pro. Read-only, no sudo.
// Returns nil on machines where the sensors don't match.

final class ThermalReader {
    private typealias Create_t        = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching_t   = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices_t  = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent_t     = @convention(c) (AnyObject, Int32, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat_t      = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty_t  = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?

    private static let kHIDPage_AppleVendor: Int32 = 0xff00
    private static let kHIDUsage_AppleVendor_TemperatureSensor: Int32 = 0x0005
    private static let kIOHIDEventTypeTemperature: Int32 = 15
    private static var temperatureField: Int32 { kIOHIDEventTypeTemperature << 16 }

    private var client: AnyObject?
    private var fnCopyServices: CopyServices_t?
    private var fnCopyEvent: CopyEvent_t?
    private var fnGetFloat: GetFloat_t?
    private var fnCopyProperty: CopyProperty_t?

    init?() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        guard let pCreate       = dlsym(lib, "IOHIDEventSystemClientCreate"),
              let pSetMatching  = dlsym(lib, "IOHIDEventSystemClientSetMatching"),
              let pCopyServices = dlsym(lib, "IOHIDEventSystemClientCopyServices"),
              let pCopyEvent    = dlsym(lib, "IOHIDServiceClientCopyEvent"),
              let pGetFloat     = dlsym(lib, "IOHIDEventGetFloatValue"),
              let pCopyProperty = dlsym(lib, "IOHIDServiceClientCopyProperty")
        else { return nil }

        let create      = unsafeBitCast(pCreate,       to: Create_t.self)
        let setMatching = unsafeBitCast(pSetMatching,  to: SetMatching_t.self)
        fnCopyServices  = unsafeBitCast(pCopyServices, to: CopyServices_t.self)
        fnCopyEvent     = unsafeBitCast(pCopyEvent,    to: CopyEvent_t.self)
        fnGetFloat      = unsafeBitCast(pGetFloat,     to: GetFloat_t.self)
        fnCopyProperty  = unsafeBitCast(pCopyProperty, to: CopyProperty_t.self)

        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = c

        let matching: [String: Any] = [
            "PrimaryUsagePage": Self.kHIDPage_AppleVendor,
            "PrimaryUsage":     Self.kHIDUsage_AppleVendor_TemperatureSensor
        ]
        _ = setMatching(c, matching as CFDictionary)
    }

    /// Average °C of CPU-related sensors. Falls back to mean of all matched sensors
    /// if nothing pattern-matches. Returns nil if no sensors at all.
    func readCPUTemperature() -> Double? {
        guard let client = client,
              let cfArray: CFArray = fnCopyServices?(client)?.takeRetainedValue()
        else { return nil }
        let services = (cfArray as NSArray) as? [AnyObject] ?? []

        var cpuValues: [Double] = []
        var allValues: [Double] = []

        for svc in services {
            guard let event = fnCopyEvent?(svc, Self.kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let temp = fnGetFloat?(event, Self.temperatureField) ?? 0
            guard temp > 0, temp < 200 else { continue }
            allValues.append(temp)

            var name = ""
            if let propRef = fnCopyProperty?(svc, "Product" as CFString)?.takeRetainedValue(),
               let s = propRef as? String {
                name = s
            }
            // Apple Silicon (M-series): "PMU tdie*" / "PMU2 tdie*" — die-temperature sensors.
            // Older Apple Silicon: "pACC MTR Temp Sensor*", "eACC MTR Temp Sensor*".
            // Intel: "TC0P", "TC0E", "TC0F", "TCXC".
            let up = name.uppercased()
            if up.contains("TDIE")
                || up.contains("CPU")
                || up.contains("PACC")
                || up.contains("EACC")
                || up.hasPrefix("TC0")
                || up.contains("TCXC") {
                cpuValues.append(temp)
            }
        }

        let pool = cpuValues.isEmpty ? allValues : cpuValues
        guard !pool.isEmpty else { return nil }
        // Report hot-spot (max), not mean — hot spot drives throttling & fan activation.
        return pool.max()
    }
}

// MARK: - Fan RPMs via SMC (System Management Controller)
// SMC keys: FNum (UInt8 fan count), F<i>Ac (actual RPM, "flt " or "fpe2").
// Returns empty array on fanless Macs or when AppleSMC service can't be opened.

final class SMC {
    private var conn: io_connect_t = 0
    private var connected = false

    private static let KERNEL_INDEX_SMC: UInt32 = 2
    private static let SMC_CMD_READ_BYTES: UInt8 = 5
    private static let SMC_CMD_READ_KEYINFO: UInt8 = 9

    // Layout matches Apple's SMCParamStruct (80 bytes total).
    // Padding fields are explicit so Swift's struct layout matches the C ABI.
    private struct SMCParamStruct {
        var key: UInt32 = 0                   // [0..4]
        var vMajor: UInt8 = 0                 // [4]
        var vMinor: UInt8 = 0                 // [5]
        var vBuild: UInt8 = 0                 // [6]
        var vReserved: UInt8 = 0              // [7]
        var vRelease: UInt16 = 0              // [8..10]
        var pad1: UInt16 = 0                  // [10..12] align next struct to 4
        var pVersion: UInt16 = 0              // [12..14]
        var pLength: UInt16 = 0               // [14..16]
        var pCpu: UInt32 = 0                  // [16..20]
        var pGpu: UInt32 = 0                  // [20..24]
        var pMem: UInt32 = 0                  // [24..28]
        var dataSize: UInt32 = 0              // [28..32]
        var dataType: UInt32 = 0              // [32..36]
        var dataAttributes: UInt8 = 0         // [36]
        var pad2a: UInt8 = 0                  // [37]
        var pad2b: UInt8 = 0                  // [38]
        var pad2c: UInt8 = 0                  // [39]
        var result: UInt8 = 0                 // [40]
        var status: UInt8 = 0                 // [41]
        var data8: UInt8 = 0                  // [42]
        // Swift inserts 1 byte padding for UInt32 alignment → data32 at [44]
        var data32: UInt32 = 0                // [44..48]
        // 32 bytes of payload data at [48..80]
        var b00: UInt8 = 0; var b01: UInt8 = 0; var b02: UInt8 = 0; var b03: UInt8 = 0
        var b04: UInt8 = 0; var b05: UInt8 = 0; var b06: UInt8 = 0; var b07: UInt8 = 0
        var b08: UInt8 = 0; var b09: UInt8 = 0; var b10: UInt8 = 0; var b11: UInt8 = 0
        var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
        var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0
        var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
        var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0
        var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0
    }

    init?() {
        // Verify struct layout matches the 80-byte ABI; bail gracefully if it doesn't.
        guard MemoryLayout<SMCParamStruct>.size == 80 else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == KERN_SUCCESS else { return nil }
        connected = true
    }

    deinit {
        if connected { IOServiceClose(conn) }
    }

    private static func encodeKey(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let kr = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(
                    conn,
                    Self.KERNEL_INDEX_SMC,
                    inPtr,
                    MemoryLayout<SMCParamStruct>.size,
                    outPtr,
                    &outputSize
                )
            }
        }
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    /// Read raw bytes for a 4-char key. Returns (data type fourCC, payload bytes).
    func readKey(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        // Step 1: get key info (data size + type fourCC).
        var step1 = SMCParamStruct()
        step1.key = Self.encodeKey(key)
        step1.data8 = Self.SMC_CMD_READ_KEYINFO
        guard let info = call(step1) else { return nil }
        let size = Int(info.dataSize)
        let type = info.dataType
        guard size > 0, size <= 32 else { return nil }

        // Step 2: read bytes.
        var step2 = SMCParamStruct()
        step2.key = Self.encodeKey(key)
        step2.data8 = Self.SMC_CMD_READ_BYTES
        step2.dataSize = UInt32(size)
        guard var out = call(step2) else { return nil }

        let bytes: [UInt8] = withUnsafeBytes(of: &out) { rawBuf in
            let dataOffset = 48
            return Array(rawBuf[dataOffset..<dataOffset + size])
        }
        return (type, bytes)
    }

    private func readUInt8(_ key: String) -> UInt8? {
        guard let r = readKey(key), !r.bytes.isEmpty else { return nil }
        return r.bytes[0]
    }

    /// Decode a fan RPM value. Handles "flt " (LE float) and "fpe2" (BE 14.2 fixed-point).
    private func decodeFanRPM(type: UInt32, bytes: [UInt8]) -> Double? {
        let fltType: UInt32  = 0x666c7420  // "flt "
        let fpe2Type: UInt32 = 0x66706532  // "fpe2"
        if type == fltType, bytes.count >= 4 {
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            let v = Double(Float(bitPattern: bits))
            return v.isFinite ? v : nil
        } else if type == fpe2Type, bytes.count >= 2 {
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        }
        return nil
    }

    /// Returns RPMs of all detected fans. Empty on fanless Macs.
    func readAllFanRPMs() -> [Double] {
        guard let count = readUInt8("FNum"), count > 0 else { return [] }
        var rpms: [Double] = []
        for i in 0..<Int(count) {
            let key = "F\(i)Ac"
            if let r = readKey(key), let rpm = decodeFanRPM(type: r.type, bytes: r.bytes) {
                rpms.append(rpm)
            }
        }
        return rpms
    }

    struct FanInfo {
        let rpm: Double
        let minRPM: Double
        let maxRPM: Double
        /// 0–100. Reflects how saturated the fan is between its min and max RPM.
        var percent: Double {
            if maxRPM <= 0 { return 0 }
            if maxRPM > minRPM {
                let pct = (rpm - minRPM) / (maxRPM - minRPM) * 100
                return max(0, min(100, pct))
            }
            return max(0, min(100, rpm / maxRPM * 100))
        }
    }

    /// Returns (rpm, min, max) for each fan. Empty on fanless Macs.
    func readAllFans() -> [FanInfo] {
        guard let count = readUInt8("FNum"), count > 0 else { return [] }
        var fans: [FanInfo] = []
        for i in 0..<Int(count) {
            let rpm = readKey("F\(i)Ac").flatMap { decodeFanRPM(type: $0.type, bytes: $0.bytes) } ?? 0
            let mn  = readKey("F\(i)Mn").flatMap { decodeFanRPM(type: $0.type, bytes: $0.bytes) } ?? 0
            let mx  = readKey("F\(i)Mx").flatMap { decodeFanRPM(type: $0.type, bytes: $0.bytes) } ?? 0
            fans.append(FanInfo(rpm: rpm, minRPM: mn, maxRPM: mx))
        }
        return fans
    }
}

// MARK: - Memory usage (public Mach API)

struct MemoryInfo {
    let usedBytes: UInt64
    let compressedBytes: UInt64
    let totalBytes: UInt64
    var usedPercent: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100 }
}

func readMemory() -> MemoryInfo? {
    var stats = vm_statistics64_data_t()
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let res = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    guard res == KERN_SUCCESS else { return nil }

    var totalBytes: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &totalBytes, &len, nil, 0)

    let pageSize = UInt64(vm_kernel_page_size)
    // "Used" the way Activity Monitor counts it: app (internal − purgeable) + wired + compressed
    let appBytes        = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) &* pageSize
    let wiredBytes      = UInt64(stats.wire_count) &* pageSize
    let compressedBytes = UInt64(stats.compressor_page_count) &* pageSize
    return MemoryInfo(
        usedBytes: appBytes &+ wiredBytes &+ compressedBytes,
        compressedBytes: compressedBytes,
        totalBytes: totalBytes
    )
}

// MARK: - Disk I/O byte counters (IOKit IOBlockStorageDriver statistics)
// Iterating the IO registry isn't free, so callers should only sample while visible.

func readDiskBytes() -> (read: UInt64, write: UInt64)? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(0, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iter) }

    var totalRead: UInt64 = 0
    var totalWrite: UInt64 = 0
    var found = false
    while case let drive = IOIteratorNext(iter), drive != 0 {
        defer { IOObjectRelease(drive) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(drive, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any],
              let stats = props["Statistics"] as? [String: Any] else { continue }
        if let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value  { totalRead &+= r; found = true }
        if let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { totalWrite &+= w; found = true }
    }
    return found ? (totalRead, totalWrite) : nil
}
