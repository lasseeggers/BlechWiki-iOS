import Foundation

/// Lokale Datenbank. Enthält nur Daten, die sich jederzeit neu vom Server laden lassen.
/// Deshalb bei Schemawechsel Neuaufbau statt Migration, wie bei der Android-App. Ausnahme sind
/// einfache Spalten-Ergänzungen: Ein Neuaufbau würde den Fundstellen-Cache der Inventar-Bücher
/// verwerfen, und jedes Gerät müsste sie neu laden.
///
/// Threadsicher: Alle Zugriffe laufen unter einer Sperre. Die Abfragen sind klein
/// (Millisekunden), nur der Stammdaten-Abgleich schreibt größere Mengen.
public final class AppDatabase: @unchecked Sendable {

    private static let schemaVersion = 2

    private let lock = NSLock()
    private let connection: SQLiteConnection
    let changes: DataChanges

    /// `url` = nil: Datenbank im Speicher, für Tests.
    public init(url: URL?, changes: DataChanges = DataChanges()) throws {
        connection = try SQLiteConnection(path: url?.path)
        self.changes = changes
        try connection.execute("PRAGMA journal_mode = WAL")
        switch connection.userVersion {
        case Self.schemaVersion: break
        case 1: try migrateFrom1()
        default: try recreateSchema()
        }
    }

    /// Version 2: Änderungszähler der REST-API in `sync_state`.
    private func migrateFrom1() throws {
        try connection.transaction {
            try connection.execute("""
                ALTER TABLE sync_state ADD COLUMN bookChangeCounter INTEGER;
                ALTER TABLE sync_state ADD COLUMN composerChangeCounter INTEGER;
                ALTER TABLE sync_state ADD COLUMN titleChangeCounter INTEGER;
                """)
        }
        connection.clearStatementCache()
        connection.userVersion = Self.schemaVersion
    }

    private func recreateSchema() throws {
        let existing = try connection.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'search_index_%'") { $0.text(0) }
        for table in existing { try connection.execute("DROP TABLE IF EXISTS \"\(table)\"") }
        try connection.execute("""
            CREATE TABLE books (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, subtitle TEXT, year INTEGER,
                editor TEXT, publisher TEXT, publisherNumber TEXT, coverUrl TEXT);
            CREATE TABLE composers (shortName TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, born TEXT, died TEXT);
            CREATE TABLE eg_songs (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ix INTEGER NOT NULL, ixUr INTEGER NOT NULL,
                title TEXT NOT NULL, part TEXT NOT NULL, number INTEGER NOT NULL, occasion TEXT);
            CREATE INDEX eg_songs_number ON eg_songs(number);
            CREATE INDEX eg_songs_ix ON eg_songs(ix);
            CREATE TABLE eg_appendices (code TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
            CREATE VIRTUAL TABLE search_index USING fts4(
                content, norm, label, detail, type, refKey, refNumber,
                notindexed=norm, notindexed=label, notindexed=detail, notindexed=type,
                notindexed=refKey, notindexed=refNumber);
            CREATE TABLE sync_state (
                id INTEGER PRIMARY KEY NOT NULL, lastBookNumber INTEGER, lastComposerNumber INTEGER,
                lastTitleNumber INTEGER, checkedAtMillis INTEGER NOT NULL, fullSyncAtMillis INTEGER,
                bookChangeCounter INTEGER, composerChangeCounter INTEGER, titleChangeCounter INTEGER);
            CREATE TABLE fundstellen (
                queryKey TEXT NOT NULL, position INTEGER NOT NULL, bookId TEXT NOT NULL,
                bookTitle TEXT NOT NULL, bookSubtitle TEXT, number TEXT NOT NULL, title TEXT NOT NULL,
                titleNorm TEXT NOT NULL, addition TEXT, composer TEXT, scoring TEXT, keySignature TEXT,
                coverUrl TEXT, PRIMARY KEY (queryKey, position));
            CREATE INDEX fundstellen_titleNorm ON fundstellen(titleNorm);
            CREATE TABLE fetch_state (queryKey TEXT PRIMARY KEY NOT NULL, fetchedAtMillis INTEGER NOT NULL, titleVersion INTEGER);
            """)
        connection.clearStatementCache()
        connection.userVersion = Self.schemaVersion
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

// MARK: - Suche

extension AppDatabase {

    /// Treffer eines Typs, sortiert nach: exakter Treffer, Präfix-Treffer, Rest. Innerhalb
    /// der Gruppen kürzere Labels zuerst.
    func search(match: String, type: SearchEntryType, norm: String, limit: Int) throws -> [SearchHit] {
        try read { db in
            try db.rows("""
                SELECT label, detail, type, refKey, refNumber FROM search_index
                WHERE search_index MATCH ? AND type = ?
                ORDER BY CASE WHEN norm = ? THEN 0 WHEN norm LIKE ? THEN 1 ELSE 2 END,
                         length(norm), norm
                LIMIT ?
                """,
                [.text(match), .int(type.rawValue), .text(norm), .text(norm + "%"), .int(limit)],
                map: Self.searchHit)
        }
    }

    /// EG-Lieder mit dieser Nummer in irgendeinem Teil (Stammteil oder Anhang).
    func egSongsByNumber(_ number: Int) throws -> [SearchHit] {
        try read { db in
            try db.rows("""
                SELECT label, detail, type, refKey, refNumber FROM search_index
                WHERE type = 0 AND refKey IN (SELECT CAST(ix AS TEXT) FROM eg_songs WHERE number = ?)
                """,
                [.int(number)],
                map: Self.searchHit)
        }
    }

    private static func searchHit(_ row: SQLiteConnection.Row) -> SearchHit {
        SearchHit(
            label: row.text(0),
            detail: row.textOrNil(1),
            type: SearchEntryType(rawValue: row.int(2)) ?? .title,
            refKey: row.text(3),
            refNumber: row.intOrNil(4)
        )
    }

    static func deleteSearchEntries(_ db: SQLiteConnection, type: SearchEntryType) throws {
        try db.run("DELETE FROM search_index WHERE type = ?", [.int(type.rawValue)])
    }

    static func insertSearchEntries(_ db: SQLiteConnection, _ entries: [SearchEntry]) throws {
        for entry in entries {
            try db.run(
                "INSERT INTO search_index (content, norm, label, detail, type, refKey, refNumber) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(entry.content), .text(entry.norm), .text(entry.label), SQLValue(entry.detail),
                 .int(entry.type.rawValue), .text(entry.refKey), SQLValue(entry.refNumber)]
            )
        }
    }
}

// MARK: - Stammdaten

extension AppDatabase {

    func books() throws -> [BookEntity] {
        try read { db in
            try db.rows("SELECT * FROM books ORDER BY year IS NULL, year DESC, title", map: Self.book)
        }
    }

    func book(id: String) throws -> BookEntity? {
        try read { db in try db.rows("SELECT * FROM books WHERE id = ?", [.text(id)], map: Self.book).first }
    }

    func bookIds() throws -> [String] {
        try read { db in try db.rows("SELECT id FROM books") { $0.text(0) } }
    }

    private static func book(_ row: SQLiteConnection.Row) -> BookEntity {
        BookEntity(
            id: row.text(0), title: row.text(1), subtitle: row.textOrNil(2), year: row.intOrNil(3),
            editor: row.textOrNil(4), publisher: row.textOrNil(5), publisherNumber: row.textOrNil(6),
            coverUrl: row.textOrNil(7)
        )
    }

    func composers(names: [String]) throws -> [ComposerEntity] {
        if names.isEmpty { return [] }
        return try read { db in
            try db.rows(
                "/*dyn*/ SELECT shortName, name, born, died FROM composers WHERE name IN (\(placeholders(names.count)))",
                names.map { .text($0) }
            ) {
                ComposerEntity(shortName: $0.text(0), name: $0.text(1), born: $0.textOrNil(2), died: $0.textOrNil(3))
            }
        }
    }

    func egAppendices() throws -> [EgAppendixEntity] {
        try read { db in
            try db.rows("SELECT code, name FROM eg_appendices ORDER BY name") {
                EgAppendixEntity(code: $0.text(0), name: $0.text(1))
            }
        }
    }

    func egSongs(ixs: [Int]) throws -> [EgSongEntity] {
        if ixs.isEmpty { return [] }
        return try read { db in
            try db.rows(
                "/*dyn*/ SELECT ix, ixUr, title, part, number, occasion FROM eg_songs WHERE ix IN (\(placeholders(ixs.count)))",
                ixs.map { .int($0) },
                map: Self.egSong
            )
        }
    }

    /// Lieder aus dem Stammteil und dem Anhang `appendix`, nach Nummer. Teil-Kürzel ohne
    /// Groß-/Kleinschreibung, die API schreibt "Ol" und "OL".
    func hymnalSongs(appendix: String?) throws -> [EgSongEntity] {
        try read { db in
            try db.rows(
                "SELECT ix, ixUr, title, part, number, occasion FROM eg_songs WHERE part = 'Stamm' OR part = ? COLLATE NOCASE ORDER BY number, title",
                [SQLValue(appendix)],
                map: Self.egSong
            )
        }
    }

    private static func egSong(_ row: SQLiteConnection.Row) -> EgSongEntity {
        EgSongEntity(ix: row.int(0), ixUr: row.int(1), title: row.text(2), part: row.text(3), number: row.int(4), occasion: row.textOrNil(5))
    }

    func syncState() throws -> SyncState? {
        try read { db in
            try db.rows("""
                SELECT lastBookNumber, lastComposerNumber, lastTitleNumber, checkedAtMillis, fullSyncAtMillis,
                       bookChangeCounter, composerChangeCounter, titleChangeCounter
                FROM sync_state WHERE id = 0
                """) {
                SyncState(
                    lastBookNumber: $0.intOrNil(0), lastComposerNumber: $0.intOrNil(1), lastTitleNumber: $0.intOrNil(2),
                    checkedAtMillis: $0.int(3), fullSyncAtMillis: $0.intOrNil(4),
                    bookChangeCounter: $0.intOrNil(5), composerChangeCounter: $0.intOrNil(6), titleChangeCounter: $0.intOrNil(7)
                )
            }.first
        }
    }

    static func replaceBooks(_ db: SQLiteConnection, _ books: [BookEntity]) throws {
        try db.run("DELETE FROM books")
        for b in books {
            try db.run(
                "INSERT INTO books (id, title, subtitle, year, editor, publisher, publisherNumber, coverUrl) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(b.id), .text(b.title), SQLValue(b.subtitle), SQLValue(b.year), SQLValue(b.editor),
                 SQLValue(b.publisher), SQLValue(b.publisherNumber), SQLValue(b.coverUrl)]
            )
        }
    }

    static func replaceComposers(_ db: SQLiteConnection, _ composers: [ComposerEntity]) throws {
        try db.run("DELETE FROM composers")
        for c in composers {
            // INSERT OR REPLACE: Die API liefert Kurznamen nicht garantiert eindeutig
            try db.run(
                "INSERT OR REPLACE INTO composers (shortName, name, born, died) VALUES (?, ?, ?, ?)",
                [.text(c.shortName), .text(c.name), SQLValue(c.born), SQLValue(c.died)]
            )
        }
    }

    static func replaceEgSongs(_ db: SQLiteConnection, _ songs: [EgSongEntity]) throws {
        try db.run("DELETE FROM eg_songs")
        for s in songs {
            try db.run(
                "INSERT INTO eg_songs (ix, ixUr, title, part, number, occasion) VALUES (?, ?, ?, ?, ?, ?)",
                [.int(s.ix), .int(s.ixUr), .text(s.title), .text(s.part), .int(s.number), SQLValue(s.occasion)]
            )
        }
    }

    static func replaceEgAppendices(_ db: SQLiteConnection, _ appendices: [EgAppendixEntity]) throws {
        try db.run("DELETE FROM eg_appendices")
        for a in appendices {
            try db.run("INSERT OR REPLACE INTO eg_appendices (code, name) VALUES (?, ?)", [.text(a.code), .text(a.name)])
        }
    }

    static func upsertSyncState(_ db: SQLiteConnection, _ s: SyncState) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO sync_state (id, lastBookNumber, lastComposerNumber, lastTitleNumber, checkedAtMillis,
                                               fullSyncAtMillis, bookChangeCounter, composerChangeCounter, titleChangeCounter)
            VALUES (0, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [SQLValue(s.lastBookNumber), SQLValue(s.lastComposerNumber), SQLValue(s.lastTitleNumber),
             .int(s.checkedAtMillis), SQLValue(s.fullSyncAtMillis),
             SQLValue(s.bookChangeCounter), SQLValue(s.composerChangeCounter), SQLValue(s.titleChangeCounter)]
        )
    }
}

// MARK: - Fundstellen

extension AppDatabase {

    func fundstellen(queryKey: String) throws -> [FundstelleEntity] {
        try read { db in
            try db.rows("SELECT * FROM fundstellen WHERE queryKey = ? ORDER BY position", [.text(queryKey)], map: Self.fundstelle)
        }
    }

    func fetchState(queryKey: String) throws -> FetchState? {
        try read { db in
            try db.rows("SELECT queryKey, fetchedAtMillis, titleVersion FROM fetch_state WHERE queryKey = ?", [.text(queryKey)]) {
                FetchState(queryKey: $0.text(0), fetchedAtMillis: $0.int(1), titleVersion: $0.intOrNil(2))
            }.first
        }
    }

    /// Fundstellen aus den Abfragen `queryKeys` (z. B. "book:…"), deren normalisierter Titel in `titleNorms` liegt.
    func ownedHits(queryKeys: [String], titleNorms: [String]) throws -> [OwnedHit] {
        if queryKeys.isEmpty || titleNorms.isEmpty { return [] }
        return try read { db in
            try db.rows("""
                /*dyn*/ SELECT titleNorm, bookId, bookTitle, number FROM fundstellen
                WHERE queryKey IN (\(placeholders(queryKeys.count))) AND titleNorm IN (\(placeholders(titleNorms.count)))
                ORDER BY bookTitle, position
                """,
                queryKeys.map { .text($0) } + titleNorms.map { .text($0) }
            ) {
                OwnedHit(titleNorm: $0.text(0), bookId: $0.text(1), bookTitle: $0.text(2), number: $0.text(3))
            }
        }
    }

    /// Welche der `queryKeys` schon einmal erfolgreich geladen wurden.
    func fetchedKeys(_ queryKeys: [String]) throws -> [String] {
        if queryKeys.isEmpty { return [] }
        return try read { db in
            try db.rows(
                "/*dyn*/ SELECT queryKey FROM fetch_state WHERE queryKey IN (\(placeholders(queryKeys.count)))",
                queryKeys.map { .text($0) }
            ) { $0.text(0) }
        }
    }

    static func replaceFundstellen(_ db: SQLiteConnection, queryKey: String, _ items: [FundstelleEntity], state: FetchState) throws {
        try db.run("DELETE FROM fundstellen WHERE queryKey = ?", [.text(queryKey)])
        for f in items {
            try db.run(
                """
                INSERT INTO fundstellen (queryKey, position, bookId, bookTitle, bookSubtitle, number, title, titleNorm,
                                         addition, composer, scoring, keySignature, coverUrl)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(f.queryKey), .int(f.position), .text(f.bookId), .text(f.bookTitle), SQLValue(f.bookSubtitle),
                 .text(f.number), .text(f.title), .text(f.titleNorm), SQLValue(f.addition), SQLValue(f.composer),
                 SQLValue(f.scoring), SQLValue(f.keySignature), SQLValue(f.coverUrl)]
            )
        }
        try db.run(
            "INSERT OR REPLACE INTO fetch_state (queryKey, fetchedAtMillis, titleVersion) VALUES (?, ?, ?)",
            [.text(state.queryKey), .int(state.fetchedAtMillis), SQLValue(state.titleVersion)]
        )
    }

    private static func fundstelle(_ row: SQLiteConnection.Row) -> FundstelleEntity {
        FundstelleEntity(
            queryKey: row.text(0), position: row.int(1), bookId: row.text(2), bookTitle: row.text(3),
            bookSubtitle: row.textOrNil(4), number: row.text(5), title: row.text(6), titleNorm: row.text(7),
            addition: row.textOrNil(8), composer: row.textOrNil(9), scoring: row.textOrNil(10),
            keySignature: row.textOrNil(11), coverUrl: row.textOrNil(12)
        )
    }
}
