import Darwin
import Foundation

public struct DiskBenchmarkResult: Codable, Hashable, Sendable {
    public let writeMegabytesPerSecond: Double
    public let readMegabytesPerSecond: Double
    public let bytesTested: Int
    public let duration: TimeInterval

    public init(writeMegabytesPerSecond: Double, readMegabytesPerSecond: Double, bytesTested: Int, duration: TimeInterval) {
        self.writeMegabytesPerSecond = writeMegabytesPerSecond
        self.readMegabytesPerSecond = readMegabytesPerSecond
        self.bytesTested = bytesTested
        self.duration = duration
    }
}

public struct NetworkBenchmarkResult: Codable, Hashable, Sendable {
    public let latencyMilliseconds: Double
    public let downloadMegabitsPerSecond: Double
    public let bytesTransferred: Int
    public let provider: String

    public init(latencyMilliseconds: Double, downloadMegabitsPerSecond: Double, bytesTransferred: Int, provider: String) {
        self.latencyMilliseconds = latencyMilliseconds
        self.downloadMegabitsPerSecond = downloadMegabitsPerSecond
        self.bytesTransferred = bytesTransferred
        self.provider = provider
    }
}

public enum BenchmarkPhase: String, Codable, Hashable, Sendable {
    case diskWrite
    case diskRead
    case networkDownload
}

public struct BenchmarkProgress: Codable, Hashable, Sendable {
    public let phase: BenchmarkPhase
    public let bytesCompleted: Int
    public let totalBytes: Int
    public let bytesPerSecond: Double

    public init(phase: BenchmarkPhase, bytesCompleted: Int, totalBytes: Int, bytesPerSecond: Double) {
        self.phase = phase
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesCompleted) / Double(totalBytes), 0), 1)
    }
}

public enum BenchmarkRunner {
    public static func disk(
        at directory: URL,
        size: Int = 128 * 1_024 * 1_024,
        progress: (@Sendable (BenchmarkProgress) -> Void)? = nil
    ) async throws -> DiskBenchmarkResult {
        try await Task.detached(priority: .userInitiated) {
            let started = Date()
            let fileManager = FileManager.default
            let fileName = ".macscope-benchmark-\(UUID().uuidString)"
            let directFileURL = directory.appending(path: fileName)
            let fileURL: URL
            var replacementDirectory: URL?

            if fileManager.createFile(atPath: directFileURL.path, contents: nil) {
                fileURL = directFileURL
            } else {
                do {
                    let replacement = try fileManager.url(
                        for: .itemReplacementDirectory,
                        in: .userDomainMask,
                        appropriateFor: directory,
                        create: true
                    )
                    let replacementFileURL = replacement.appending(path: fileName)
                    guard fileManager.createFile(atPath: replacementFileURL.path, contents: nil) else {
                        try? fileManager.removeItem(at: replacement)
                        throw CollectorError.permissionDenied("MacScope could not create a same-volume temporary benchmark file.")
                    }
                    replacementDirectory = replacement
                    fileURL = replacementFileURL
                } catch let error as CollectorError {
                    throw error
                } catch {
                    throw CollectorError.permissionDenied("MacScope could not create a same-volume temporary benchmark file: \(error.localizedDescription)")
                }
            }
            defer {
                try? fileManager.removeItem(at: fileURL)
                if let replacementDirectory { try? fileManager.removeItem(at: replacementDirectory) }
            }

            let blockSize = 4 * 1_024 * 1_024
            let block = Data(repeating: 0xA5, count: blockSize)
            let writeHandle = try FileHandle(forWritingTo: fileURL)
            _ = fcntl(writeHandle.fileDescriptor, F_NOCACHE, 1)
            let writeStart = ContinuousClock.now
            var written = 0
            while written < size {
                try Task.checkCancellation()
                let count = min(blockSize, size - written)
                try writeHandle.write(contentsOf: count == blockSize ? block : block.prefix(count))
                written += count
                let elapsed = seconds(writeStart.duration(to: .now))
                progress?(BenchmarkProgress(
                    phase: .diskWrite,
                    bytesCompleted: written,
                    totalBytes: size,
                    bytesPerSecond: Double(written) / max(elapsed, 0.001)
                ))
            }
            try writeHandle.synchronize()
            try writeHandle.close()
            let writeSeconds = seconds(writeStart.duration(to: .now))

            let readHandle = try FileHandle(forReadingFrom: fileURL)
            _ = fcntl(readHandle.fileDescriptor, F_NOCACHE, 1)
            let readStart = ContinuousClock.now
            var read = 0
            while read < size {
                try Task.checkCancellation()
                guard let data = try readHandle.read(upToCount: blockSize), !data.isEmpty else { break }
                read += data.count
                let elapsed = seconds(readStart.duration(to: .now))
                progress?(BenchmarkProgress(
                    phase: .diskRead,
                    bytesCompleted: read,
                    totalBytes: size,
                    bytesPerSecond: Double(read) / max(elapsed, 0.001)
                ))
            }
            try readHandle.close()
            let readSeconds = seconds(readStart.duration(to: .now))
            guard written == size, read == size else { throw CollectorError.malformed("The disk benchmark ended before all test data was processed.") }
            let megabytes = Double(size) / 1_000_000
            return DiskBenchmarkResult(
                writeMegabytesPerSecond: megabytes / max(writeSeconds, 0.001),
                readMegabytesPerSecond: megabytes / max(readSeconds, 0.001),
                bytesTested: size,
                duration: Date().timeIntervalSince(started)
            )
        }.value
    }

    public static func network(
        downloadBytes: Int = 25_000_000,
        progress: (@Sendable (BenchmarkProgress) -> Void)? = nil
    ) async throws -> NetworkBenchmarkResult {
        guard let baseURL = URL(string: "https://speed.cloudflare.com/"),
              var components = URLComponents(string: "https://speed.cloudflare.com/__down") else {
            throw CollectorError.malformed("The benchmark endpoint is invalid.")
        }
        components.queryItems = [URLQueryItem(name: "bytes", value: String(downloadBytes))]
        guard let downloadURL = components.url else { throw CollectorError.malformed("The benchmark endpoint is invalid.") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let latencySession = URLSession(configuration: configuration)
        defer { latencySession.invalidateAndCancel() }

        var pingRequest = URLRequest(url: baseURL)
        pingRequest.httpMethod = "HEAD"
        let latencyStart = ContinuousClock.now
        _ = try await latencySession.data(for: pingRequest)
        let latency = seconds(latencyStart.duration(to: .now)) * 1_000

        let delegate = BenchmarkDownloadDelegate(expectedBytes: downloadBytes, progress: progress)
        let downloadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { downloadSession.finishTasksAndInvalidate() }
        let download = try await delegate.download(from: downloadURL, using: downloadSession)
        guard let http = download.response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              download.bytesReceived > 0 else {
            throw CollectorError.unavailable("The network benchmark endpoint returned no test data.")
        }
        let megabits = Double(download.bytesReceived) * 8 / 1_000_000
        return NetworkBenchmarkResult(
            latencyMilliseconds: latency,
            downloadMegabitsPerSecond: megabits / max(download.duration, 0.001),
            bytesTransferred: download.bytesReceived,
            provider: "Cloudflare Speed Test"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private struct BenchmarkDownload: Sendable {
    let bytesReceived: Int
    let duration: TimeInterval
    let response: URLResponse
}

private final class BenchmarkDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int
    private let progress: (@Sendable (BenchmarkProgress) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BenchmarkDownload, Error>?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var received = 0
    private var started = ContinuousClock.now
    private var lastReport = ContinuousClock.now

    init(expectedBytes: Int, progress: (@Sendable (BenchmarkProgress) -> Void)?) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func download(from url: URL, using session: URLSession) async throws -> BenchmarkDownload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    started = .now
                    lastReport = .now
                    task = session.dataTask(with: url)
                    task?.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: BenchmarkProgress? = lock.withLock {
            received += data.count
            let now = ContinuousClock.now
            let elapsed = BenchmarkRunner.elapsedSeconds(started.duration(to: now))
            let shouldReport = BenchmarkRunner.elapsedSeconds(lastReport.duration(to: now)) >= 0.05 || received >= expectedBytes
            guard shouldReport else { return nil }
            lastReport = now
            return BenchmarkProgress(
                phase: .networkDownload,
                bytesCompleted: received,
                totalBytes: expectedBytes,
                bytesPerSecond: Double(received) / max(elapsed, 0.001)
            )
        }
        if let report { progress?(report) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<BenchmarkDownload, Error>, Result<BenchmarkDownload, Error>)? = lock.withLock {
            guard let continuation else { return nil }
            self.continuation = nil
            self.task = nil
            if let error {
                return (continuation, .failure(error))
            }
            guard let response else {
                return (continuation, .failure(CollectorError.unavailable("The network benchmark returned no response.")))
            }
            let duration = BenchmarkRunner.elapsedSeconds(started.duration(to: .now))
            return (continuation, .success(BenchmarkDownload(bytesReceived: received, duration: duration, response: response)))
        }
        guard let completion else { return }
        switch completion.1 {
        case let .success(value): completion.0.resume(returning: value)
        case let .failure(error): completion.0.resume(throwing: error)
        }
    }

    private func cancel() {
        let continuation: CheckedContinuation<BenchmarkDownload, Error>? = lock.withLock {
            task?.cancel()
            task = nil
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private extension BenchmarkRunner {
    static func elapsedSeconds(_ duration: Duration) -> Double { seconds(duration) }
}
