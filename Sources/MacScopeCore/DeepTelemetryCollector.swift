import Foundation

public actor DeepTelemetryCollector: Collector {
    public let id = "deep-telemetry"
    private let client = PrivilegedTelemetryClient()

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "gpu.usage", name: "GPU Usage", source: "powermetrics", scope: "system", unit: "%", provenance: "privileged plist stream", availability: .restricted),
            MetricDescriptor(id: "ane.usage", name: "ANE Activity", source: "powermetrics", scope: "system", unit: "%", provenance: "privileged plist stream", availability: .restricted),
            MetricDescriptor(id: "thermal.sensors", name: "Thermal Sensors", source: "AppleSMC", scope: "sensor", unit: "°C", provenance: "model-specific SMC keys", availability: .restricted)
        ]
    }

    public func sample() async throws -> DeepTelemetrySnapshot {
        await client.sample()
    }
}

private final class PrivilegedTelemetryClient: @unchecked Sendable {
    func sample() async -> DeepTelemetrySnapshot {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: privilegedMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedTelemetryXPC.self)
            let reply = DeepTelemetryReply(continuation: continuation, connection: connection)
            connection.invalidationHandler = {
                reply.finish(.restricted(detail: "The privileged helper is not connected. Install or approve it in Settings."))
            }
            connection.interruptionHandler = {
                reply.finish(.restricted(detail: "The privileged helper was interrupted and will be retried automatically."))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.finish(.restricted(detail: "The privileged helper could not be reached: \(error.localizedDescription)"))
            }) as? PrivilegedTelemetryXPC else {
                reply.finish(.restricted(detail: "The privileged helper XPC interface is unavailable."))
                return
            }
            let proxyBox = PrivilegedTelemetryProxyBox(proxy)

            proxyBox.value.handshake { protocolVersion, status in
                guard PrivilegedTelemetryCompatibility.supports(protocolVersion) else {
                    var snapshot = DeepTelemetrySnapshot(
                        availability: .degraded,
                        detail: "The privileged helper uses unsupported telemetry protocol version \(protocolVersion). \(status)"
                    )
                    snapshot.helperConnected = true
                    reply.finish(snapshot)
                    return
                }

                Self.requestSample(
                    from: proxyBox.value,
                    protocolVersion: protocolVersion,
                    reply: reply
                )
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                reply.finish(.restricted(detail: "The privileged helper did not respond within 10 seconds."))
            }
        }
    }

    private static func requestSample(
        from proxy: PrivilegedTelemetryXPC,
        protocolVersion: Int,
        reply: DeepTelemetryReply
    ) {
        proxy.sampleDeepTelemetry { data, errorMessage in
            guard let data else {
                var snapshot = DeepTelemetrySnapshot(availability: .degraded, detail: errorMessage ?? "The helper returned no telemetry.")
                snapshot.helperConnected = true
                reply.finish(snapshot)
                return
            }
            do {
                var snapshot = try JSONDecoder().decode(DeepTelemetrySnapshot.self, from: data)
                snapshot = PrivilegedTelemetryCompatibility.normalizePowerUnits(
                    in: snapshot,
                    fromProtocolVersion: protocolVersion
                )
                snapshot.helperConnected = true
                reply.finish(snapshot)
            } catch {
                var snapshot = DeepTelemetrySnapshot(availability: .degraded, detail: "The helper response could not be decoded: \(error.localizedDescription)")
                snapshot.helperConnected = true
                reply.finish(snapshot)
            }
        }
    }
}

private final class PrivilegedTelemetryProxyBox: @unchecked Sendable {
    let value: PrivilegedTelemetryXPC

    init(_ value: PrivilegedTelemetryXPC) {
        self.value = value
    }
}

/// Compatibility rules for telemetry already emitted by installed helper versions.
///
/// Protocol version 1 encoded raw powermetrics milliwatt counters in properties
/// whose model names end in `PowerWatts`. Version 2 and later encode watts.
/// Keeping this conversion at the XPC boundary prevents current parser output
/// from being normalized a second time.
public enum PrivilegedTelemetryProtocolVersion {
    public static let current = 2
}

enum PrivilegedTelemetryCompatibility {
    private static let legacyMilliwattProtocolVersion = 1

    static func supports(_ protocolVersion: Int) -> Bool {
        (legacyMilliwattProtocolVersion...PrivilegedTelemetryProtocolVersion.current).contains(protocolVersion)
    }

    static func normalizePowerUnits(
        in snapshot: DeepTelemetrySnapshot,
        fromProtocolVersion protocolVersion: Int
    ) -> DeepTelemetrySnapshot {
        guard protocolVersion == legacyMilliwattProtocolVersion else { return snapshot }

        var normalized = snapshot
        normalized.cpuPowerWatts = watts(fromLegacyMilliwatts: snapshot.cpuPowerWatts)
        normalized.gpuPowerWatts = watts(fromLegacyMilliwatts: snapshot.gpuPowerWatts)
        normalized.anePowerWatts = watts(fromLegacyMilliwatts: snapshot.anePowerWatts)
        return normalized
    }

    private static func watts(fromLegacyMilliwatts value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value / 1_000
    }
}

private final class DeepTelemetryReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<DeepTelemetrySnapshot, Never>
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<DeepTelemetrySnapshot, Never>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ value: DeepTelemetrySnapshot) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        continuation.resume(returning: value)
    }
}

private extension DeepTelemetrySnapshot {
    static func restricted(detail: String) -> Self {
        .init(availability: .restricted, detail: detail)
    }
}
