import Foundation
import SQLite3

/// Dünne Hülle um die SQLite-C-API. Nicht threadsicher, Zugriff nur über `AppDatabase`.
final class SQLiteConnection {

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `path` = nil öffnet eine Datenbank im Speicher (Tests).
    init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unbekannt"
            sqlite3_close(handle)
            throw Error(description: "Datenbank lässt sich nicht öffnen: \(message)")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError(sql) }
    }

    /// Führt `sql` mit `args` aus und ruft `row` für jede Ergebniszeile auf.
    func query(_ sql: String, _ args: [SQLValue] = [], row: (Row) throws -> Void) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(args, to: statement, sql: sql)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw lastError(sql)
            }
        }
    }

    func rows<T>(_ sql: String, _ args: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        var result: [T] = []
        try query(sql, args) { result.append(try map($0)) }
        return result
    }

    func run(_ sql: String, _ args: [SQLValue] = []) throws {
        try query(sql, args) { _ in }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? rows("PRAGMA user_version") { $0.int(0) }.first) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError(sql)
        }
        // Abfragen mit variabler Platzhalterzahl (IN-Listen) nicht cachen
        if !sql.contains("/*dyn*/") { statements[sql] = statement }
        return statement
    }

    /// Nach Schemawechseln aufrufen, gecachte Statements verweisen sonst auf alte Tabellen.
    func clearStatementCache() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
    }

    private func bind(_ args: [SQLValue], to statement: OpaquePointer, sql: String) throws {
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let v): rc = sqlite3_bind_int64(statement, index, Int64(v))
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else { throw lastError(sql) }
        }
    }

    private func lastError(_ sql: String) -> Error {
        Error(description: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql)")
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        func intOrNil(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
        }

        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }

        func textOrNil(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }
    }
}

enum SQLValue {
    case null
    case int(Int)
    case text(String)

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int?) { self = value.map { .int($0) } ?? .null }
}

// SQLITE_TRANSIENT ist in Swift nicht importiert: SQLite kopiert den Text sofort
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// "?, ?, ?" für IN-Listen.
func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
