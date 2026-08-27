import Foundation

public actor StartupCollector: Collector {
    public let id = "startup"

    private let fileManager = FileManager.default

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [MetricDescriptor(id: "startup.items", name: "Startup Items", source: "launchd", scope: "system", unit: "items", kind: .information, provenance: "LaunchAgents and LaunchDaemons property lists")]
    }

    public func sample() async throws -> [StartupItem] {
        async let systemDisabledResult = CommandRunner.run(executable: "/bin/launchctl", arguments: ["print-disabled", "system"], timeout: 8)
        async let guiDisabledResult = CommandRunner.run(executable: "/bin/launchctl", arguments: ["print-disabled", "gui/\(getuid())"], timeout: 8)
        let (systemResult, guiResult) = await (systemDisabledResult, guiDisabledResult)
        let systemDisabled = disabledOverrides(systemResult.stdout)
        let guiDisabled = disabledOverrides(guiResult.stdout)
        let home = fileManager.homeDirectoryForCurrentUser
        let locations: [(URL, StartupDomain)] = [
            (home.appending(path: "Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .local),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .local),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), .system),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), .system)
        ]

        var items: [StartupItem] = []
        for (directory, domain) in locations {
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "plist" {
                let overrides = file.pathComponents.contains("LaunchAgents") ? guiDisabled : systemDisabled
                items.append(parse(file, domain: domain, disabledOverrides: overrides))
            }
        }
        return items.sorted {
            if $0.domain != $1.domain { return $0.domain.rawValue < $1.domain.rawValue }
            let labelOrder = $0.label.localizedStandardCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending
        }
    }

    private func parse(_ url: URL, domain: StartupDomain, disabledOverrides: [String: Bool]) -> StartupItem {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let plist = object as? [String: Any]
        else {
            return StartupItem(
                label: url.deletingPathExtension().lastPathComponent,
                domain: domain,
                sourcePath: url.path,
                program: nil,
                arguments: [],
                runAtLoad: false,
                keepAlive: false,
                isEnabled: nil,
                isLoaded: nil,
                availability: .restricted
            )
        }

        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let keepAlive: Bool
        if let boolean = plist["KeepAlive"] as? Bool {
            keepAlive = boolean
        } else {
            keepAlive = plist["KeepAlive"] != nil
        }
        return StartupItem(
            label: label,
            domain: domain,
            sourcePath: url.path,
            program: plist["Program"] as? String ?? arguments.first,
            arguments: arguments,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            isEnabled: !(disabledOverrides[label] ?? (plist["Disabled"] as? Bool ?? false)),
            isLoaded: nil,
            availability: .degraded
        )
    }

    private func disabledOverrides(_ output: String) -> [String: Bool] {
        var values: [String: Bool] = [:]
        let pattern = #"\"([^\"]+)\"\s*=>\s*(true|false)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return values }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in expression.matches(in: output, range: range) where match.numberOfRanges == 3 {
            guard let labelRange = Range(match.range(at: 1), in: output),
                  let valueRange = Range(match.range(at: 2), in: output) else { continue }
            values[String(output[labelRange])] = output[valueRange] == "true"
        }
        return values
    }
}
