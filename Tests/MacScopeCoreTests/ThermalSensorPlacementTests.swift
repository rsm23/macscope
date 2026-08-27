import Testing
@testable import MacScopeCore

@Suite("Thermal sensor placement")
struct ThermalSensorPlacementTests {
    @Test("Processor die names and TC/TG families map to the processor")
    func processorMappings() {
        assertPlacement("tDie", region: .processor, confidence: .exactName)
        assertPlacement("PMU tDie #2", region: .processor, confidence: .exactName)
        assertPlacement("TC0P", region: .processor, confidence: .knownFamily)
        assertPlacement("tg1d", region: .processor, confidence: .knownFamily)
    }

    @Test("Memory and storage names use only their explicit families")
    func memoryAndStorageMappings() {
        assertPlacement("Tm0P", region: .memory, confidence: .knownFamily)
        assertPlacement("DRAM temperature", region: .memory, confidence: .exactName)
        assertPlacement("Ts0P", region: .storage, confidence: .knownFamily)
        assertPlacement("SSD temperature", region: .storage, confidence: .exactName)
        assertPlacement("NVMe (2)", region: .storage, confidence: .exactName)
    }

    @Test("Battery and power delivery remain distinct")
    func batteryAndPowerMappings() {
        assertPlacement("TB0T", region: .battery, confidence: .knownFamily)
        assertPlacement("Battery Temperature", region: .battery, confidence: .exactName)
        assertPlacement("PMU die", region: .powerDelivery, confidence: .exactName)
        assertPlacement("PMU DIE #2", region: .powerDelivery, confidence: .exactName)
        assertPlacement("Charger", region: .powerDelivery, confidence: .exactName)
        assertPlacement("USB-C Power", region: .powerDelivery, confidence: .exactName)
        assertPlacement("PMIC temperature", region: .powerDelivery, confidence: .exactName)
    }

    @Test("Wireless and display names map only when the component is identifiable")
    func peripheralMappings() {
        assertPlacement("TW0P", region: .wirelessIO, confidence: .knownFamily)
        assertPlacement("Wi-Fi temperature", region: .wirelessIO, confidence: .exactName)
        assertPlacement("Bluetooth", region: .wirelessIO, confidence: .exactName)
        assertPlacement("TL0P", region: .display, confidence: .knownFamily)
        assertPlacement("Display panel", region: .display, confidence: .exactName)
    }

    @Test("Generic device and proximity keys never claim exact component placement")
    func ambiguousMappings() {
        let device = ThermalSensorPlacement.classify(key: "tDev1")
        #expect(device.region == .enclosure)
        #expect(device.confidence == .contextual)
        #expect(device.basis.contains("exact component is not published"))

        let proximity = ThermalSensorPlacement.classify(key: "TP0P #3")
        #expect(proximity.region == .enclosure)
        #expect(proximity.confidence == .contextual)
        #expect(proximity.basis.contains("proximity"))

        assertPlacement("Ambient", region: .enclosure, confidence: .contextual)
    }

    @Test("Calibration and unknown keys remain unmapped")
    func unknownMappings() {
        let calibration = ThermalSensorPlacement.classify(key: "tCal0")
        #expect(calibration.region == .unknown)
        #expect(calibration.confidence == .unknown)
        #expect(calibration.basis.contains("Calibration"))

        assertPlacement("TN0D", region: .unknown, confidence: .unknown)
        assertPlacement("mystery sensor", region: .unknown, confidence: .unknown)
        assertPlacement("", region: .unknown, confidence: .unknown)
    }

    @Test("Classification is case-insensitive, strips duplicate suffixes, and retains the source key")
    func normalization() {
        let original = "  tc0p (2)  "
        let placement = ThermalSensorPlacement.classify(key: original)
        #expect(placement.key == original)
        #expect(placement.region == .processor)
        #expect(placement.confidence == .knownFamily)

        assertPlacement("BATTERY TEMPERATURE #12", region: .battery, confidence: .exactName)
        assertPlacement("tM0p #2", region: .memory, confidence: .knownFamily)
    }

    @Test("Every region has stable identity and a display title")
    func regionIdentity() {
        #expect(ThermalHardwareRegion.allCases.count == 9)
        for region in ThermalHardwareRegion.allCases {
            #expect(region.id == region.rawValue)
            #expect(!region.title.isEmpty)
        }
    }

    private func assertPlacement(
        _ key: String,
        region: ThermalHardwareRegion,
        confidence: ThermalPlacementConfidence
    ) {
        let placement = ThermalSensorPlacement.classify(key: key)
        #expect(placement.key == key)
        #expect(placement.region == region)
        #expect(placement.confidence == confidence)
        #expect(!placement.basis.isEmpty)
    }
}
