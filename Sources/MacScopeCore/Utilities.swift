import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandRunner {
    public static func run(executable: String, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await Task.detached(priority: .utility) {
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

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: output, encoding: .utf8) ?? "",
                stderr: String(data: error, encoding: .utf8) ?? ""
            )
        }.value
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
