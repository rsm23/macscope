import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandRunner {
    public static func run(executable: String, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        let cancellation = CommandCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(
                        executable: executable, arguments: arguments, timeout: timeout, cancellation: cancellation
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], timeout: TimeInterval, cancellation: CommandCancellation
    ) -> CommandResult {
        guard !cancellation.isCancelled else {
            return CommandResult(exitCode: -1, stdout: "", stderr: "Command cancelled.")
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain both pipes while the child is running. Waiting for exit first
        // deadlocks as soon as either pipe fills. Nonblocking reads also avoid
        // waiting forever for an inherited pipe held open by a descendant.
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let errorFD = errorPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errorFD, F_SETFL, fcntl(errorFD, F_GETFL) | O_NONBLOCK)
        defer {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        }
        let duration = timeout.isFinite ? max(timeout, 0) : 30
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        var output = CommandOutputBuffer()
        var error = CommandOutputBuffer()
        var terminationStarted: ContinuousClock.Instant?
        var wasInterrupted = false
        while process.isRunning {
            output.drain(outputFD)
            error.drain(errorFD)
            let now = ContinuousClock.now
            if let terminationStarted {
                if terminationStarted.duration(to: now) >= .milliseconds(100) {
                    // SIGTERM is advisory; a script can ignore it.
                    _ = kill(process.processIdentifier, SIGKILL)
                }
            } else if cancellation.isCancelled || now >= deadline {
                wasInterrupted = true
                terminationStarted = now
                process.terminate()
            }
            usleep(5_000)
        }
        output.drain(outputFD)
        error.drain(errorFD)
        return CommandResult(
            exitCode: wasInterrupted ? -1 : process.terminationStatus,
            stdout: output.text,
            stderr: error.text
        )
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private struct CommandOutputBuffer {
    // Keep noisy commands from exhausting memory, but continue draining excess
    // bytes so the cap never recreates the pipe deadlock.
    private static let limit = 8 * 1_024 * 1_024
    private var data = Data()
    private var truncated = false

    mutating func drain(_ descriptor: Int32) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<128 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            let retainedCount = min(count, Self.limit - data.count)
            data.append(contentsOf: bytes.prefix(retainedCount))
            if retainedCount < count { truncated = true }
        }
    }

    var text: String {
        String(decoding: data, as: UTF8.self) + (truncated ? "\n[Output truncated at 8 MiB.]" : "")
    }
}

public enum KeyValueTextParser {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \Character.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}

func decodedCString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

public extension ByteCountFormatter {
    static func macScope(_ bytes: UInt64) -> String {
        string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
