import Foundation
import SQLite3

// MARK: - TrustLevel

public enum TrustLevel: String, Codable, Sendable, CaseIterable {
    case unknown
    case trusted
    case suspicious
}

// MARK: - NewConnection

public struct NewConnection: Sendable {
    public let appName: String
    public let remoteHost: String
    public let countryCode: String?
    public let flagEmoji: String?
}

// MARK: - TrustManager

public actor TrustManager {

    private var db: OpaquePointer?
    private let defaults = UserDefaults.standard

    private static let appTrustKeyPrefix = "trust.app."

    // MARK: - Lifecycle

    public init() throws {
        let dbPath = try Self.databasePath()
        try Self.ensureDirectoryExists(for: dbPath)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let connection = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let h = handle { sqlite3_close(h) }
            throw TrustManagerError.openFailed(message)
        }
        self.db = connection

        // Enable WAL mode for better concurrent read performance
        try Self.executeSQL("PRAGMA journal_mode=WAL;", on: connection)
        try Self.executeSQL("""
            CREATE TABLE IF NOT EXISTS seen_pairs (
                app_name TEXT NOT NULL,
                remote_host TEXT NOT NULL,
                first_seen REAL NOT NULL,
                trust_level TEXT NOT NULL DEFAULT 'unknown',
                PRIMARY KEY(app_name, remote_host)
            );
            """, on: connection)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Public API

    /// Returns connection entries that have not been previously seen (new app+remoteHost pairs).
    /// Inserts newly seen pairs with `.unknown` trust level.
    public func checkConnections(_ entries: [ConnectionEntry]) -> [NewConnection] {
        var newConnections: [NewConnection] = []

        for entry in entries {
            let host = entry.remoteHostname ?? entry.remoteAddress
            guard !host.isEmpty else { continue }

            if !pairExists(app: entry.appName, host: host) {
                insertPair(
                    app: entry.appName,
                    host: host,
                    firstSeen: entry.timestamp,
                    trustLevel: .unknown
                )
                newConnections.append(
                    NewConnection(
                        appName: entry.appName,
                        remoteHost: host,
                        countryCode: entry.countryCode,
                        flagEmoji: entry.flagEmoji
                    )
                )
            }
        }

        return newConnections
    }

    /// Returns the effective trust level for a given app+host pair.
    /// If the app has a blanket trust override, that takes precedence.
    public func trustLevel(app: String, host: String) -> TrustLevel {
        // Check per-app override first
        if let appLevel = appTrustOverride(for: app) {
            return appLevel
        }

        // Query the database for the specific pair
        let sql = "SELECT trust_level FROM seen_pairs WHERE app_name = ? AND remote_host = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unknown
        }

        bindText(stmt, index: 1, value: app)
        bindText(stmt, index: 2, value: host)

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 0) {
                let value = String(cString: raw)
                return TrustLevel(rawValue: value) ?? .unknown
            }
        }

        return .unknown
    }

    /// Sets the trust level for a specific app+host pair.
    public func setTrustLevel(app: String, host: String, level: TrustLevel) {
        let sql = """
            UPDATE seen_pairs SET trust_level = ? WHERE app_name = ? AND remote_host = ?;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, index: 1, value: level.rawValue)
        bindText(stmt, index: 2, value: app)
        bindText(stmt, index: 3, value: host)

        sqlite3_step(stmt)
    }

    /// Marks all existing pairs for a given app as `.trusted` and stores a blanket override in UserDefaults.
    public func trustAllForApp(_ appName: String) {
        // Set blanket override in UserDefaults
        let key = Self.appTrustKeyPrefix + appName
        defaults.set(TrustLevel.trusted.rawValue, forKey: key)

        // Update all existing rows for this app
        let sql = "UPDATE seen_pairs SET trust_level = ? WHERE app_name = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, index: 1, value: TrustLevel.trusted.rawValue)
        bindText(stmt, index: 2, value: appName)

        sqlite3_step(stmt)
    }

    /// Returns all stored app+host pairs with their first-seen dates and trust levels.
    public func allPairs() -> [(appName: String, remoteHost: String, firstSeen: Date, trustLevel: TrustLevel)] {
        let sql = "SELECT app_name, remote_host, first_seen, trust_level FROM seen_pairs ORDER BY first_seen DESC;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }

        var results: [(appName: String, remoteHost: String, firstSeen: Date, trustLevel: TrustLevel)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let appRaw = sqlite3_column_text(stmt, 0),
                  let hostRaw = sqlite3_column_text(stmt, 1),
                  let levelRaw = sqlite3_column_text(stmt, 3)
            else { continue }

            let appName = String(cString: appRaw)
            let remoteHost = String(cString: hostRaw)
            let firstSeen = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            let trustLevel = TrustLevel(rawValue: String(cString: levelRaw)) ?? .unknown

            // Apply per-app override if present
            let effectiveLevel: TrustLevel
            if let appOverride = appTrustOverride(for: appName) {
                effectiveLevel = appOverride
            } else {
                effectiveLevel = trustLevel
            }

            results.append((
                appName: appName,
                remoteHost: remoteHost,
                firstSeen: firstSeen,
                trustLevel: effectiveLevel
            ))
        }

        return results
    }

    // MARK: - Private Helpers

    /// Binds a text value to a prepared statement parameter. Uses SQLITE_TRANSIENT so SQLite copies the data.
    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_PTR)
    }

    /// Executes a SQL statement on a given database connection (usable from non-isolated contexts like init).
    private static func executeSQL(_ sql: String, on db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw TrustManagerError.queryFailed(message)
        }
    }

    private func pairExists(app: String, host: String) -> Bool {
        let sql = "SELECT 1 FROM seen_pairs WHERE app_name = ? AND remote_host = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }

        bindText(stmt, index: 1, value: app)
        bindText(stmt, index: 2, value: host)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func insertPair(app: String, host: String, firstSeen: Date, trustLevel: TrustLevel) {
        let sql = """
            INSERT OR IGNORE INTO seen_pairs (app_name, remote_host, first_seen, trust_level)
            VALUES (?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, index: 1, value: app)
        bindText(stmt, index: 2, value: host)
        sqlite3_bind_double(stmt, 3, firstSeen.timeIntervalSinceReferenceDate)
        bindText(stmt, index: 4, value: trustLevel.rawValue)

        sqlite3_step(stmt)
    }

    /// Reads the per-app trust override from UserDefaults, if set.
    private func appTrustOverride(for appName: String) -> TrustLevel? {
        let key = Self.appTrustKeyPrefix + appName
        guard let raw = defaults.string(forKey: key) else { return nil }
        return TrustLevel(rawValue: raw)
    }

    // MARK: - File System Helpers

    private static func databasePath() throws -> String {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw TrustManagerError.openFailed("Cannot locate Application Support directory")
        }
        let dir = appSupport.appendingPathComponent("Sentry", isDirectory: true)
        return dir.appendingPathComponent("trust.db").path
    }

    private static func ensureDirectoryExists(for filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - SQLITE_TRANSIENT Helper

/// A helper constant that represents `SQLITE_TRANSIENT` (value -1 cast to the expected destructor type).
/// SQLite will make its own private copy of the bound data.
private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Errors

public enum TrustManagerError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg):  return "TrustManager: failed to open database - \(msg)"
        case .queryFailed(let msg): return "TrustManager: query failed - \(msg)"
        }
    }
}
