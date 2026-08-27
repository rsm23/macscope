import Darwin
import Foundation

/// Reads the same Apple-silicon PMU temperature services exposed through IOKit's HID event system.
/// These symbols are undocumented, so capability discovery is performed at runtime and failures are
/// reported as unavailable instead of manufacturing sensor values.
public actor ThermalSensorCollector: Collector {
    public let id = "thermal-sensors"

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [MetricDescriptor(id: "thermal.hid", name: "PMU Temperature Sensors", source: "IOHIDEventSystem", scope: "sensor", unit: "°C", provenance: "AppleARMPMUTempSensor HID events", availability: .unmapped)]
    }

    public func sample() async throws -> [String: Double] {
        guard let api = HIDThermalAPI() else {
            throw CollectorError.unavailable("The IOKit thermal event interface is unavailable on this macOS version.")
        }
        return api.readTemperatures()
    }
}

private final class HIDThermalAPI: @unchecked Sendable {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private let handle: UnsafeMutableRawPointer
    private let createClient: CreateClient
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let services = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let property = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let event = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatValue = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }
        self.handle = handle
        createClient = unsafeBitCast(create, to: CreateClient.self)
        copyServices = unsafeBitCast(services, to: CopyServices.self)
        copyProperty = unsafeBitCast(property, to: CopyProperty.self)
        copyEvent = unsafeBitCast(event, to: CopyEvent.self)
        getFloatValue = unsafeBitCast(floatValue, to: GetFloatValue.self)
    }

    deinit { dlclose(handle) }

    func readTemperatures() -> [String: Double] {
        guard let client = createClient(kCFAllocatorDefault)?.takeRetainedValue(),
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [:] }
        var result: [String: Double] = [:]
        var duplicateCounts: [String: Int] = [:]
        for serviceObject in services {
            let service = unsafeBitCast(serviceObject, to: CFTypeRef.self)
            guard let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  product.hasPrefix("PMU t"),
                  let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloatValue(event, Int32(15 << 16))
            guard value.isFinite, value > -20, value < 160 else { continue }
            let baseName = product.replacingOccurrences(of: "PMU ", with: "")
            let count = duplicateCounts[baseName, default: 0]
            duplicateCounts[baseName] = count + 1
            result[count == 0 ? baseName : "\(baseName) #\(count + 1)"] = value
        }
        return result
    }
}
