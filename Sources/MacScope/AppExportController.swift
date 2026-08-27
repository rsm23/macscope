import AppKit
import MacScopeCore
import UniformTypeIdentifiers

@MainActor
enum AppExportController {
    static func exportInventory(_ inventory: HardwareInventory, redact: Bool) {
        do {
            let data = try TelemetryExporter.inventoryJSON(inventory, redactSensitive: redact)
            save(data, suggestedName: "MacScope-inventory.json", allowedType: "json")
        } catch {
            present(error)
        }
    }

    static func exportMetrics(_ snapshots: [SystemSnapshot]) {
        save(TelemetryExporter.metricsCSV(snapshots), suggestedName: "MacScope-metrics.csv", allowedType: "csv")
    }

    private static func save(_ data: Data, suggestedName: String, allowedType: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: allowedType) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            present(error)
        }
    }

    private static func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
