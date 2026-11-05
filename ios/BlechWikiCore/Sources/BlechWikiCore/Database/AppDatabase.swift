import Foundation
import SQLite3

/// Lokale Datenbank. Enthält nur Daten, die sich jederzeit neu vom Server laden lassen oder in
/// der App mitgeliefert sind (Fundstellen). Deshalb bei Schemawechsel Neuaufbau statt Migration,
/// wie bei der Android-App. Inventar und Landeskirche liegen in den Einstellungen und bleiben.
///
/// Threadsicher: Schreiben und Lesen haben je eine Verbindung unter eigener Sperre. Die Abfragen
/// sind klein (Millisekunden), nur der Stammdaten-Abgleich schreibt größere Mengen und hält die
/// Schreibsperre dabei mehrere Sekunden. Dank WAL lesen die Models auf dem Main Thread währenddessen
/// den alten Stand, statt zu warten.
public final class AppDatabase: @unchecked Sendable {

    private static let schemaVersion = 5

    private let lock = NSLock()
    private let connection: SQLiteConnection
    /// Nur lesend, mit eigenem Statement-Cache. `nil` bei der Datenbank im Speicher, die jede
    /// Verbindung für sich hätte. Dann liest `connection`.
    private let reader: SQLiteConnection?
    private let readLock = NSLock()
    private let url: URL?
    let changes: DataChanges

    /// `url` = nil: Datenbank im Speicher, für Tests und als letzter Ausweg beim Start.
    /// Wirft, wenn ein früherer Zugriff die Datei als beschädigt erkannt hat. Dann
    /// `SharedStorage.removeDatabase()` aufrufen und neu öffnen.
    public init(url: URL?, changes: DataChanges = DataChanges()) throws {
        if let url, FileManager.default.fileExists(atPath: Self.corruptionMarker(url).path) {
            throw SQLiteConnection.Error(description: "Datenbank als beschädigt markiert", code: SQLITE_CORRUPT)
        }
        let connection = try SQLiteConnection(path: url?.path)
        try connection.execute("PRAGMA journal_mode = WAL")
        // Version 3: REST statt SOAP, neue Schlüssel für Titel, Bücher und Komponisten
        // Version 4: neue Normalisierung (ø, æ, Ligaturen)
        // Version 5: alle Fundstellen lokal statt Cache pro Abfrage, ohne Titel-Tabelle. Nach dem
        // Update kommen Bücher, Komponisten und EG neu (ca. 1 MB), die Fundstellen aus der App.
        if try connection.userVersion() != Self.schemaVersion {
            // App und Share Extension öffnen nach einem Update womöglich gleichzeitig. Die
            // Transaktion lässt die zweite warten, danach findet sie das neue Schema vor.
            try connection.transaction {
                if try connection.userVersion() != Self.schemaVersion { try Self.recreateSchema(connection) }
            }
        }
        // Erst nach einem Neuaufbau öffnen, sonst verwiese ihr Statement-Cache auf alte Tabellen
        reader = try url.map { try SQLiteConnection(path: $0.path, readOnly: true) }
        self.connection = connection
        self.url = url
        self.changes = changes
    }

    /// Erkennt den Fehler einer beschädigten Datei, wie ihn `init` oder ein Zugriff wirft. Nur dann
    /// hilft Löschen und neu Laden. Andere Fehler (Datei gesperrt, Speicher voll) liegen nicht an der
    /// Datei, Löschen verlöre dort nur den Cache.
    public static func isCorruption(_ error: Swift.Error) -> Bool {
        (error as? SQLiteConnection.Error)?.isCorruption ?? false
    }

    /// Bricht eine laufende Schreibtransaktion ab, z. B. wenn die Zeit im Hintergrund abläuft. Sie
    /// wird zurückgerollt, der Abgleich scheitert und läuft beim nächsten Start erneut. Aus jedem
    /// Thread aufrufbar.
    public func interrupt() {
        connection.interrupt()
    }

    private static func recreateSchema(_ connection: SQLiteConnection) throws {
        let existing = try connection.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'search_index_%'") { $0.text(0) }
        for table in existing { try connection.execute("DROP TABLE IF EXISTS \"\(table)\"") }
        try connection.execute("""
            CREATE TABLE books (
                id TEXT PRIMARY KEY NOT NULL, shortName TEXT NOT NULL COLLATE NOCASE, title TEXT NOT NULL,
                subtitle TEXT, year INTEGER, editor TEXT, publisher TEXT, publisherNumber TEXT, coverUrl TEXT);
            CREATE INDEX books_shortName ON books(shortName);
            CREATE TABLE composers (
                id TEXT PRIMARY KEY NOT NULL, shortName TEXT COLLATE NOCASE, name TEXT NOT NULL, born TEXT, died TEXT);
            CREATE INDEX composers_shortName ON composers(shortName);
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
                id INTEGER PRIMARY KEY NOT NULL, bookChangeCounter INTEGER, composerChangeCounter INTEGER,
                pieceCounter INTEGER, checkedAtMillis INTEGER NOT NULL, fullSyncAtMillis INTEGER,
                piecesCheckedAtMillis INTEGER, importedSnapshot TEXT);
            CREATE TABLE pieces (
                counter INTEGER PRIMARY KEY NOT NULL, bookShortName TEXT NOT NULL COLLATE NOCASE,
                number TEXT NOT NULL, title TEXT NOT NULL, titleNorm TEXT NOT NULL, addition TEXT,
                keySignature TEXT, egIx INTEGER, scoring TEXT, composerShortName TEXT COLLATE NOCASE,
                composerShortName2 TEXT COLLATE NOCASE);
            CREATE INDEX pieces_bookShortName ON pieces(bookShortName);
            CREATE INDEX pieces_titleNorm ON pieces(titleNorm);
            CREATE INDEX pieces_egIx ON pieces(egIx);
            CREATE INDEX pieces_composerShortName ON pieces(composerShortName);
            CREATE INDEX pieces_composerShortName2 ON pieces(composerShortName2);
            CREATE TABLE book_checks (bookId TEXT PRIMARY KEY NOT NULL, checkedAtMillis INTEGER NOT NULL);
            """)
        connection.clearStatementCache()
        try connection.setUserVersion(Self.schemaVersion)
    }

    /// Liest über die eigene Verbindung, ohne auf eine laufende Schreibtransaktion zu warten.
    /// Innerhalb von `write` nicht aufrufen, sondern die dort übergebene Verbindung nutzen. `read`
    /// sähe den Stand vor der Transaktion.
    func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        guard let reader else {
            lock.lock()
            defer { lock.unlock() }
            return try markingCorruption { try body(connection) }
        }
        readLock.lock()
        defer { readLock.unlock() }
        return try markingCorruption { try body(reader) }
    }

    /// Schreibt in einer Transaktion und meldet danach die Änderung.
    func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let result: T = try {
            lock.lock()
            defer { lock.unlock() }
            return try markingCorruption { try connection.transaction { try body(connection) } }
        }()
        changes.notify()
        return result
    }

    /// Ist die Datei beschädigt, scheitert jeder weitere Abgleich. Eine Markierung neben der Datei
    /// sorgt dafür, dass sie beim nächsten Start verworfen und neu geladen wird.
    private func markingCorruption<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SQLiteConnection.Error where error.isCorruption {
            if let url { FileManager.default.createFile(atPath: Self.corruptionMarker(url).path, contents: nil) }
            throw error
        }
    }

    static func corruptionMarker(_ url: URL) -> URL {
        url.appendingPathExtension("corrupt")
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

    /// EG-Lieder mit dieser Nummer in irgendeinem Teil (Stammteil oder Anhang). Die Nummern der
    /// Ergänzungen ("Add") sind keine EG-Nummern.
    func egSongsByNumber(_ number: Int) throws -> [SearchHit] {
        try read { db in
            try db.rows("""
                SELECT label, detail, type, refKey, refNumber FROM search_index
                WHERE type = 0 AND refKey IN (SELECT CAST(ix AS TEXT) FROM eg_songs WHERE number = ? AND part <> 'Add')
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
            try db.rows("SELECT \(Self.bookColumns) FROM books ORDER BY year IS NULL, year DESC, title", map: Self.book)
        }
    }

    func book(id: String) throws -> BookEntity? {
        try read { db in try db.rows("SELECT \(Self.bookColumns) FROM books WHERE id = ?", [.text(id)], map: Self.book).first }
    }

    func bookIds() throws -> [String] {
        try read { db in try db.rows("SELECT id FROM books") { $0.text(0) } }
    }

    func books(ids: [String]) throws -> [BookEntity] {
        if ids.isEmpty { return [] }
        return try read { db in
            try db.rows("/*dyn*/ SELECT \(Self.bookColumns) FROM books WHERE id IN (\(placeholders(ids.count)))", ids.map { .text($0) }, map: Self.book)
        }
    }

    func allEgSongs() throws -> [EgSongEntity] {
        try read { db in try db.rows("SELECT ix, ixUr, title, part, number, occasion FROM eg_songs", map: Self.egSong) }
    }

    private static let bookColumns = "id, shortName, title, subtitle, year, editor, publisher, publisherNumber, coverUrl"

    private static func book(_ row: SQLiteConnection.Row) -> BookEntity {
        BookEntity(
            id: row.text(0), shortName: row.text(1), title: row.text(2), subtitle: row.textOrNil(3), year: row.intOrNil(4),
            editor: row.textOrNil(5), publisher: row.textOrNil(6), publisherNumber: row.textOrNil(7),
            coverUrl: row.textOrNil(8)
        )
    }

    func composers(names: [String]) throws -> [ComposerEntity] {
        if names.isEmpty { return [] }
        return try read { db in
            try db.rows(
                "/*dyn*/ SELECT id, shortName, name, born, died FROM composers WHERE name IN (\(placeholders(names.count)))",
                names.map { .text($0) }
            ) {
                ComposerEntity(id: $0.text(0), shortName: $0.textOrNil(1), name: $0.text(2), born: $0.textOrNil(3), died: $0.textOrNil(4))
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
            try Self.syncState(db)
        }
    }

    /// Wie `syncState()`, aber über die Verbindung einer laufenden Schreibtransaktion.
    static func syncState(_ db: SQLiteConnection) throws -> SyncState? {
        try db.rows("""
            SELECT bookChangeCounter, composerChangeCounter, pieceCounter, checkedAtMillis, fullSyncAtMillis,
                   piecesCheckedAtMillis, importedSnapshot
            FROM sync_state WHERE id = 0
            """) {
            SyncState(
                bookChangeCounter: $0.intOrNil(0), composerChangeCounter: $0.intOrNil(1), pieceCounter: $0.intOrNil(2),
                checkedAtMillis: $0.int(3), fullSyncAtMillis: $0.intOrNil(4), piecesCheckedAtMillis: $0.intOrNil(5),
                importedSnapshot: $0.textOrNil(6)
            )
        }.first
    }

    /// Wie `allEgSongs()`, aber über die Verbindung einer laufenden Schreibtransaktion.
    static func allEgSongs(_ db: SQLiteConnection) throws -> [EgSongEntity] {
        try db.rows("SELECT ix, ixUr, title, part, number, occasion FROM eg_songs", map: Self.egSong)
    }

    static func deleteBooks(_ db: SQLiteConnection, ids: [String]? = nil) throws {
        guard let ids else { return try db.run("DELETE FROM books") }
        for id in ids { try db.run("DELETE FROM books WHERE id = ?", [.text(id)]) }
    }

    static func upsertBooks(_ db: SQLiteConnection, _ books: [BookEntity]) throws {
        for b in books {
            try db.run(
                "INSERT OR REPLACE INTO books (\(bookColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(b.id), .text(b.shortName), .text(b.title), SQLValue(b.subtitle), SQLValue(b.year), SQLValue(b.editor),
                 SQLValue(b.publisher), SQLValue(b.publisherNumber), SQLValue(b.coverUrl)]
            )
        }
    }

    static func replaceComposers(_ db: SQLiteConnection, _ composers: [ComposerEntity]) throws {
        try db.run("DELETE FROM composers")
        for c in composers {
            try db.run(
                "INSERT OR REPLACE INTO composers (id, shortName, name, born, died) VALUES (?, ?, ?, ?, ?)",
                [.text(c.id), SQLValue(c.shortName), .text(c.name), SQLValue(c.born), SQLValue(c.died)]
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
            INSERT OR REPLACE INTO sync_state (id, bookChangeCounter, composerChangeCounter, pieceCounter,
                                               checkedAtMillis, fullSyncAtMillis, piecesCheckedAtMillis, importedSnapshot)
            VALUES (0, ?, ?, ?, ?, ?, ?, ?)
            """,
            [SQLValue(s.bookChangeCounter), SQLValue(s.composerChangeCounter), SQLValue(s.pieceCounter),
             .int(s.checkedAtMillis), SQLValue(s.fullSyncAtMillis), SQLValue(s.piecesCheckedAtMillis), SQLValue(s.importedSnapshot)]
        )
    }
}

// MARK: - Fundstellen

extension AppDatabase {

    /// Fundstellen ohne Buch im Verzeichnis (EG-Anhänge, private Sammlungen) fallen durch den Join weg.
    private static let pieceSelect = """
        SELECT p.counter, b.id, b.title, b.subtitle, b.coverUrl, p.number, p.title, p.addition, p.keySignature,
               p.scoring, p.composerShortName, p.composerShortName2, c1.name, c2.name
        FROM pieces p
        JOIN books b ON b.shortName = p.bookShortName
        LEFT JOIN composers c1 ON c1.shortName = p.composerShortName
        LEFT JOIN composers c2 ON c2.shortName = p.composerShortName2
        """

    /// Neueste Bücher zuerst, im Buch nach Nummer ("4", "12", "12a").
    private static let pieceOrder = """
        ORDER BY b.year IS NULL, b.year DESC, b.title, b.id, CAST(p.number AS INTEGER), p.number, p.counter
        """

    func pieces(_ query: FundstellenQuery) throws -> [PieceRow] {
        let (filter, args): (String, [SQLValue]) = switch query {
        case .byBook(let id): ("b.id = ?", [.text(id)])
        // Alle Sätze zur Melodie, auch unter anderem Liedtext
        case .byEgMelody(let ixUr): ("p.egIx IN (SELECT ix FROM eg_songs WHERE ixUr = ?)", [.int(ixUr)])
        case .byTitle(let titleNorm): ("p.titleNorm = ?", [.text(titleNorm)])
        // Als erster oder zweiter Komponist
        case .byComposer(let id):
            ("""
             p.composerShortName IN (SELECT shortName FROM composers WHERE id = ?)
             OR p.composerShortName2 IN (SELECT shortName FROM composers WHERE id = ?)
             """, [.text(id), .text(id)])
        }
        return try read { db in
            try db.rows("\(Self.pieceSelect) WHERE \(filter) \(Self.pieceOrder)", args, map: Self.pieceRow)
        }
    }

    /// Stücke mit der Nummer `number` im Buch `bookId`, für Fundstellen in Listen. Vergleicht ohne
    /// Leerraum am Rand, wie der Schlüssel der Liste (`ListEntryKey`).
    func pieces(bookId: String, number: String) throws -> [PieceRow] {
        try read { db in
            try db.rows("\(Self.pieceSelect) WHERE b.id = ? AND TRIM(p.number) = ? \(Self.pieceOrder)",
                        [.text(bookId), .text(number.trimmingCharacters(in: .whitespaces))], map: Self.pieceRow)
        }
    }

    private static func pieceRow(_ row: SQLiteConnection.Row) -> PieceRow {
        PieceRow(
            counter: row.int(0), bookId: row.text(1), bookTitle: row.text(2), bookSubtitle: row.textOrNil(3),
            coverUrl: row.textOrNil(4), number: row.text(5), title: row.text(6), addition: row.textOrNil(7),
            keySignature: row.textOrNil(8), scoring: row.textOrNil(9), composerShortName: row.textOrNil(10),
            composerShortName2: row.textOrNil(11), composerName: row.textOrNil(12), composerName2: row.textOrNil(13)
        )
    }

    /// Zahl der Bücher im Verzeichnis je normalisiertem Titel, für „In 7 Büchern“ in Listen.
    func bookCounts(titleNorms: [String]) throws -> [String: Int] {
        if titleNorms.isEmpty { return [:] }
        return try read { db in
            let rows = try db.rows("""
                /*dyn*/ SELECT p.titleNorm, COUNT(DISTINCT b.id) FROM pieces p
                JOIN books b ON b.shortName = p.bookShortName
                WHERE p.titleNorm IN (\(placeholders(titleNorms.count)))
                GROUP BY p.titleNorm
                """,
                titleNorms.map { .text($0) }
            ) { ($0.text(0), $0.int(1)) }
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Stücke mit einem der `titleNorms` in den Büchern `bookIds`.
    func ownedHits(bookIds: [String], titleNorms: [String]) throws -> [OwnedHit] {
        if bookIds.isEmpty || titleNorms.isEmpty { return [] }
        return try read { db in
            try db.rows("""
                /*dyn*/ SELECT p.titleNorm, b.id, b.title, p.number FROM pieces p
                JOIN books b ON b.shortName = p.bookShortName
                WHERE b.id IN (\(placeholders(bookIds.count))) AND p.titleNorm IN (\(placeholders(titleNorms.count)))
                ORDER BY b.title, CAST(p.number AS INTEGER), p.number
                """,
                bookIds.map { .text($0) } + titleNorms.map { .text($0) }
            ) {
                OwnedHit(titleNorm: $0.text(0), bookId: $0.text(1), bookTitle: $0.text(2), number: $0.text(3))
            }
        }
    }

    /// Sätze zu den Melodien `ixUrs` in den Büchern `bookIds`.
    func ownedMelodyHits(bookIds: [String], ixUrs: [Int]) throws -> [OwnedMelodyHit] {
        if bookIds.isEmpty || ixUrs.isEmpty { return [] }
        return try read { db in
            try db.rows("""
                /*dyn*/ SELECT e.ixUr, b.id, b.title, p.number FROM pieces p
                JOIN books b ON b.shortName = p.bookShortName
                JOIN (SELECT DISTINCT ix, ixUr FROM eg_songs) e ON e.ix = p.egIx
                WHERE b.id IN (\(placeholders(bookIds.count))) AND e.ixUr IN (\(placeholders(ixUrs.count)))
                ORDER BY b.title, CAST(p.number AS INTEGER), p.number
                """,
                bookIds.map { .text($0) } + ixUrs.map { .int($0) }
            ) {
                OwnedMelodyHit(ixUr: $0.int(0), bookId: $0.text(1), bookTitle: $0.text(2), number: $0.text(3))
            }
        }
    }

    func countersOfBook(_ bookId: String) throws -> [Int] {
        try read { db in
            try db.rows(
                "SELECT p.counter FROM pieces p JOIN books b ON b.shortName = p.bookShortName WHERE b.id = ?",
                [.text(bookId)]
            ) { $0.int(0) }
        }
    }

    func bookCheckedAtMillis(_ bookId: String) throws -> Int? {
        try read { db in
            try db.rows("SELECT checkedAtMillis FROM book_checks WHERE bookId = ?", [.text(bookId)]) { $0.int(0) }.first
        }
    }

    /// Titel aller Fundstellen in Büchern des Verzeichnisses, mit Doppeln, für den Suchindex.
    static func pieceTitles(_ db: SQLiteConnection) throws -> [String] {
        try db.rows("SELECT p.title FROM pieces p JOIN books b ON b.shortName = p.bookShortName") { $0.text(0) }
    }

    static func deleteAllPieces(_ db: SQLiteConnection) throws {
        try db.run("DELETE FROM pieces")
    }

    static func deletePieces(_ db: SQLiteConnection, counters: [Int]) throws {
        for counter in counters { try db.run("DELETE FROM pieces WHERE counter = ?", [.int(counter)]) }
    }

    /// Korrigierte Zeilen bekommen einen neuen Zähler, ersetzt wird nur bei gleichem Zähler.
    static func upsertPieces(_ db: SQLiteConnection, _ pieces: [PieceEntity]) throws {
        for p in pieces {
            try db.run(
                """
                INSERT OR REPLACE INTO pieces (counter, bookShortName, number, title, titleNorm, addition, keySignature,
                                               egIx, scoring, composerShortName, composerShortName2)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.int(p.counter), .text(p.bookShortName), .text(p.number), .text(p.title), .text(p.titleNorm),
                 SQLValue(p.addition), SQLValue(p.keySignature), SQLValue(p.egIx), SQLValue(p.scoring),
                 SQLValue(p.composerShortName), SQLValue(p.composerShortName2)]
            )
        }
    }

    static func upsertBookCheck(_ db: SQLiteConnection, bookId: String, checkedAtMillis: Int) throws {
        try db.run("INSERT OR REPLACE INTO book_checks (bookId, checkedAtMillis) VALUES (?, ?)", [.text(bookId), .int(checkedAtMillis)])
    }

    static func deleteBookChecks(_ db: SQLiteConnection) throws {
        try db.run("DELETE FROM book_checks")
    }
}
