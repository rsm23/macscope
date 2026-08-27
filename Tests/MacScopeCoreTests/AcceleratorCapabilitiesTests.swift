import Testing
@testable import MacScopeCore

@Suite("Accelerator telemetry capabilities")
struct AcceleratorCapabilitiesTests {
    @Test("Missing counters hide both accelerator families")
    func missingCounters() {
        let capabilities = DeepTelemetrySnapshot().acceleratorCapabilities

        #expect(!capabilities.gpuTelemetryAvailable)
        #expect(!capabilities.aneTelemetryAvailable)
    }

    @Test("A zero counter is still an available reading")
    func zeroCountersAreAvailable() {
        var deep = DeepTelemetrySnapshot()
        deep.gpuUsage = 0
        deep.aneUsage = 0

        #expect(deep.acceleratorCapabilities.gpuTelemetryAvailable)
        #expect(deep.acceleratorCapabilities.aneTelemetryAvailable)
    }

    @Test("Non-finite counters do not expose unavailable telemetry")
    func nonFiniteCounters() {
        var deep = DeepTelemetrySnapshot()
        deep.gpuUsage = .nan
        deep.gpuPowerWatts = .infinity
        deep.aneFrequencyMHz = -.infinity

        #expect(!deep.acceleratorCapabilities.gpuTelemetryAvailable)
        #expect(!deep.acceleratorCapabilities.aneTelemetryAvailable)
    }

    @Test("Auxiliary counters do not expose an unreadable accelerator page")
    func auxiliaryCountersAreInsufficient() {
        var deep = DeepTelemetrySnapshot()
        deep.gpuFrequencyMHz = 1_296
        deep.gpuPowerWatts = 8
        deep.aneFrequencyMHz = 780
        deep.anePowerWatts = 1.5

        #expect(!deep.acceleratorCapabilities.gpuTelemetryAvailable)
        #expect(!deep.acceleratorCapabilities.aneTelemetryAvailable)
    }

    @Test("GPU and ANE availability are independent")
    func independentCapabilities() {
        var deep = DeepTelemetrySnapshot()
        deep.gpuUsage = 42

        #expect(deep.acceleratorCapabilities.gpuTelemetryAvailable)
        #expect(!deep.acceleratorCapabilities.aneTelemetryAvailable)
    }
}
