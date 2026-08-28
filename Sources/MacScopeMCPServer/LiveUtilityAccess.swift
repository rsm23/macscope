import AppKit
import Darwin
import Foundation
import MacScopeMCPBridge

actor LiveMacScopeMCPUtilityAccess: MacScopeMCPUtilityAccess {
    func state(module: MacScopeMCPUtilityModule, includeSensitive: Bool) async throws -> MacScopeMCPJSONValue {
        try await send(.init(
            kind: .state,
            module: module,
            arguments: ["include_sensitive": .bool(includeSensitive)],
            serverPID: ProcessInfo.processInfo.processIdentifier
        ))
    }

    func run(actionID: String, arguments: [String: MacScopeMCPJSONValue]) async throws -> MacScopeMCPJSONValue {
        try await send(.init(
            kind: .run,
            actionID: actionID,
            arguments: arguments,
            serverPID: ProcessInfo.processInfo.processIdentifier
        ))
    }

    private func send(_ request: MacScopeMCPUtilityRequest) async throws -> MacScopeMCPJSONValue {
        let requestData = try MacScopeMCPUtilityTransport.encode(request)
        var launchedApp = false
        for _ in 0..<80 {
            do {
                let responseData = try perform(requestData)
                let response = try MacScopeMCPUtilityTransport.decode(MacScopeMCPUtilityResponse.self, from: responseData)
                guard response.requestID == request.id else {
                    throw MacScopeMCPError.utilityRequestFailed("MacScope returned a mismatched utility response.")
                }
                if let error = response.error { throw MacScopeMCPError.utilityRequestFailed(error) }
                return response.result ?? .object(["accepted": .bool(true)])
            } catch {
                if case MacScopeMCPError.utilityRequestFailed = error { throw error }
                if !launchedApp {
                    launchedApp = true
                    await launchMacScopeIfNeeded()
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw MacScopeMCPError.utilityAppUnavailable
    }

    private func perform(_ requestData: Data) throws -> Data {
        let path = try MacScopeMCPUtilityTransport.socketURL().path
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MacScopeMCPError.utilityAppUnavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(min(Int(length), Int(UInt8.max)))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MacScopeMCPError.utilityAppUnavailable }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { throw MacScopeMCPError.utilityAppUnavailable }
        try Self.writeMessage(requestData, to: fd)
        guard let header = Self.readExactly(fd, count: 4) else { throw MacScopeMCPError.utilityAppUnavailable }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= UInt32(MacScopeMCPUtilityTransport.maximumMessageBytes),
              let response = Self.readExactly(fd, count: Int(count)) else {
            throw MacScopeMCPError.utilityAppUnavailable
        }
        return response
    }

    private func launchMacScopeIfNeeded() async {
        await MainActor.run {
            guard NSRunningApplication.runningApplications(
                withBundleIdentifier: "local.taskmanager.MacScope"
            ).isEmpty else { return }
            if let url = Self.appURL() { NSWorkspace.shared.open(url) }
        }
    }

    @MainActor
    private static func appURL() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["MACSCOPE_APP_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidate = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if candidate.pathExtension == "app" { return candidate }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.taskmanager.MacScope")
    }

    private static func readExactly(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let result = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            while offset < count {
                let amount = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if amount <= 0 { return -1 }
                offset += amount
            }
            return offset
        }
        return result == count ? data : nil
    }

    private static func writeMessage(_ data: Data, to fd: Int32) throws {
        let count = UInt32(data.count)
        let header = Data([UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)])
        guard writeAll(header, to: fd), writeAll(data, to: fd) else {
            throw MacScopeMCPError.utilityAppUnavailable
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if amount <= 0 { return false }
                offset += amount
            }
            return true
        }
    }
}
