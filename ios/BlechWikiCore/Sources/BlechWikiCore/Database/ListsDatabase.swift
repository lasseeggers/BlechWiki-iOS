import Foundation

/// Favoriten und eigene Listen. Anders als `AppDatabase` liegen hier Nutzerdaten, die sich nicht
/// neu laden lassen. Deshalb eine eigene Datei (`SharedStorage.listsDatabaseURL()`), und ein neues
/// Schema kommt nur über schrittweise Migrationen (`user_version`), nie über einen Neuaufbau.
///
/// Threadsicher über eine Verbindung unter Sperre. Die Datei ist klein, jede Abfrage dauert
/// Millisekunden. Ohne WAL bleibt alles in einer Datei, ein Backup sieht immer einen ganzen Stand.
public final class ListsDatabase: @unchecked Sendable {

    static let favoritesId = "favoriten"
    static let favoritesName = "Favoriten"
    /// Neueste Version, die diese App kennt.
    static let schemaVersion = 1

    private let lock = NSLock()
    private let connection: SQLiteConnection
    let changes: DataChanges
    /// Die Datei stammt von einer neueren App-Version (z. B. nach Rückkehr zu einer älteren aus
    /// TestFlight). Dann bleibt sie unverändert, jedes Schreiben scheitert.
    let isReadOnly: Bool

    /// `url` = nil: Datenbank im Speicher, für Tests.
    public init(url: URL?, changes: DataChanges = DataChanges()) throws {
        let connection = try SQLiteConnection(path: url?.path)
        // Löscht mit einer Liste ihre Einträge (ON DELETE CASCADE). Gilt nur für diese Verbindung.
        try connection.execute("PRAGMA foreign_keys = ON")
        if try connection.userVersion() > Self.schemaVersion {
            try connection.execute("PRAGMA query_only = ON")
            isReadOnly = true
        } else {
            try connection.transaction {
                try Self.migrate(connection)
                // Bei jedem Öffnen, falls die Zeile fehlt
                let now = Int(Date().timeIntervalSince1970 * 1000)
                try connection.run(
                    "INSERT OR IGNORE INTO lists (id, name, createdAtMillis, updatedAtMillis) VALUES (?, ?, ?, ?)",
                    [.text(Self.favoritesId), .text(Self.favoritesName), .int(now), .int(now)]
                )
            }
            isReadOnly = false
        }
        self.connection = connection
        self.changes = changes
    }

    /// Von der gespeicherten Version schrittweise bis `schemaVersion`. Jeder Schritt bleibt für immer
    /// stehen, damit auch eine Datei aus der ersten Version jede spätere erreicht. Läuft in der
    /// Transaktion von `init`.
    private static func migrate(_ db: SQLiteConnection) throws {
        let stored = try db.userVersion()
        var version = stored
        if version < 1 {
            try db.execute("""
                CREATE TABLE lists (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
                    createdAtMillis INTEGER NOT NULL, updatedAtMillis INTEGER NOT NULL);
                CREATE TABLE list_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    listId TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, kind TEXT NOT NULL, entryKey TEXT NOT NULL, title TEXT NOT NULL,
                    bookId TEXT, bookTitle TEXT, number TEXT, addition TEXT,
                    egIx INTEGER, egIxUr INTEGER, egLabel TEXT,
                    comment TEXT, addedAtMillis INTEGER NOT NULL);
                CREATE INDEX list_entries_list ON list_entries(listId, position);
                CREATE INDEX list_entries_key ON list_entries(entryKey);
                """)
            version = 1
        }
        if version != stored {
            db.clearStatementCache()
            try db.setUserVersion(version)
        }
    }

    func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(connection)
    }

    /// Schreibt in einer Transaktion und meldet danach die Änderung.
    func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let result: T = try {
            lock.lock()
            defer { lock.unlock() }
            return try connection.transaction { try body(connection) }
        }()
        changes.notify()
        return result
    }
}

/// Eine Zeile aus `list_entries`.
struct ListEntryRecord: Equatable {
    var id: String
    var listId: String
    var position: Int
    var kind: String
    var entryKey: String
    var title: String
    var bookId: String?
    var bookTitle: String?
    var number: String?
    var addition: String?
    var egIx: Int?
    var egIxUr: Int?
    var egLabel: String?
    var comment: String?
    var addedAtMillis: Int
}

extension ListsDatabase {

    /// Alle Listen mit Zahl der Einträge, unsortiert.
    func lists() throws -> [ListSummary] {
        try read { db in
            try db.rows("""
                SELECT l.id, l.name, COUNT(e.id) FROM lists l
                LEFT JOIN list_entries e ON e.listId = l.id
                GROUP BY l.id
                """) {
                ListSummary(id: $0.text(0), name: $0.text(1), entryCount: $0.int(2))
            }
        }
    }

    func listName(id: String) throws -> String? {
        try read { db in try db.rows("SELECT name FROM lists WHERE id = ?", [.text(id)]) { $0.text(0) }.first }
    }

    func entries(listId: String) throws -> [ListEntryRecord] {
        try read { db in try Self.entries(db, listId: listId) }
    }

    func entry(id: String) throws -> ListEntryRecord? {
        try read { db in
            try db.rows("SELECT \(Self.entryColumns) FROM list_entries WHERE id = ?", [.text(id)], map: Self.entry).first
        }
    }

    func keys(listId: String) throws -> Set<String> {
        try read { db in Set(try db.rows("SELECT entryKey FROM list_entries WHERE listId = ?", [.text(listId)]) { $0.text(0) }) }
    }

    func listIds(containing key: String) throws -> Set<String> {
        try read { db in Set(try db.rows("SELECT listId FROM list_entries WHERE entryKey = ?", [.text(key)]) { $0.text(0) }) }
    }

    /// Kommentar des ersten Eintrags mit `key` in der Liste.
    func comment(listId: String, key: String) throws -> String? {
        try read { db in
            try db.rows(
                "SELECT comment FROM list_entries WHERE listId = ? AND entryKey = ? AND comment IS NOT NULL ORDER BY position LIMIT 1",
                [.text(listId), .text(key)]
            ) { $0.text(0) }.first
        }
    }

    static func entries(_ db: SQLiteConnection, listId: String) throws -> [ListEntryRecord] {
        try db.rows("SELECT \(entryColumns) FROM list_entries WHERE listId = ? ORDER BY position", [.text(listId)], map: entry)
    }

    static func listExists(_ db: SQLiteConnection, id: String) throws -> Bool {
        try !db.rows("SELECT 1 FROM lists WHERE id = ?", [.text(id)]) { $0.int(0) }.isEmpty
    }

    static func containsKey(_ db: SQLiteConnection, listId: String, key: String) throws -> Bool {
        try !db.rows("SELECT 1 FROM list_entries WHERE listId = ? AND entryKey = ? LIMIT 1", [.text(listId), .text(key)]) { $0.int(0) }.isEmpty
    }

    static func insertList(_ db: SQLiteConnection, id: String, name: String, nowMillis: Int) throws {
        try db.run(
            "INSERT INTO lists (id, name, createdAtMillis, updatedAtMillis) VALUES (?, ?, ?, ?)",
            [.text(id), .text(name), .int(nowMillis), .int(nowMillis)]
        )
    }

    static func renameList(_ db: SQLiteConnection, id: String, name: String, nowMillis: Int) throws {
        try db.run("UPDATE lists SET name = ?, updatedAtMillis = ? WHERE id = ?", [.text(name), .int(nowMillis), .text(id)])
    }

    /// Die Einträge löscht SQLite mit (ON DELETE CASCADE).
    static func deleteList(_ db: SQLiteConnection, id: String) throws {
        try db.run("DELETE FROM lists WHERE id = ?", [.text(id)])
    }

    static func touchList(_ db: SQLiteConnection, id: String, nowMillis: Int) throws {
        try db.run("UPDATE lists SET updatedAtMillis = ? WHERE id = ?", [.int(nowMillis), .text(id)])
    }

    /// Hängt `entry` unten an, `entry.position` wird dabei gesetzt.
    static func appendEntry(_ db: SQLiteConnection, _ entry: ListEntryRecord) throws {
        let next = try db.rows("SELECT COALESCE(MAX(position) + 1, 0) FROM list_entries WHERE listId = ?", [.text(entry.listId)]) { $0.int(0) }.first ?? 0
        try db.run(
            """
            INSERT INTO list_entries (\(entryColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(entry.id), .text(entry.listId), .int(next), .text(entry.kind), .text(entry.entryKey), .text(entry.title),
             SQLValue(entry.bookId), SQLValue(entry.bookTitle), SQLValue(entry.number), SQLValue(entry.addition),
             SQLValue(entry.egIx), SQLValue(entry.egIxUr), SQLValue(entry.egLabel), SQLValue(entry.comment),
             .int(entry.addedAtMillis)]
        )
    }

    static func deleteEntries(_ db: SQLiteConnection, ids: [String]) throws {
        for id in ids { try db.run("DELETE FROM list_entries WHERE id = ?", [.text(id)]) }
    }

    /// Schreibt die Positionen in der Reihenfolge von `ids` neu, lückenlos ab 0.
    static func setPositions(_ db: SQLiteConnection, ids: [String]) throws {
        for (position, id) in ids.enumerated() {
            try db.run("UPDATE list_entries SET position = ? WHERE id = ?", [.int(position), .text(id)])
        }
    }

    static func setComment(_ db: SQLiteConnection, entryId: String, comment: String?) throws {
        try db.run("UPDATE list_entries SET comment = ? WHERE id = ?", [SQLValue(comment), .text(entryId)])
    }

    private static let entryColumns = """
        id, listId, position, kind, entryKey, title, bookId, bookTitle, number, addition, egIx, egIxUr, egLabel, comment, addedAtMillis
        """

    private static func entry(_ row: SQLiteConnection.Row) -> ListEntryRecord {
        ListEntryRecord(
            id: row.text(0), listId: row.text(1), position: row.int(2), kind: row.text(3), entryKey: row.text(4),
            title: row.text(5), bookId: row.textOrNil(6), bookTitle: row.textOrNil(7), number: row.textOrNil(8),
            addition: row.textOrNil(9), egIx: row.intOrNil(10), egIxUr: row.intOrNil(11), egLabel: row.textOrNil(12),
            comment: row.textOrNil(13), addedAtMillis: row.int(14)
        )
    }
}
