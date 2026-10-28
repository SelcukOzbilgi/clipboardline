import Foundation
import SQLite3
import Darwin

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var string: String? { if case let .text(value) = self { return value }; return nil }
    var data: Data? { if case let .blob(value) = self { return value }; return nil }
    var number: Int64? { if case let .integer(value) = self { return value }; return nil }
}

/// A connection is confined to its creating queue. Background readers open
/// their own read-only connection; no SQLite handle crosses UI/worker queues.
final class LibraryDatabase {
    struct Failure: Error, LocalizedError {
        let code: Int32
        var errorDescription: String? { L("Library could not be saved or opened") + " (\(code))" }
    }
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, readOnly: Bool = false, verify: Bool = true) throws {
        // macOS exposes /var temporary folders through a system symlink.
        // Resolve the existing parent with POSIX before SQLITE_OPEN_NOFOLLOW;
        // the final database file still cannot itself be a symlink.
        guard let parent = url.deletingLastPathComponent().path.withCString({ realpath($0, nil) }) else { throw Failure(code: SQLITE_CANTOPEN) }
        let path = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
        free(parent)
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(handle); sqlite3_close(handle); handle = nil; throw Failure(code: code)
        }
        sqlite3_busy_timeout(handle, 3000)
        do {
            try execute("PRAGMA foreign_keys=ON")
            // Freed rows and pages are zeroed, so purged clipboard content is
            // not left in unused database space. Applies per connection.
            try execute("PRAGMA secure_delete=ON")
            if verify { guard try rows("PRAGMA quick_check").first?.values.first?.string == "ok" else { throw Failure(code: SQLITE_CORRUPT) } }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    private func statement(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure(code: sqlite3_errcode(handle)) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), result: Int32
                switch value {
                case let .text(text): result = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), transient)
                case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
                case let .real(number): result = sqlite3_bind_double(statement, index, number)
                case let .blob(data): result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw Failure(code: result) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw Failure(code: result) }
    }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        var rows = [[String: SQLValue]](), result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var row = [String: SQLValue]()
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: length) } ?? Data())
                default: row[name] = .null
                }
            }
            rows.append(row); result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Failure(code: result) }
        return rows
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func backup(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw Failure(code: SQLITE_CANTOPEN) }
        }
        let destination = try LibraryDatabase(url: url)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw Failure(code: sqlite3_errcode(destination.handle)) }
        let result = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE && finish == SQLITE_OK else { throw Failure(code: result) }
        // A standalone snapshot must not require the source's WAL/SHM files.
        try destination.execute("PRAGMA journal_mode=DELETE")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
