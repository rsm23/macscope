import AppKit
import SwiftUI
import Testing
@testable import MacScope

@Suite("Menu bar readout")
struct MenuBarReadoutTests {
    @Test("Usage bars fit inside the macOS menu bar") @MainActor
    func usageBarsHaveCompactHeight() {
        let defaults = UserDefaults.standard
        let previousStyle = defaults.object(forKey: "menuBarReadoutStyle")
        let previousMetrics = defaults.object(forKey: "menuBarReadoutMetrics")
        defer {
            restore(previousStyle, forKey: "menuBarReadoutStyle", in: defaults)
            restore(previousMetrics, forKey: "menuBarReadoutMetrics", in: defaults)
        }
        defaults.set(MenuBarReadoutStyle.bars.rawValue, forKey: "menuBarReadoutStyle")
        defaults.set(MenuBarReadoutMetric.cpu.rawValue, forKey: "menuBarReadoutMetrics")

        let hostingView = NSHostingView(
            rootView: MenuBarStatusLabel(presentation: MenuBarPresentation())
        )

        #expect(hostingView.fittingSize.height <= 22)
        #expect(hostingView.fittingSize.width > 24)
    }

    @Test("Usage bars map utilization onto seven visual segments") @MainActor
    func usageBarsMapToVisualSegments() {
        #expect(MenuBarUsageGauge.segmentCount == 7)
        #expect(MenuBarUsageGauge.activeSegmentCount(for: 0) == 0)
        #expect(MenuBarUsageGauge.activeSegmentCount(for: 0.4) == 3)
        #expect(MenuBarUsageGauge.activeSegmentCount(for: 1) == 7)
    }

    @Test("Usage bars keep the numeric percentage visible") @MainActor
    func usageBarsKeepNumericPercentage() {
        #expect(MenuBarUsageGauge.displayText(label: "CPU", fraction: 0.4) == "CPU 40%")
    }

    @Test("Network readout fits a live colored graph in the menu bar") @MainActor
    func networkReadoutHasCompactGraph() {
        let defaults = UserDefaults.standard
        let previousStyle = defaults.object(forKey: "menuBarReadoutStyle")
        let previousMetrics = defaults.object(forKey: "menuBarReadoutMetrics")
        defer {
            restore(previousStyle, forKey: "menuBarReadoutStyle", in: defaults)
            restore(previousMetrics, forKey: "menuBarReadoutMetrics", in: defaults)
        }
        defaults.set(MenuBarReadoutStyle.bars.rawValue, forKey: "menuBarReadoutStyle")
        defaults.set(MenuBarReadoutMetric.network.rawValue, forKey: "menuBarReadoutMetrics")

        let hostingView = NSHostingView(
            rootView: MenuBarStatusLabel(presentation: MenuBarPresentation())
        )

        #expect(MenuBarNetworkGraph.width >= 40)
        #expect(hostingView.fittingSize.height <= 22)
        #expect(hostingView.fittingSize.width > MenuBarNetworkGraph.width)
    }

    @Test("Network graph scales traffic history while preserving its shape")
    func networkGraphNormalizesSamples() {
        let normalized = MenuBarNetworkGraph.normalizedSamples([0, 25, 100])
        #expect(normalized == [0, 0.5, 1])
        #expect(MenuBarNetworkGraph.normalizedSamples([-1, .infinity, .nan]) == [0, 0, 0])
        #expect(
            MenuBarNetworkGraph.normalizedSamples(Array(repeating: 1, count: 30)).count
                == MenuBarNetworkGraph.maximumSampleCount
        )
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
