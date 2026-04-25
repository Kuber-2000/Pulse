import Foundation
import IOKit

// Standalone tool: list every IOHID temperature sensor with name + °C.

let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!

typealias Create_t       = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias SetMatching_t  = @convention(c) (AnyObject, CFDictionary) -> Int32
typealias CopyServices_t = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
typealias CopyEvent_t    = @convention(c) (AnyObject, Int32, Int32, Int64) -> Unmanaged<AnyObject>?
typealias GetFloat_t     = @convention(c) (AnyObject, Int32) -> Double
typealias CopyProperty_t = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?

let create      = unsafeBitCast(dlsym(lib, "IOHIDEventSystemClientCreate")!, to: Create_t.self)
let setMatching = unsafeBitCast(dlsym(lib, "IOHIDEventSystemClientSetMatching")!, to: SetMatching_t.self)
let copyServices = unsafeBitCast(dlsym(lib, "IOHIDEventSystemClientCopyServices")!, to: CopyServices_t.self)
let copyEvent   = unsafeBitCast(dlsym(lib, "IOHIDServiceClientCopyEvent")!, to: CopyEvent_t.self)
let getFloat    = unsafeBitCast(dlsym(lib, "IOHIDEventGetFloatValue")!, to: GetFloat_t.self)
let copyProp    = unsafeBitCast(dlsym(lib, "IOHIDServiceClientCopyProperty")!, to: CopyProperty_t.self)

guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
    print("Failed to create IOHID client"); exit(1)
}

let matching: [String: Any] = [
    "PrimaryUsagePage": 0xff00,
    "PrimaryUsage":     0x0005
]
_ = setMatching(client, matching as CFDictionary)

guard let cfArray: CFArray = copyServices(client)?.takeRetainedValue() else {
    print("No thermal services"); exit(1)
}
let services = (cfArray as NSArray) as? [AnyObject] ?? []
print("Found \(services.count) thermal sensor services\n")

let kIOHIDEventTypeTemperature: Int32 = 15
let field: Int32 = kIOHIDEventTypeTemperature << 16

struct Reading { let name: String; let temp: Double }
var readings: [Reading] = []

for svc in services {
    var name = "(unnamed)"
    if let p = copyProp(svc, "Product" as CFString)?.takeRetainedValue(), let s = p as? String {
        name = s
    }
    guard let event = copyEvent(svc, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else {
        readings.append(Reading(name: name, temp: -999))
        continue
    }
    let t = getFloat(event, field)
    readings.append(Reading(name: name, temp: t))
}

readings.sort { $0.temp > $1.temp }
print(String(format: "%-40@ %8@", "SENSOR" as NSString, "°C" as NSString))
print(String(repeating: "─", count: 50))
for r in readings {
    let tStr = r.temp == -999 ? "  n/a" : String(format: "%6.2f", r.temp)
    print(String(format: "%-40@ %8@", r.name as NSString, tStr as NSString))
}

print("\n--- Summary ---")
let valid = readings.filter { $0.temp > 0 && $0.temp < 200 }
if !valid.isEmpty {
    let max = valid.map(\.temp).max()!
    let mean = valid.map(\.temp).reduce(0, +) / Double(valid.count)
    print(String(format: "Max:    %.2f °C", max))
    print(String(format: "Mean:   %.2f °C  (over %d sensors)", mean, valid.count))
}

let cpuPattern = ["CPU", "pACC", "eACC", "PMU", "SOC", "TC0", "TCXC"]
let cpuOnly = valid.filter { r in cpuPattern.contains(where: { r.name.uppercased().contains($0.uppercased()) }) }
if !cpuOnly.isEmpty {
    let cmax = cpuOnly.map(\.temp).max()!
    let cmean = cpuOnly.map(\.temp).reduce(0, +) / Double(cpuOnly.count)
    print(String(format: "CPU max:  %.2f °C", cmax))
    print(String(format: "CPU mean: %.2f °C  (over %d sensors)", cmean, cpuOnly.count))
}
