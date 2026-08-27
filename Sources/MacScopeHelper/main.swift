import Foundation
import Darwin
import MacScopeCore
import Security

final class HelperService: NSObject, MacScopePrivilegedXPC, @unchecked Sendable {
    private let smc = SMCSensorCollector()
    private let hidThermals = ThermalSensorCollector()

    func handshake(reply: @escaping @Sendable (Int, String) -> Void) {
        reply(PrivilegedTelemetryProtocolVersion.current, "Ready")
    }

    func sampleDeepTelemetry(reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            let result = await CommandRunner.run(
                executable: "/usr/bin/powermetrics",
                arguments: ["-n", "1", "-i", "1000", "--format", "plist", "--samplers", "cpu_power,gpu_power,ane_power,thermal"],
                timeout: 8
            )
            do {
                var snapshot: DeepTelemetrySnapshot
                if result.exitCode == 0 {
                    do {
                        snapshot = try PowermetricsParser.parseStream(Data(result.stdout.utf8))
                    } catch {
                        snapshot = DeepTelemetrySnapshot(
                            availability: .degraded,
                            detail: "powermetrics could not be parsed: \(error.localizedDescription)"
                        )
                    }
                } else {
                    let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    snapshot = DeepTelemetrySnapshot(
                        availability: .degraded,
                        detail: message.isEmpty ? "powermetrics failed; independent sensor sources were still sampled." : "powermetrics failed: \(message)"
                    )
                }

                // SMC and HID sensors are independent of powermetrics. Always sample them so a
                // missing/changed powermetrics sampler cannot erase valid fan and temperature data.
                if let smcReadings = try? await smc.sample() {
                    snapshot.sensors.merge(smcReadings.temperatures) { _, value in value }
                    snapshot.fanSpeeds = smcReadings.fanSpeeds
                }
                if let hid = try? await hidThermals.sample() {
                    snapshot.sensors.merge(hid) { _, existing in existing }
                }
                reply(try JSONEncoder().encode(snapshot), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func preflight(actionData: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let envelope = try JSONDecoder().decode(PrivilegedActionEnvelope.self, from: actionData)
            let value: ActionPreflight
            switch envelope {
            case .process(let request): value = try ProcessController.preflight(request)
            case .launchd(let request): value = launchdPreflight(request)
            }
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func execute(actionData: Data, confirmation: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            do {
                let envelope = try JSONDecoder().decode(PrivilegedActionEnvelope.self, from: actionData)
                let preflight: ActionPreflight
                switch envelope {
                case .process(let request): preflight = try ProcessController.preflight(request)
                case .launchd(let request): preflight = launchdPreflight(request)
                }
                guard confirmation == preflight.confirmationPhrase else {
                    throw CollectorError.permissionDenied("The confirmation phrase does not match the live preflight")
                }
                let result: ActionResult
                switch envelope {
                case .process(let request): result = try await ProcessController.execute(request)
                case .launchd(let request): result = try await executeLaunchd(request)
                }
                reply(try JSONEncoder().encode(result), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func launchdPreflight(_ request: LaunchActionRequest) -> ActionPreflight {
        let domain = launchDomain(request)
        let phrase = "\(request.kind.rawValue) \(domain)/\(request.label)"
        return ActionPreflight(
            target: "\(domain)/\(request.label)",
            operation: request.kind.rawValue,
            expectedEffect: "Run launchctl \(request.kind.rawValue) without deleting or rewriting its property list",
            confirmationPhrase: phrase,
            reversible: request.kind != .kickstart
        )
    }

    private func executeLaunchd(_ request: LaunchActionRequest) async throws -> ActionResult {
        let domain = launchDomain(request)
        var arguments = [request.kind.rawValue]
        switch request.kind {
        case .bootstrap:
            guard let path = request.propertyListPath, path.hasPrefix("/") else { throw CollectorError.malformed("Bootstrap requires an absolute property-list path") }
            arguments += [domain, path]
        case .bootout:
            arguments += [domain + "/" + request.label]
        case .enable, .disable, .kickstart:
            arguments += [domain + "/" + request.label]
        }
        let result = await CommandRunner.run(executable: "/bin/launchctl", arguments: arguments, timeout: 10)
        guard result.exitCode == 0 else { throw CollectorError.permissionDenied(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return ActionResult(succeeded: true, message: result.stdout.isEmpty ? "launchctl completed" : result.stdout, timestamp: .now)
    }

    private func launchDomain(_ request: LaunchActionRequest) -> String {
        switch request.domain {
        case .system: "system"
        case .user: "user/\(request.userID ?? getuid())"
        case .gui: "gui/\(request.userID ?? getuid())"
        }
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientVerifier.isAllowed(pid: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: MacScopePrivilegedXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

enum ClientVerifier {
    private struct SigningIdentity {
        let identifier: String
        let teamIdentifier: String?
        let executableURL: URL
    }

    private static let mainAppIdentifiers: Set<String> = [
        "local.taskmanager.MacScope",
        "MacScope"
    ]
    private static let mcpServerIdentifier = "local.taskmanager.MacScope.MCPServer"

    static func isAllowed(pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        guard SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else { return false }

        guard let client = signingIdentity(for: staticCode),
              let contentsURL = macScopeContentsURL(),
              allowedCodePaths(for: client.identifier, contentsURL: contentsURL).contains(client.executableURL) else { return false }

        // A Developer ID build must have the same Team ID as the helper. Ad-hoc local builds
        // have no Team ID and remain constrained to exact executables inside this app bundle.
        if let helperTeam = currentTeamIdentifier() {
            guard client.teamIdentifier == helperTeam else { return false }
        } else {
            guard client.teamIdentifier == nil else { return false }
        }
        return true
    }

    private static func allowedCodePaths(for identifier: String, contentsURL: URL) -> Set<URL> {
        let paths: [URL]
        if mainAppIdentifiers.contains(identifier) {
            // SecCode may identify a bundled process by either its bundle root or main executable.
            paths = [
                contentsURL.deletingLastPathComponent(),
                contentsURL.appendingPathComponent("MacOS/MacScope")
            ]
        } else if identifier == mcpServerIdentifier {
            paths = [contentsURL.appendingPathComponent("Resources/MacScopeMCPServer")]
        } else {
            return []
        }
        return Set(paths.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
    }

    private static func signingIdentity(for code: SecStaticCode) -> SigningIdentity? {
        var information: CFDictionary?
        var path: CFURL?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              SecCodeCopyPath(code, [], &path) == errSecSuccess,
              let executableURL = path as URL?,
              let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return SigningIdentity(
            identifier: identifier,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            executableURL: executableURL.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func macScopeContentsURL() -> URL? {
        var requiredSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &requiredSize)
        var buffer = [CChar](repeating: 0, count: Int(requiredSize))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &requiredSize)
        }
        guard result == 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let helperURL = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let contentsURL = helperURL.deletingLastPathComponent().deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents",
              contentsURL.deletingLastPathComponent().pathExtension == "app" else { return nil }
        return contentsURL
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: privilegedMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
