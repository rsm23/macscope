import Foundation
import Darwin
import MacScopeCore
import MacScopeMCPBridge
import MCP

private enum MacScopeMCPServerConstants {
    static let name = "MacScope"
    static let version = "1.0.0"
    static let protocolVersion = "2025-11-25"
    static let instructions = """
        MacScope exposes local macOS telemetry and an allowlisted macOS feature catalog. Read tools redact sensitive fields unless the server was explicitly launched with sensitive reads enabled. Feature changes are disabled by default and always require a separate preflight followed by an exact, expiring confirmation. Never claim unavailable telemetry is zero, and inspect availability/detail fields before drawing conclusions.
        """
}

private struct ServerOptions: Sendable {
    var allowSensitiveReads = false
    var allowFeatureWrites = false
    var allowExperimentalFeatureWrites = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--allow-sensitive-read":
                allowSensitiveReads = true
            case "--allow-feature-writes":
                allowFeatureWrites = true
            case "--allow-experimental-feature-writes":
                allowFeatureWrites = true
                allowExperimentalFeatureWrites = true
            case "--help", "-h":
                print(Self.help)
                exit(EXIT_SUCCESS)
            case "--version", "-v":
                print(MacScopeMCPServerConstants.version)
                exit(EXIT_SUCCESS)
            case let value:
                throw ServerOptionError.unknownArgument(value)
            }
            index += 1
        }
    }

    static let help = """
        MacScopeMCPServer \(MacScopeMCPServerConstants.version)

        Usage: MacScopeMCPServer [options]

          --allow-sensitive-read                 Permit include_sensitive=true.
          --allow-feature-writes                 Permit preflighted catalog feature changes.
          --allow-experimental-feature-writes    Also permit experimental catalog entries.
          --version                              Print the server version.
          --help                                 Show this help.

        With no options the server is read-only and redacts sensitive fields.
        MCP communication uses newline-delimited JSON-RPC over stdin/stdout.
        """
}

private enum ServerOptionError: LocalizedError {
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let value): "Unknown argument: \(value). Use --help for supported options."
        }
    }
}

@main
private enum MacScopeMCPServerMain {
    static func main() async {
        var connectionRegistry: MCPConnectionRegistry?
        var heartbeatTask: Task<Void, Never>?
        do {
            let options = try ServerOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let registry = try MCPConnectionRegistry()
            connectionRegistry = registry
            let policy = MCPConnectionPolicy(
                sensitiveReads: options.allowSensitiveReads,
                featureWrites: options.allowFeatureWrites,
                experimentalFeatureWrites: options.allowExperimentalFeatureWrites
            )
            let gateway = MacScopeMCPGateway(
                snapshotSource: LiveMacScopeMCPSnapshotSource(),
                featureAccess: MacOSFeatureManager(),
                configuration: .init(
                    allowSensitiveReads: options.allowSensitiveReads,
                    allowFeatureWrites: options.allowFeatureWrites,
                    allowExperimentalFeatureWrites: options.allowExperimentalFeatureWrites
                )
            )
            let server = Server(
                name: MacScopeMCPServerConstants.name,
                version: MacScopeMCPServerConstants.version,
                title: "MacScope System Monitor",
                instructions: MacScopeMCPServerConstants.instructions,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: false)
                )
            )

            await registerHandlers(server: server, gateway: gateway, connectionRegistry: registry)
            try await server.start(
                transport: StdioTransport(),
                initializeHook: { clientInfo, _ in
                    try await registry.beginSession(
                        clientName: clientInfo.name,
                        clientTitle: clientInfo.title,
                        clientVersion: clientInfo.version,
                        serverVersion: MacScopeMCPServerConstants.version,
                        protocolVersion: MacScopeMCPServerConstants.protocolVersion,
                        policy: policy
                    )
                }
            )
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    try? await registry.heartbeat()
                }
            }
            await server.waitUntilCompleted()
            heartbeatTask?.cancel()
            try? await registry.endSession()
        } catch {
            heartbeatTask?.cancel()
            if let connectionRegistry { try? await connectionRegistry.endSession() }
            FileHandle.standardError.write(Data("MacScope MCP server failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func registerHandlers(
        server: Server,
        gateway: MacScopeMCPGateway,
        connectionRegistry: MCPConnectionRegistry
    ) async {
        await server.withMethodHandler(ListTools.self) { _ in
            try? await connectionRegistry.recordActivity()
            return .init(tools: ToolCatalog.tools)
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            try? await connectionRegistry.recordActivity()
            do {
                let document = try await callTool(
                    name: parameters.name,
                    arguments: parameters.arguments ?? [:],
                    gateway: gateway
                )
                return try result(document)
            } catch {
                return errorResult(error)
            }
        }

        await server.withMethodHandler(ListResources.self) { _ in
            try? await connectionRegistry.recordActivity()
            return .init(resources: ResourceCatalog.resources)
        }

        await server.withMethodHandler(ReadResource.self) { parameters in
            try? await connectionRegistry.recordActivity()
            let document: MacScopeMCPJSONValue
            switch parameters.uri {
            case ResourceCatalog.serverInfoURI:
                document = try await gateway.serverInformation()
            case ResourceCatalog.summaryURI:
                document = try await gateway.snapshot(.init(sections: [.summary]))
            case ResourceCatalog.snapshotURI:
                document = try await gateway.snapshot(.init(sections: [.all]))
            case ResourceCatalog.hardwareURI:
                document = try await gateway.snapshot(.init(sections: [.hardware]))
            case ResourceCatalog.featuresURI:
                document = try await gateway.listFeatures()
            default:
                throw MCPError.invalidParams("Unknown MacScope resource URI: \(parameters.uri)")
            }
            return .init(contents: [
                .text(try document.jsonString(), uri: parameters.uri, mimeType: "application/json")
            ])
        }
    }

    private static func callTool(
        name: String,
        arguments: [String: Value],
        gateway: MacScopeMCPGateway
    ) async throws -> MacScopeMCPJSONValue {
        switch name {
        case ToolCatalog.serverInfo:
            return try await gateway.serverInformation()

        case ToolCatalog.snapshot:
            return try await gateway.snapshot(try snapshotQuery(arguments))

        case ToolCatalog.history:
            return try await gateway.history(
                query: snapshotQuery(arguments),
                limit: arguments.integer("limit", default: 30)
            )

        case ToolCatalog.listFeatures:
            return try await gateway.listFeatures(try featureQuery(arguments))

        case ToolCatalog.getFeature:
            return try await gateway.feature(id: arguments.requiredString("id"))

        case ToolCatalog.prepareFeatureChange:
            return try await gateway.prepareFeatureChange(
                id: arguments.requiredString("id"),
                enabled: arguments.requiredBool("enabled")
            )

        case ToolCatalog.applyFeatureChange:
            return try await gateway.applyFeatureChange(
                approvalToken: arguments.requiredString("approval_token"),
                confirmation: arguments.requiredString("confirmation")
            )

        case ToolCatalog.undoFeatureChange:
            return try await gateway.undoFeatureChange(
                undoToken: arguments.requiredString("undo_token"),
                confirmation: arguments.requiredString("confirmation")
            )

        default:
            throw MCPError.methodNotFound("Unknown MacScope tool: \(name)")
        }
    }

    private static func snapshotQuery(_ arguments: [String: Value]) throws -> MacScopeMCPSnapshotQuery {
        let sectionNames = arguments.stringArray("sections") ?? [MacScopeMCPSnapshotSection.summary.rawValue]
        let sections = try sectionNames.map { name in
            guard let value = MacScopeMCPSnapshotSection(rawValue: name) else {
                throw MCPError.invalidParams("Unknown snapshot section '\(name)'.")
            }
            return value
        }
        return MacScopeMCPSnapshotQuery(
            sections: sections,
            includeSensitive: arguments.bool("include_sensitive", default: false),
            processLimit: arguments.integer("process_limit", default: 250),
            processQuery: arguments.optionalString("process_query")
        )
    }

    private static func featureQuery(_ arguments: [String: Value]) throws -> MacScopeMCPFeatureQuery {
        let category = try arguments.optionalEnum("category", values: MacOSFeatureCategory.allCases)
        let tier = try arguments.optionalEnum("tier", values: MacOSFeatureTier.allCases)
        let state = try arguments.optionalEnum("state", values: MacOSFeatureEffectiveState.allCases)
        let availability = try arguments.optionalEnum("availability", values: DataAvailability.allCases)
        return MacScopeMCPFeatureQuery(
            query: arguments.optionalString("query"),
            category: category,
            tier: tier,
            state: state,
            availability: availability,
            limit: arguments.integer("limit", default: 500)
        )
    }

    private static func result(_ document: MacScopeMCPJSONValue) throws -> CallTool.Result {
        let json = try document.jsonString()
        return try .init(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: try Value(document),
            isError: false
        )
    }

    private static func errorResult(_ error: Error) -> CallTool.Result {
        let message = error.localizedDescription
        let document = MacScopeMCPJSONValue.object([
            "error": .string(message),
            "errorType": .string(String(describing: type(of: error)))
        ])
        return .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: try? Value(document),
            isError: true
        )
    }
}

private enum ToolCatalog {
    static let serverInfo = "macscope_get_server_info"
    static let snapshot = "macscope_get_system_snapshot"
    static let history = "macscope_get_metric_history"
    static let listFeatures = "macscope_list_macos_features"
    static let getFeature = "macscope_get_macos_feature"
    static let prepareFeatureChange = "macscope_prepare_macos_feature_change"
    static let applyFeatureChange = "macscope_apply_macos_feature_change"
    static let undoFeatureChange = "macscope_undo_macos_feature_change"

    static let tools: [Tool] = [
        Tool(
            name: serverInfo,
            title: "Get MacScope MCP server information",
            description: "Returns server capabilities and whether sensitive reads or feature writes were enabled at startup.",
            inputSchema: Schema.emptyObject,
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: snapshot,
            title: "Get current Mac telemetry",
            description: "Returns current MacScope telemetry for selected sections. Use sections=['all'] for every snapshot field. Sensitive fields are redacted by default.",
            inputSchema: Schema.snapshot(includeHistoryLimit: false),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: history,
            title: "Get recent metric history",
            description: "Returns recent snapshots collected during this MCP server process, newest last, with the same section and redaction controls as the current snapshot tool.",
            inputSchema: Schema.snapshot(includeHistoryLimit: true),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: listFeatures,
            title: "List macOS feature states",
            description: "Lists MacScope's allowlisted macOS feature catalog with current effective state, support status, tier, exact typed mechanism, and provenance.",
            inputSchema: Schema.featureList,
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: getFeature,
            title: "Get one macOS feature state",
            description: "Returns the current state and complete catalog metadata for one exact MacScope feature identifier.",
            inputSchema: Schema.object(
                properties: ["id": Schema.string("Exact feature identifier returned by macscope_list_macos_features.")],
                required: ["id"]
            ),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: prepareFeatureChange,
            title: "Preflight a macOS feature change",
            description: "Read-only preflight. Verifies the allowlisted feature, current state, typed preference, tier, restart effect, and server policy; returns an expiring approval token and exact confirmation.",
            inputSchema: Schema.object(
                properties: [
                    "id": Schema.string("Exact feature identifier."),
                    "enabled": .object(["type": .string("boolean"), "description": .string("Requested effective state.")])
                ],
                required: ["id", "enabled"]
            ),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: applyFeatureChange,
            title: "Apply a preflighted macOS feature change",
            description: "Consumes one unexpired preflight token, rechecks that state did not change, requires the exact confirmation, writes only the catalog's typed allowlisted preference, verifies it, and returns a time-limited undo token.",
            inputSchema: Schema.object(
                properties: [
                    "approval_token": Schema.string("Token returned by macscope_prepare_macos_feature_change."),
                    "confirmation": Schema.string("Exact confirmation returned by the preflight tool.")
                ],
                required: ["approval_token", "confirmation"]
            ),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: undoFeatureChange,
            title: "Undo a macOS feature change",
            description: "Consumes the undo token returned by a successful feature change and restores the exact prior stored preference value.",
            inputSchema: Schema.object(
                properties: [
                    "undo_token": Schema.string("Token returned by macscope_apply_macos_feature_change."),
                    "confirmation": Schema.string("Exact undo confirmation returned by the apply tool.")
                ],
                required: ["undo_token", "confirmation"]
            ),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        )
    ]
}

private enum ResourceCatalog {
    static let serverInfoURI = "macscope://server/info"
    static let summaryURI = "macscope://telemetry/summary"
    static let snapshotURI = "macscope://telemetry/snapshot"
    static let hardwareURI = "macscope://hardware/inventory"
    static let featuresURI = "macscope://macos/features"

    static let resources: [Resource] = [
        Resource(name: "server-info", uri: serverInfoURI, title: "MacScope MCP server information", description: "Active read/write policy and supported snapshot sections.", mimeType: "application/json"),
        Resource(name: "telemetry-summary", uri: summaryURI, title: "Current Mac telemetry summary", description: "A compact, redacted summary of current CPU, memory, battery, disk, network, thermal, and availability data.", mimeType: "application/json"),
        Resource(name: "telemetry-snapshot", uri: snapshotURI, title: "Current complete MacScope snapshot", description: "Every snapshot field, with sensitive values redacted and process results bounded.", mimeType: "application/json"),
        Resource(name: "hardware-inventory", uri: hardwareURI, title: "Mac hardware inventory", description: "Current redacted hardware and operating-system inventory.", mimeType: "application/json"),
        Resource(name: "macos-features", uri: featuresURI, title: "macOS feature catalog and state", description: "Complete allowlisted feature catalog with current states and provenance.", mimeType: "application/json")
    ]
}

private enum Schema {
    static let emptyObject: Value = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false)
    ])

    static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(Value.string)) }
        return .object(schema)
    }

    static func enumeration<T: RawRepresentable>(_ values: [T], description: String) -> Value where T.RawValue == String {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0.rawValue) }),
            "description": .string(description)
        ])
    }

    static func snapshot(includeHistoryLimit: Bool) -> Value {
        var properties: [String: Value] = [
            "sections": .object([
                "type": .string("array"),
                "items": enumeration(MacScopeMCPSnapshotSection.allCases, description: "Snapshot section."),
                "description": .string("Sections to return. Use ['all'] for the complete snapshot."),
                "default": .array([.string("summary")])
            ]),
            "include_sensitive": .object([
                "type": .string("boolean"),
                "default": .bool(false),
                "description": .string("Request sensitive identifiers and paths. Rejected unless enabled at server startup.")
            ]),
            "process_limit": .object([
                "type": .string("integer"),
                "minimum": .int(0),
                "maximum": .int(5_000),
                "default": .int(250),
                "description": .string("Maximum process rows returned.")
            ]),
            "process_query": string("Optional case-insensitive process name, path, or PID filter.")
        ]
        if includeHistoryLimit {
            properties["limit"] = .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(300),
                "default": .int(30),
                "description": .string("Maximum recent samples, newest last.")
            ])
        }
        return object(properties: properties)
    }

    static let featureList = object(properties: [
        "query": string("Optional search across identifier, title, summary, category, provenance, and detail."),
        "category": enumeration(MacOSFeatureCategory.allCases, description: "Exact feature category."),
        "tier": enumeration(MacOSFeatureTier.allCases, description: "Safety/complexity tier."),
        "state": enumeration(MacOSFeatureEffectiveState.allCases, description: "Current effective state."),
        "availability": enumeration(DataAvailability.allCases, description: "Current support/readability state."),
        "limit": .object([
            "type": .string("integer"),
            "minimum": .int(1),
            "maximum": .int(1_000),
            "default": .int(500)
        ])
    ])
}

private extension Dictionary where Key == String, Value == MCP.Value {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw MCPError.invalidParams("Missing or invalid string parameter: \(key).")
        }
        return value
    }

    func optionalString(_ key: String) -> String? { self[key]?.stringValue }

    func requiredBool(_ key: String) throws -> Bool {
        guard let value = self[key]?.boolValue else {
            throw MCPError.invalidParams("Missing or invalid Boolean parameter: \(key).")
        }
        return value
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        self[key]?.boolValue ?? defaultValue
    }

    func integer(_ key: String, default defaultValue: Int) -> Int {
        self[key]?.intValue ?? defaultValue
    }

    func stringArray(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap(\.stringValue)
    }

    func optionalEnum<T>(_ key: String, values: [T]) throws -> T? where T: RawRepresentable, T.RawValue == String {
        guard let raw = optionalString(key) else { return nil }
        guard let value = values.first(where: { $0.rawValue == raw }) else {
            throw MCPError.invalidParams("Invalid \(key) value '\(raw)'.")
        }
        return value
    }
}
