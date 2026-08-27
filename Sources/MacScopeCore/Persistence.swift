import CryptoKit
import Foundation
import Security
import SQLite3

public actor TelemetryDatabase {
    nonisolated(unsafe) private var database: OpaquePointer?
    private let url: URL

    public init(url: URL? = nil) throws {
        let resolvedURL = try url ?? Self.defaultURL()
        self.url = resolvedURL
        let directory = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(resolvedURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CollectorError.unavailable("Unable to open telemetry database")
        }
        try Self.execute(database, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(database, sql: "PRAGMA synchronous=NORMAL;")
        try Self.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS metric_rollups (
                bucket_size INTEGER NOT NULL,
                bucket REAL NOT NULL,
                metric_id TEXT NOT NULL,
                minimum REAL NOT NULL,
                maximum REAL NOT NULL,
                total REAL NOT NULL,
                sample_count INTEGER NOT NULL,
                last_value REAL NOT NULL,
                quality TEXT NOT NULL,
                PRIMARY KEY (bucket_size, bucket, metric_id)
            );
            CREATE INDEX IF NOT EXISTS metric_rollups_metric_time
              ON metric_rollups(metric_id, bucket_size, bucket);
            CREATE TABLE IF NOT EXISTS process_history (
                timestamp REAL PRIMARY KEY,
                encrypted_payload BLOB NOT NULL
            );
            """)
    }

    deinit { sqlite3_close(database) }

    public func record(_ snapshot: SystemSnapshot, includeMetrics: Bool = true, includeProcesses: Bool = false) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            if includeMetrics {
                for sample in snapshot.metrics {
                    guard let value = sample.value.number else { continue }
                    try insertMetric(sample, value: value, bucketSize: 10)
                    try insertMetric(sample, value: value, bucketSize: 60)
                }
            }
            if includeProcesses {
                let data = try JSONEncoder().encode(snapshot.processes)
                let encrypted = try ProcessHistoryCipher.encrypt(data)
                try insertProcessHistory(timestamp: snapshot.timestamp, data: encrypted)
            }
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func prune(metricRetention: TimeInterval = 30 * 86_400, processRetention: TimeInterval = 7 * 86_400) throws {
        let now = Date.now.timeIntervalSince1970
        try Self.execute(database, sql: "DELETE FROM metric_rollups WHERE (bucket_size = 10 AND bucket < \(now - 86_400)) OR (bucket_size = 60 AND bucket < \(now - metricRetention));")
        try Self.execute(database, sql: "DELETE FROM process_history WHERE timestamp < \(Date.now.timeIntervalSince1970 - processRetention);")
        try Self.execute(database, sql: "PRAGMA wal_checkpoint(PASSIVE);")
    }

    public func deleteAll() throws {
        try Self.execute(database, sql: "DELETE FROM metric_rollups; DELETE FROM process_history; VACUUM;")
    }

    public func fileURL() -> URL { url }

    private func insertMetric(_ sample: MetricSample, value: Double, bucketSize: Int32) throws {
        let sql = """
            INSERT INTO metric_rollups(bucket_size, bucket, metric_id, minimum, maximum, total, sample_count, last_value, quality)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(bucket_size, bucket, metric_id) DO UPDATE SET
              minimum = MIN(minimum, excluded.minimum),
              maximum = MAX(maximum, excluded.maximum),
              total = total + excluded.total,
              sample_count = sample_count + 1,
              last_value = excluded.last_value,
              quality = excluded.quality;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        let timestamp = sample.timestamp.timeIntervalSince1970
        let bucket = floor(timestamp / Double(bucketSize)) * Double(bucketSize)
        sqlite3_bind_int(statement, 1, bucketSize)
        sqlite3_bind_double(statement, 2, bucket)
        sqlite3_bind_text(statement, 3, sample.descriptorID, -1, sqliteTransient)
        sqlite3_bind_double(statement, 4, value)
        sqlite3_bind_double(statement, 5, value)
        sqlite3_bind_double(statement, 6, value)
        sqlite3_bind_double(statement, 7, value)
        sqlite3_bind_text(statement, 8, sample.quality.rawValue, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func insertProcessHistory(timestamp: Date, data: Data) throws {
        let sql = "INSERT OR REPLACE INTO process_history(timestamp, encrypted_payload) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private nonisolated static func execute(_ database: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: UnsafePointer($0)) } ?? "SQLite error"
            sqlite3_free(message)
            throw CollectorError.unavailable(detail)
        }
    }

    private func databaseError() -> CollectorError {
        CollectorError.unavailable(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
    }

    private static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "MacScope", directoryHint: .isDirectory).appending(path: "telemetry.sqlite")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ProcessHistoryCipher {
    private static let service = "local.taskmanager.MacScope"
    private static let account = "process-history-key"

    public static func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: try key())
        guard let combined = sealed.combined else { throw CollectorError.unavailable("Unable to encode encrypted process history") }
        return combined
    }

    public static func decrypt(_ data: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: try key())
    }

    private static func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw CollectorError.unavailable("Keychain error \(status)")
        }

        let data = Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init))
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CollectorError.unavailable("Unable to store process-history key: \(addStatus)")
        }
        return SymmetricKey(data: data)
    }
}
