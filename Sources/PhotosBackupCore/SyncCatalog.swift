import Foundation
import CSQLite

struct PlannedPhotoResource: Codable {
    enum Disposition: Codable {
        case candidate(existing: BlobRecord?)
        case skipped(reason: String, size: Int64?)
        case failed(message: String)
    }

    let item: BackupItem
    let disposition: Disposition
}

final class SyncCatalog {
    private let url: URL
    private var database: OpaquePointer?
    private var insertBlobStatement: OpaquePointer?
    private var lookupBlobStatement: OpaquePointer?
    private var insertPlanStatement: OpaquePointer?
    private var insertUndatedStatement: OpaquePointer?
    private var countUndatedStatement: OpaquePointer?
    private var planCursor: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) throws {
        url = directory.appendingPathComponent("sync-catalog-\(UUID().uuidString.lowercased()).sqlite")
        let openResult = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard openResult == SQLITE_OK, database != nil else {
            closeDatabase()
            throw BackupError.storage("could not create the private sync catalog")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do {
            try execute("PRAGMA journal_mode=OFF")
            try execute("PRAGMA synchronous=OFF")
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA cache_size=-4096")
            try execute("CREATE TABLE azure_blobs(name TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID")
            try execute("CREATE TABLE sync_plan(seq INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)")
            try execute("CREATE TABLE undated_assets(asset_id TEXT PRIMARY KEY) WITHOUT ROWID")
            try prepare("INSERT OR REPLACE INTO azure_blobs(name, payload) VALUES(?, ?)", into: &insertBlobStatement)
            try prepare("SELECT payload FROM azure_blobs WHERE name = ?", into: &lookupBlobStatement)
            try prepare("INSERT INTO sync_plan(payload) VALUES(?)", into: &insertPlanStatement)
            try prepare("INSERT OR IGNORE INTO undated_assets(asset_id) VALUES(?)", into: &insertUndatedStatement)
            try prepare("SELECT COUNT(*) FROM undated_assets", into: &countUndatedStatement)
            try prepare("SELECT payload FROM sync_plan ORDER BY seq", into: &planCursor)
        } catch {
            closeDatabase()
            removeFiles()
            throw error
        }
    }

    func beginBatch() throws { try execute("BEGIN TRANSACTION") }
    func commitBatch() throws { try execute("COMMIT TRANSACTION") }
    func rollbackBatch() { try? execute("ROLLBACK TRANSACTION") }

    func insertBlob(_ blob: ListedBlob) throws {
        guard let statement = insertBlobStatement else { throw catalogError() }
        try reset(statement)
        try bind(blob.name, at: 1, to: statement)
        try bind(try encoder.encode(blob.record), at: 2, to: statement)
        try stepDone(statement)
    }

    func blob(named name: String) throws -> BlobRecord? {
        guard let statement = lookupBlobStatement else { throw catalogError() }
        try reset(statement)
        try bind(name, at: 1, to: statement)
        let result = sqlite3_step(statement)
        defer { _ = sqlite3_reset(statement); _ = sqlite3_clear_bindings(statement) }
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let data = columnData(statement, at: 0) else { throw catalogError() }
        return try decoder.decode(BlobRecord.self, from: data)
    }

    func append(_ entry: PlannedPhotoResource) throws {
        guard let statement = insertPlanStatement else { throw catalogError() }
        try reset(statement)
        try bind(try encoder.encode(entry), at: 1, to: statement)
        try stepDone(statement)
    }

    func addUndatedAsset(_ assetID: String) throws {
        guard let statement = insertUndatedStatement else { throw catalogError() }
        try reset(statement)
        try bind(assetID, at: 1, to: statement)
        try stepDone(statement)
    }

    func unclassifiableAssetCount() throws -> Int {
        guard let statement = countUndatedStatement, sqlite3_step(statement) == SQLITE_ROW else {
            throw catalogError()
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        _ = sqlite3_reset(statement)
        return count
    }

    func nextPlan() throws -> PlannedPhotoResource? {
        guard let planCursor else { throw catalogError() }
        let result = sqlite3_step(planCursor)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let data = columnData(planCursor, at: 0) else { throw catalogError() }
        return try decoder.decode(PlannedPhotoResource.self, from: data)
    }

    func remove() {
        closeDatabase()
        removeFiles()
    }

    deinit { closeDatabase() }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard let database else { throw catalogError() }
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw catalogError() }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw catalogError() }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw catalogError() }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard result == SQLITE_OK else { throw catalogError() }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw catalogError() }
    }

    private func reset(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else { throw catalogError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw catalogError() }
    }

    private func columnData(_ statement: OpaquePointer, at index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func catalogError() -> BackupError {
        .storage("local sync catalog operation failed")
    }

    private func closeDatabase() {
        for statement in [insertBlobStatement, lookupBlobStatement, insertPlanStatement,
                          insertUndatedStatement, countUndatedStatement, planCursor].compactMap({ $0 }) {
            sqlite3_finalize(statement)
        }
        insertBlobStatement = nil
        lookupBlobStatement = nil
        insertPlanStatement = nil
        insertUndatedStatement = nil
        countUndatedStatement = nil
        planCursor = nil
        if let database { _ = sqlite3_close(database) }
        database = nil
    }

    private func removeFiles() {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
