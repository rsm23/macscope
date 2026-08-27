import Foundation

public let privilegedMachServiceName = "local.taskmanager.MacScope.Helper"

@objc public protocol PrivilegedTelemetryXPC {
    func handshake(reply: @escaping @Sendable (Int, String) -> Void)
    func sampleDeepTelemetry(reply: @escaping @Sendable (Data?, String?) -> Void)
}

@objc public protocol PrivilegedActionXPC {
    func preflight(actionData: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    func execute(actionData: Data, confirmation: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}

@objc public protocol MacScopePrivilegedXPC: PrivilegedTelemetryXPC, PrivilegedActionXPC {}

public enum ProcessActionKind: String, Codable, Sendable, CaseIterable {
    case terminate
    case kill
    case stop
    case resume
    case renice
}

public struct ProcessActionRequest: Codable, Hashable, Sendable {
    public let kind: ProcessActionKind
    public let pid: Int32
    public let expectedStartTime: Date
    public let priority: Int32?

    public init(kind: ProcessActionKind, pid: Int32, expectedStartTime: Date, priority: Int32? = nil) {
        self.kind = kind
        self.pid = pid
        self.expectedStartTime = expectedStartTime
        self.priority = priority
    }
}

public struct ActionPreflight: Codable, Hashable, Sendable {
    public let target: String
    public let operation: String
    public let expectedEffect: String
    public let confirmationPhrase: String
    public let reversible: Bool

    public init(target: String, operation: String, expectedEffect: String, confirmationPhrase: String, reversible: Bool) {
        self.target = target
        self.operation = operation
        self.expectedEffect = expectedEffect
        self.confirmationPhrase = confirmationPhrase
        self.reversible = reversible
    }
}

public struct ActionResult: Codable, Hashable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let timestamp: Date

    public init(succeeded: Bool, message: String, timestamp: Date = .now) {
        self.succeeded = succeeded
        self.message = message
        self.timestamp = timestamp
    }
}

public enum LaunchDomain: String, Codable, Hashable, Sendable {
    case user
    case gui
    case system
}

public enum LaunchActionKind: String, Codable, Hashable, Sendable {
    case bootstrap
    case bootout
    case enable
    case disable
    case kickstart
}

public struct LaunchActionRequest: Codable, Hashable, Sendable {
    public let kind: LaunchActionKind
    public let domain: LaunchDomain
    public let label: String
    public let propertyListPath: String?
    public let userID: UInt32?

    public init(kind: LaunchActionKind, domain: LaunchDomain, label: String, propertyListPath: String? = nil, userID: UInt32? = nil) {
        self.kind = kind
        self.domain = domain
        self.label = label
        self.propertyListPath = propertyListPath
        self.userID = userID
    }
}

public enum PrivilegedActionEnvelope: Codable, Hashable, Sendable {
    case process(ProcessActionRequest)
    case launchd(LaunchActionRequest)
}
