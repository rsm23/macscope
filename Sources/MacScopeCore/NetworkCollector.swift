import Darwin
import Foundation

public actor NetworkCollector: Collector {
    public let id = "network"

    private struct Counters: Sendable {
        let bytesIn: UInt64
        let bytesOut: UInt64
        let packetsIn: UInt64
        let packetsOut: UInt64
        let errorsIn: UInt64
        let errorsOut: UInt64
        let sampledAt: ContinuousClock.Instant
    }

    private struct Accumulator {
        var addresses: Set<String> = []
        var flags: UInt32 = 0
        var counters = Counters(bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0, errorsIn: 0, errorsOut: 0, sampledAt: .now)
    }

    private var previous: [String: Counters] = [:]
    private let clock = ContinuousClock()

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "network.download", name: "Download", source: "BSD", scope: "interface", unit: "bytes/s", provenance: "getifaddrs"),
            MetricDescriptor(id: "network.upload", name: "Upload", source: "BSD", scope: "interface", unit: "bytes/s", provenance: "getifaddrs")
        ]
    }

    public func sample() async throws -> [NetworkInterfaceSnapshot] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            throw CollectorError.unavailable("getifaddrs failed")
        }
        defer { freeifaddrs(first) }

        let now = clock.now
        var values: [String: Accumulator] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor?.pointee {
            let name = String(cString: item.ifa_name)
            var accumulator = values[name] ?? Accumulator()
            accumulator.flags = item.ifa_flags

            if let address = item.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                if family == AF_INET || family == AF_INET6, let formatted = formatAddress(address) {
                    accumulator.addresses.insert(formatted)
                }
                if family == AF_LINK, let data = item.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    accumulator.counters = Counters(
                        bytesIn: UInt64(data.ifi_ibytes),
                        bytesOut: UInt64(data.ifi_obytes),
                        packetsIn: UInt64(data.ifi_ipackets),
                        packetsOut: UInt64(data.ifi_opackets),
                        errorsIn: UInt64(data.ifi_ierrors),
                        errorsOut: UInt64(data.ifi_oerrors),
                        sampledAt: now
                    )
                }
            }
            values[name] = accumulator
            cursor = item.ifa_next
        }

        let snapshots = values.map { name, value -> NetworkInterfaceSnapshot in
            let counters = value.counters
            let old = previous[name]
            let elapsed = old.map { durationSeconds($0.sampledAt.duration(to: now)) } ?? 0
            let download = elapsed > 0 ? Double(delta(counters.bytesIn, old?.bytesIn ?? counters.bytesIn)) / elapsed : 0
            let upload = elapsed > 0 ? Double(delta(counters.bytesOut, old?.bytesOut ?? counters.bytesOut)) / elapsed : 0
            return NetworkInterfaceSnapshot(
                name: name,
                displayName: interfaceDisplayName(name),
                addresses: value.addresses.sorted(),
                isUp: (value.flags & UInt32(IFF_UP)) != 0,
                bytesIn: counters.bytesIn,
                bytesOut: counters.bytesOut,
                packetsIn: counters.packetsIn,
                packetsOut: counters.packetsOut,
                errorsIn: counters.errorsIn,
                errorsOut: counters.errorsOut,
                downloadRate: download,
                uploadRate: upload
            )
        }.sorted { left, right in
            if left.isUp != right.isUp { return left.isUp }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        previous = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value.counters) })
        return snapshots
    }

    private func formatAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        let result = getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return result == 0 ? decodedCString(host) : nil
    }

    private func delta(_ current: UInt64, _ old: UInt64) -> UInt64 {
        current >= old ? current - old : current
    }

    private func interfaceDisplayName(_ name: String) -> String {
        switch name {
        case "en0": "Primary network"
        case "lo0": "Loopback"
        case let value where value.hasPrefix("utun"): "VPN tunnel"
        case let value where value.hasPrefix("bridge"): "Network bridge"
        case let value where value.hasPrefix("awdl"): "Apple Wireless Direct Link"
        default: name
        }
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
