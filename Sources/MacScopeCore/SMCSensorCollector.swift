import Foundation
import IOKit

public struct SMCSensorReadings: Sendable {
    public var temperatures: [String: Double] = [:]
    public var fanSpeeds: [String: Double] = [:]
    public init() {}
}

public actor SMCSensorCollector: Collector {
    public let id = "apple-smc"
    private var client: SMCClient?
    private var temperatureKeys: [SMCKeyDescriptor] = []
    private var fanKeys: [SMCKeyDescriptor] = []
    private var discovered = false

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "smc.temperature", name: "SMC Temperatures", source: "AppleSMC", scope: "sensor", unit: "°C", provenance: "runtime-discovered SMC keys", availability: .unmapped),
            MetricDescriptor(id: "smc.fan", name: "Fan Speed", source: "AppleSMC", scope: "fan", unit: "RPM", provenance: "runtime-discovered F*Ac SMC keys", availability: .unmapped)
        ]
    }

    public func sample() async throws -> SMCSensorReadings {
        if client == nil { client = SMCClient() }
        guard let client else { throw CollectorError.unavailable("AppleSMC could not be opened on this Mac.") }
        if !discovered {
            let keys = client.discoverKeys()
            temperatureKeys = keys.filter { $0.name.hasPrefix("T") && SMCDecoder.isTemperatureType($0.type) }
            let discoveredFans = keys.filter { key in
                key.name.count == 4 && key.name.first == "F" && key.name.hasSuffix("Ac")
            }
            // Some AppleSMC implementations do not expose a usable #KEY index even though
            // direct reads work. Always probe the well-known current-speed keys and merge
            // them with enumeration results instead of making fan telemetry depend on #KEY.
            fanKeys = SMCKeyCatalog.merging(
                discoveredFans,
                with: client.descriptors(named: SMCKeyCatalog.fanSpeedKeys)
            )
            // A completely empty result is treated as a transient failure and retried on the
            // next sampling lane. Fanless Macs still discover temperature keys and settle here.
            discovered = !temperatureKeys.isEmpty || !fanKeys.isEmpty
        }
        var readings = SMCSensorReadings()
        for key in temperatureKeys {
            guard let value = client.read(key), value > -20, value < 160 else { continue }
            readings.temperatures[key.name] = value
        }
        for key in fanKeys {
            guard let value = client.read(key), value >= 0, value < 30_000 else { continue }
            readings.fanSpeeds[key.name] = value
        }
        return readings
    }
}

struct SMCKeyDescriptor: Sendable {
    let code: UInt32
    let name: String
    let type: String
    let size: UInt32
}

private final class SMCClient: @unchecked Sendable {
    private var connection: io_connect_t = 0

    init?() {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == IO_OBJECT_NULL {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
        }
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func discoverKeys() -> [SMCKeyDescriptor] {
        guard let countDescriptor = keyInfo(code: fourCC("#KEY")),
              let countBytes = readBytes(countDescriptor), countBytes.count >= 4 else { return knownSensorKeys() }
        let count = countBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count < 50_000 else { return knownSensorKeys() }
        var result: [SMCKeyDescriptor] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            var input = SMCParamStruct()
            var output = SMCParamStruct()
            input.data8 = 8
            input.data32 = index
            guard call(input: &input, output: &output) == KERN_SUCCESS,
                  output.result == 0,
                  let descriptor = keyInfo(code: output.key) else { continue }
            result.append(descriptor)
        }
        return result
    }

    func descriptors(named names: [String]) -> [SMCKeyDescriptor] {
        names.compactMap { keyInfo(code: fourCC($0)) }
    }

    private func knownSensorKeys() -> [SMCKeyDescriptor] {
        descriptors(named: SMCKeyCatalog.fallbackSensorKeys)
    }

    func read(_ descriptor: SMCKeyDescriptor) -> Double? {
        guard let bytes = readBytes(descriptor) else { return nil }
        return SMCDecoder.decode(bytes, type: descriptor.type)
    }

    private func keyInfo(code: UInt32) -> SMCKeyDescriptor? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = code
        input.data8 = 9
        let result = call(input: &input, output: &output)
        guard result == KERN_SUCCESS,
              output.result == 0,
              (1...32).contains(output.keyInfo.dataSize) else { return nil }
        return SMCKeyDescriptor(code: code, name: fourCCString(code), type: fourCCString(output.keyInfo.dataType), size: output.keyInfo.dataSize)
    }

    private func readBytes(_ descriptor: SMCKeyDescriptor) -> [UInt8]? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = descriptor.code
        input.keyInfo.dataSize = descriptor.size
        input.data8 = 5
        let result = call(input: &input, output: &output)
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(descriptor.size, 32)))) }
    }

    private func call(input: inout SMCParamStruct, output: inout SMCParamStruct) -> kern_return_t {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize)
    }
}

enum SMCKeyCatalog {
    // SMC identifiers are exactly four bytes. The current fan index therefore occupies
    // one character; probing 0...9 covers every representable F*Ac key without inventing
    // invalid five-character identifiers such as "F10Ac".
    static let fanSpeedKeys = (0...9).map { "F\($0)Ac" }

    static let fallbackSensorKeys = fanSpeedKeys + [
        "TC0P", "TC0D", "TC0E", "TC0F", "TG0P", "TG0D", "Tm0P", "TB0T",
        "Tp0P", "Ts0P", "TW0P", "TN0D"
    ]

    static func merging(
        _ first: [SMCKeyDescriptor],
        with second: [SMCKeyDescriptor]
    ) -> [SMCKeyDescriptor] {
        var result: [String: SMCKeyDescriptor] = [:]
        for descriptor in first + second {
            result[descriptor.name] = descriptor
        }
        return result.values.sorted { $0.name < $1.name }
    }
}

enum SMCDecoder {
    static func isTemperatureType(_ type: String) -> Bool {
        ["sp78", "flt ", "fp88", "ui16", "si16"].contains(type)
    }

    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // Apple-silicon AppleSMC stores its IEEE-754 `flt ` payload least-significant
            // byte first. Fixed-point and integer SMC types above remain big-endian.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default: return nil
        }
    }
}

private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPowerLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Match the three bytes of C tail padding in SMCKeyInfo. Swift normally packs the
    // following UInt8 fields into that space, producing a 76-byte request instead of the
    // 80-byte AppleSMC ABI structure; AppleSMC rejects that request as unsupported.
    var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}
private struct SMCParamStruct {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCABI {
    static var requestSize: Int { MemoryLayout<SMCParamStruct>.stride }
}

private func fourCC(_ value: String) -> UInt32 {
    value.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func fourCCString(_ value: UInt32) -> String {
    String(bytes: [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? "????"
}
