public struct AcceleratorCapabilities: Equatable, Sendable {
    public let gpuTelemetryAvailable: Bool
    public let aneTelemetryAvailable: Bool

    public init(gpuTelemetryAvailable: Bool, aneTelemetryAvailable: Bool) {
        self.gpuTelemetryAvailable = gpuTelemetryAvailable
        self.aneTelemetryAvailable = aneTelemetryAvailable
    }
}

public extension DeepTelemetrySnapshot {
    /// Accelerator UI is exposed only after a genuine utilization counter has
    /// been observed. Auxiliary frequency or power estimates are not enough to
    /// make an otherwise unreadable accelerator page useful. Zero is a valid
    /// utilization reading and must not be mistaken for missing telemetry.
    var acceleratorCapabilities: AcceleratorCapabilities {
        AcceleratorCapabilities(
            gpuTelemetryAvailable: gpuUsage?.isFinite == true,
            aneTelemetryAvailable: aneUsage?.isFinite == true
        )
    }
}

public extension SystemSnapshot {
    var acceleratorCapabilities: AcceleratorCapabilities {
        deep.acceleratorCapabilities
    }
}
