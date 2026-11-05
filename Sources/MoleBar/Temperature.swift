import Foundation

// Private IOKit HID calls used to read the SoC temperature sensors without sudo (Apple Silicon).
@_silgen_name("IOHIDEventSystemClientCreate") private func hidCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func hidSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func hidServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func hidEvent(_ s: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func hidFloat(_ e: AnyObject, _ field: Int32) -> Double
@_silgen_name("IOHIDServiceClientCopyProperty") private func hidProperty(_ s: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

/// Real system temperature: the average of the CPU die sensors ("PMU tdie*"), in °C.
/// Returns nil when the sensors are unavailable (e.g. Intel Macs).
final class SystemTemperature {
    private let client: AnyObject?
    private var dieServices: [AnyObject] = []

    init() {
        client = hidCreate(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client else { return }
        _ = hidSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (hidServices(client)?.takeRetainedValue() as [AnyObject]?) ?? []
        dieServices = all.filter {
            ((hidProperty($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? "").contains("tdie")
        }
    }

    func read() -> Double? {
        let temps = dieServices.compactMap { s -> Double? in
            guard let e = hidEvent(s, 15, 0, 0)?.takeRetainedValue() else { return nil }
            let v = hidFloat(e, 15 << 16)
            return v > 0 && v < 130 ? v : nil
        }
        return temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
    }
}
