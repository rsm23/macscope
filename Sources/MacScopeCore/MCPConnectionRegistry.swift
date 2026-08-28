import Darwin
import Foundation

public struct MCPConnectionPolicy: Codable, Hashable, Sendable {
    public let sensitiveReads: Bool
    public let featureWrites: Bool
    public let experimentalFeatureWrites: Bool
    public let utilityWrites: Bool
    public let artifactReads: Bool

    public init(
        sensitiveReads: Bool,
        featureWrites: Bool,
        experimentalFeatureWrites: Bool,
        utilityWrites: Bool = false,
        artifactReads: Bool = false
    ) {
        self.sensitiveReads = sensitiveReads
        self.featureWrites = featureWrites
        self.experimentalFeatureWrites = experimentalFeatureWrites
        self.utilityWrites = utilityWrites
        self.artifactReads = artifactReads
    }

    private enum CodingKeys: String, CodingKey {
        case sensitiveReads, featureWrites, experimentalFeatureWrites, utilityWrites, artifactReads
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sensitiveReads = try values.decode(Bool.self, forKey: .sensitiveReads)
        featureWrites = try values.decode(Bool.self, forKey: .featureWrites)
        experimentalFeatureWrites = try values.decode(Bool.self, forKey: .experimentalFeatureWrites)
        utilityWrites = try values.decodeIfPresent(Bool.self, forKey: .utilityWrites) ?? false
        artifactReads = try values.decodeIfPresent(Bool.self, forKey: .artifactReads) ?? false
    }
}

public struct MCPClientSession: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let clientName: String
    public let clientTitle: String?
    public let clientVersion: String
    public let serverPID: Int32
    public let serverVersion: String
    public let protocolVersion: String
    public let policy: MCPConnectionPolicy
    public let connectedAt: Date
    public var lastActivityAt: Date
    public var lastSeenAt: Date

    public var displayName: String {
        guard let clientTitle, !clientTitle.isEmpty else { return clientName }
        return clientTitle
    }
}

/// Coordinates live MCP server processes through one private, atomic session file per process.
/// A heartbeat makes crashed or force-quit clients disappear without relying on a clean shutdown.
public actor MCPConnectionRegistry {
    public static let defaultStaleInterval: TimeInterval = 8

    private let directoryURL: URL
    private let staleInterval: TimeInterval
    private var ownedSession: MCPClientSession?

    public init(
        directoryURL: URL? = nil,
        staleInterval: TimeInterval = defaultStaleInterval
    ) throws {
        self.directoryURL = try directoryURL ?? Self.defaultDirectoryURL()
        self.staleInterval = max(staleInterval, 0.05)
        try Self.prepareDirectory(self.directoryURL)
    }

    public func beginSession(
        clientName: String,
        clientTitle: String?,
        clientVersion: String,
        serverVersion: String,
        protocolVersion: String,
        policy: MCPConnectionPolicy
    ) throws {
        let now = Date.now
        let session = MCPClientSession(
            id: ownedSession?.id ?? UUID(),
            clientName: Self.bounded(clientName, fallback: "Unknown MCP client"),
            clientTitle: Self.boundedOptional(clientTitle),
            clientVersion: Self.bounded(clientVersion, fallback: "Unknown"),
            serverPID: getpid(),
            serverVersion: Self.bounded(serverVersion, fallback: "Unknown"),
            protocolVersion: Self.bounded(protocolVersion, fallback: "Unknown"),
            policy: policy,
            connectedAt: ownedSession?.connectedAt ?? now,
            lastActivityAt: now,
            lastSeenAt: now
        )
        ownedSession = session
        try persist(session)
    }

    public func heartbeat() throws {
        guard var session = ownedSession else { return }
        session.lastSeenAt = .now
        ownedSession = session
        try persist(session)
    }

    public func recordActivity() throws {
        guard var session = ownedSession else { return }
        let now = Date.now
        session.lastActivityAt = now
        session.lastSeenAt = now
        ownedSession = session
        try persist(session)
    }

    public func endSession() throws {
        guard let session = ownedSession else { return }
        ownedSession = nil
        let url = sessionURL(for: session.id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func activeSessions() -> [MCPClientSession] {
        let now = Date.now
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [MCPClientSession] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for url in urls where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let fileSize = values?.fileSize,
                  fileSize <= 64 * 1_024,
                  let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(MCPClientSession.self, from: data),
                  session.id.uuidString.lowercased() == url.deletingPathExtension().lastPathComponent else {
                continue
            }

            if now.timeIntervalSince(session.lastSeenAt) > staleInterval {
                try? fileManager.removeItem(at: url)
                continue
            }
            sessions.append(session)
        }
        return sessions.sorted {
            if $0.connectedAt != $1.connectedAt { return $0.connectedAt > $1.connectedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func persist(_ session: MCPClientSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        let url = sessionURL(for: session.id)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func sessionURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private static func defaultDirectoryURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "MacScope", directoryHint: .isDirectory)
            .appending(path: "mcp-sessions", directoryHint: .isDirectory)
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func bounded(_ value: String, fallback: String) -> String {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String((normalized.isEmpty ? fallback : normalized).prefix(200))
    }

    private static func boundedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(200))
    }
}
