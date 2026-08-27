import Foundation

public enum PrivilegedActionClient {
    public static func preflight(_ action: PrivilegedActionEnvelope) async throws -> ActionPreflight {
        let data = try JSONEncoder().encode(action)
        let response = try await request { proxy, reply in
            proxy.preflight(actionData: data, reply: reply)
        }
        return try JSONDecoder().decode(ActionPreflight.self, from: response)
    }

    public static func execute(_ action: PrivilegedActionEnvelope, confirmation: String) async throws -> ActionResult {
        let data = try JSONEncoder().encode(action)
        let response = try await request { proxy, reply in
            proxy.execute(actionData: data, confirmation: confirmation, reply: reply)
        }
        return try JSONDecoder().decode(ActionResult.self, from: response)
    }

    private static func request(
        _ operation: @escaping @Sendable (PrivilegedActionXPC, @escaping @Sendable (Data?, String?) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: privilegedMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedActionXPC.self)
            let reply = PrivilegedDataReply(continuation: continuation, connection: connection)
            connection.invalidationHandler = { reply.fail("The privileged helper is not connected.") }
            connection.interruptionHandler = { reply.fail("The privileged helper was interrupted.") }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.fail(error.localizedDescription)
            }) as? PrivilegedActionXPC else {
                reply.fail("The privileged action interface is unavailable.")
                return
            }
            operation(proxy) { data, message in
                if let data { reply.succeed(data) }
                else { reply.fail(message ?? "The helper returned no response.") }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
                reply.fail("The helper action timed out.")
            }
        }
    }
}

private final class PrivilegedDataReply: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Data, Error>
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<Data, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ message: String) { finish(.failure(CollectorError.permissionDenied(message))) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        continuation.resume(with: result)
    }
}
