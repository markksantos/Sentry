import Foundation
import SQLite3

// MARK: - SQLiteError

public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case executionFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let msg):      return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg):   return "SQLite prepare failed: \(msg)"
        case .executionFailed(let msg): return "SQLite execution failed: \(msg)"
        case .stepFailed(let msg):      return "SQLite step failed: \(msg)"
        }
    }
}

// MARK: - SQLiteStore

/// Actor-isolated SQLite storage for persisting connection history.
///
/// Uses the C SQLite3 API directly (via `import SQLite3`) with no external
/// dependencies. The database is stored in `~/Library/Application Support/Sentry/`.
public actor SQLiteStore {

    // MARK: - Properties

    /// Opaque pointer to the SQLite database.
    private var db: OpaquePointer?

    /// Path to the database file on disk.
    public let databasePath: String

    // MARK: - Initialization

    /// Open (or create) the database and ensure the schema is up to date.
    /// - Throws: `SQLiteError` if the database cannot be opened.
    public init() throws {
        let path = try Self.ensureDatabaseDirectory()
        self.databasePath = path

        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let openedDB = dbPointer else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw SQLiteError.openFailed(msg)
        }
        self.db = openedDB

        // Enable WAL mode for better concurrent read/write performance.
        try Self.executeOnDB(openedDB, sql: "PRAGMA journal_mode=WAL;")
        try Self.initializeTables(on: openedDB)
    }

    /// Initialize with a specific database path (for testing).
    public init(path: String) throws {
        self.databasePath = path

        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let openedDB = dbPointer else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw SQLiteError.openFailed(msg)
        }
        self.db = openedDB

        try Self.executeOnDB(openedDB, sql: "PRAGMA journal_mode=WAL;")
        try Self.initializeTables(on: openedDB)
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Schema

    /// Nonisolated static helper to execute SQL on a raw db pointer.
    /// Used during `init` before the actor is fully initialized.
    private static func executeOnDB(_ db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let msg = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError.executionFailed(msg)
        }
    }

    /// Create tables and indexes on the given database handle.
    private static func initializeTables(on db: OpaquePointer) throws {
        let createSQL = """
            CREATE TABLE IF NOT EXISTS connections (
                id TEXT PRIMARY KEY,
                app_name TEXT NOT NULL,
                pid INTEGER,
                protocol TEXT,
                local_address TEXT,
                local_port INTEGER,
                remote_address TEXT,
                remote_port INTEGER,
                remote_hostname TEXT,
                country_code TEXT,
                state TEXT,
                direction TEXT,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL
            );
            """
        try executeOnDB(db, sql: createSQL)
        try executeOnDB(db, sql: "CREATE INDEX IF NOT EXISTS idx_app ON connections(app_name);")
        try executeOnDB(db, sql: "CREATE INDEX IF NOT EXISTS idx_remote ON connections(remote_address);")
        try executeOnDB(db, sql: "CREATE INDEX IF NOT EXISTS idx_timestamp ON connections(last_seen);")
    }

    // MARK: - Upsert

    /// Insert or update a single connection entry.
    /// If a row with the same `app_name`, `remote_address`, and `remote_port` exists,
    /// update `last_seen`. Otherwise insert a new row.
    public func upsert(_ entry: ConnectionEntry) throws {
        try upsertBatch([entry])
    }

    /// Insert or update multiple connection entries within a single transaction.
    public func upsertBatch(_ entries: [ConnectionEntry]) throws {
        guard !entries.isEmpty else { return }

        try execute("BEGIN TRANSACTION;")

        let sql = """
            INSERT INTO connections (
                id, app_name, pid, protocol, local_address, local_port,
                remote_address, remote_port, remote_hostname, country_code,
                state, direction, first_seen, last_seen
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                last_seen = excluded.last_seen,
                state = excluded.state,
                remote_hostname = COALESCE(excluded.remote_hostname, connections.remote_hostname),
                country_code = COALESCE(excluded.country_code, connections.country_code);
            """

        // Also handle logical upsert: same app+remote_address+remote_port -> update last_seen.
        let checkSQL = """
            SELECT id FROM connections
            WHERE app_name = ? AND remote_address = ? AND remote_port = ?
            LIMIT 1;
            """

        let updateSQL = """
            UPDATE connections
            SET last_seen = ?, state = ?,
                remote_hostname = COALESCE(?, remote_hostname),
                country_code = COALESCE(?, country_code)
            WHERE id = ?;
            """

        for entry in entries {
            // Check if a matching row exists.
            var checkStmt: OpaquePointer?
            defer { sqlite3_finalize(checkStmt) }

            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
                try execute("ROLLBACK;")
                throw SQLiteError.prepareFailed(errorMessage)
            }

            bindText(checkStmt, index: 1, value: entry.appName)
            bindText(checkStmt, index: 2, value: entry.remoteAddress)
            bindInt(checkStmt, index: 3, value: Int(entry.remotePort))

            if sqlite3_step(checkStmt) == SQLITE_ROW {
                // Existing row found -- update it.
                let existingID = columnText(checkStmt, index: 0) ?? entry.id.uuidString
                sqlite3_finalize(checkStmt)
                checkStmt = nil

                var updateStmt: OpaquePointer?
                defer { sqlite3_finalize(updateStmt) }

                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                    try execute("ROLLBACK;")
                    throw SQLiteError.prepareFailed(errorMessage)
                }

                bindDouble(updateStmt, index: 1, value: entry.timestamp.timeIntervalSince1970)
                bindText(updateStmt, index: 2, value: entry.state.rawValue)
                bindOptionalText(updateStmt, index: 3, value: entry.remoteHostname)
                bindOptionalText(updateStmt, index: 4, value: entry.countryCode)
                bindText(updateStmt, index: 5, value: existingID)

                let rc = sqlite3_step(updateStmt)
                guard rc == SQLITE_DONE else {
                    try execute("ROLLBACK;")
                    throw SQLiteError.stepFailed(errorMessage)
                }
            } else {
                // No existing row -- insert new.
                sqlite3_finalize(checkStmt)
                checkStmt = nil

                var insertStmt: OpaquePointer?
                defer { sqlite3_finalize(insertStmt) }

                guard sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK else {
                    try execute("ROLLBACK;")
                    throw SQLiteError.prepareFailed(errorMessage)
                }

                bindText(insertStmt, index: 1, value: entry.id.uuidString)
                bindText(insertStmt, index: 2, value: entry.appName)
                bindInt(insertStmt, index: 3, value: Int(entry.pid))
                bindText(insertStmt, index: 4, value: entry.protocolType.rawValue)
                bindText(insertStmt, index: 5, value: entry.localAddress)
                bindInt(insertStmt, index: 6, value: Int(entry.localPort))
                bindText(insertStmt, index: 7, value: entry.remoteAddress)
                bindInt(insertStmt, index: 8, value: Int(entry.remotePort))
                bindOptionalText(insertStmt, index: 9, value: entry.remoteHostname)
                bindOptionalText(insertStmt, index: 10, value: entry.countryCode)
                bindText(insertStmt, index: 11, value: entry.state.rawValue)
                bindText(insertStmt, index: 12, value: entry.direction.rawValue)
                bindDouble(insertStmt, index: 13, value: entry.timestamp.timeIntervalSince1970)
                bindDouble(insertStmt, index: 14, value: entry.timestamp.timeIntervalSince1970)

                let rc = sqlite3_step(insertStmt)
                guard rc == SQLITE_DONE else {
                    try execute("ROLLBACK;")
                    throw SQLiteError.stepFailed(errorMessage)
                }
            }
        }

        try execute("COMMIT;")
    }

    // MARK: - Queries

    /// Search connections by app name, remote address, or remote hostname.
    public func search(term: String) throws -> [ConnectionEntry] {
        let sql = """
            SELECT * FROM connections
            WHERE app_name LIKE ? OR remote_address LIKE ? OR remote_hostname LIKE ?
            ORDER BY last_seen DESC;
            """
        let wildcard = "%\(term)%"
        return try query(sql, bindings: [.text(wildcard), .text(wildcard), .text(wildcard)])
    }

    /// Filter connections by app name.
    public func filterByApp(_ appName: String) throws -> [ConnectionEntry] {
        let sql = "SELECT * FROM connections WHERE app_name = ? ORDER BY last_seen DESC;"
        return try query(sql, bindings: [.text(appName)])
    }

    /// Filter connections by country code.
    public func filterByCountry(_ countryCode: String) throws -> [ConnectionEntry] {
        let sql = "SELECT * FROM connections WHERE country_code = ? ORDER BY last_seen DESC;"
        return try query(sql, bindings: [.text(countryCode)])
    }

    /// Retrieve all entries with pagination.
    public func allEntries(limit: Int = 500, offset: Int = 0) throws -> [ConnectionEntry] {
        let sql = "SELECT * FROM connections ORDER BY last_seen DESC LIMIT ? OFFSET ?;"
        return try query(sql, bindings: [.int(limit), .int(offset)])
    }

    // MARK: - Export

    /// Export all rows to a CSV file in the temporary directory.
    /// Returns the URL of the created file, or `nil` on failure.
    public func exportCSV() throws -> URL? {
        let entries = try allEntries(limit: Int.max, offset: 0)
        guard !entries.isEmpty else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("sentry-export-\(Int(Date().timeIntervalSince1970)).csv")

        var csv = "id,app_name,pid,protocol,local_address,local_port,remote_address,remote_port,"
        csv += "remote_hostname,country_code,state,direction,timestamp\n"

        for entry in entries {
            let fields: [String] = [
                entry.id.uuidString,
                escapeCSV(entry.appName),
                "\(entry.pid)",
                entry.protocolType.rawValue,
                entry.localAddress,
                "\(entry.localPort)",
                entry.remoteAddress,
                "\(entry.remotePort)",
                entry.remoteHostname ?? "",
                entry.countryCode ?? "",
                entry.state.rawValue,
                entry.direction.rawValue,
                ISO8601DateFormatter().string(from: entry.timestamp),
            ]
            csv += fields.joined(separator: ",") + "\n"
        }

        try csv.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Maintenance

    /// Delete all stored connection history.
    public func clearHistory() throws {
        try execute("DELETE FROM connections;")
        try execute("VACUUM;")
    }

    // MARK: - Private Helpers

    /// Ensure the Application Support directory exists and return the DB path.
    private static func ensureDatabaseDirectory() throws -> String {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let sentryDir = appSupport.appendingPathComponent("Sentry", isDirectory: true)

        if !fileManager.fileExists(atPath: sentryDir.path) {
            try fileManager.createDirectory(at: sentryDir, withIntermediateDirectories: true)
        }

        return sentryDir.appendingPathComponent("history.db").path
    }

    /// Execute a raw SQL statement (no result set).
    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let msg = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw SQLiteError.executionFailed(msg)
        }
    }

    /// Current error message from the database handle.
    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    // MARK: - Binding Helpers

    private enum BindingValue {
        case text(String)
        case int(Int)
        case double(Double)
        case null
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value = value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, index: Int32, value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func bindDouble(_ stmt: OpaquePointer?, index: Int32, value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    // MARK: - Query Helpers

    private func query(_ sql: String, bindings: [BindingValue]) throws -> [ConnectionEntry] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage)
        }

        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case .text(let value):
                bindText(stmt, index: idx, value: value)
            case .int(let value):
                bindInt(stmt, index: idx, value: value)
            case .double(let value):
                bindDouble(stmt, index: idx, value: value)
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [ConnectionEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = readRow(stmt) {
                results.append(entry)
            }
        }
        return results
    }

    /// Read a single row from a prepared statement into a `ConnectionEntry`.
    private func readRow(_ stmt: OpaquePointer?) -> ConnectionEntry? {
        guard let stmt = stmt else { return nil }

        let idString = columnText(stmt, index: 0) ?? ""
        let appName = columnText(stmt, index: 1) ?? ""
        let pid = Int32(sqlite3_column_int(stmt, 2))
        let protocolStr = columnText(stmt, index: 3) ?? "tcp"
        let localAddress = columnText(stmt, index: 4) ?? ""
        let localPort = UInt16(sqlite3_column_int(stmt, 5))
        let remoteAddress = columnText(stmt, index: 6) ?? ""
        let remotePort = UInt16(sqlite3_column_int(stmt, 7))
        let remoteHostname = columnText(stmt, index: 8)
        let countryCode = columnText(stmt, index: 9)
        let stateStr = columnText(stmt, index: 10) ?? "UNKNOWN"
        let directionStr = columnText(stmt, index: 11) ?? "unknown"
        let lastSeen = sqlite3_column_double(stmt, 13)

        let id = UUID(uuidString: idString) ?? UUID()
        let proto = ProtocolType(rawValue: protocolStr) ?? .tcp
        let state = ConnectionState(rawValue: stateStr) ?? .unknown
        let direction = Direction(rawValue: directionStr) ?? .unknown

        let flagEmoji: String?
        if let cc = countryCode, cc.count == 2 {
            flagEmoji = Self.flagEmoji(for: cc)
        } else {
            flagEmoji = nil
        }

        return ConnectionEntry(
            id: id,
            appName: appName,
            pid: pid,
            protocolType: proto,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            state: state,
            direction: direction,
            timestamp: Date(timeIntervalSince1970: lastSeen),
            remoteHostname: remoteHostname,
            countryCode: countryCode,
            flagEmoji: flagEmoji
        )
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Convert country code to flag emoji (static helper for use outside actor context).
    private static func flagEmoji(for countryCode: String) -> String {
        let upper = countryCode.uppercased()
        var emoji = ""
        for scalar in upper.unicodeScalars {
            guard scalar.value >= 0x41, scalar.value <= 0x5A else { continue }
            if let regional = UnicodeScalar(0x1F1E6 + (scalar.value - 0x41)) {
                emoji.append(String(regional))
            }
        }
        return emoji
    }
}
