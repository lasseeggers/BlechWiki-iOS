import Foundation

/// Lädt Bücher, Komponisten, EG-Lieder und Fundstellen in die lokale Datenbank.
///
/// Fundstellen: Die App bringt einen Stand mit (`PieceSnapshot`). Ist er neuer als der zuletzt
/// importierte (erster Start, Update), ersetzt er alle Fundstellen, ohne Netz. Danach fragt jeder
/// Abgleich nur die Zeilen mit höherem Zähler ab (neue Bücher, Korrekturen), meist `[]`. Löschungen
/// meldet der Server nicht, die findet `FundstellenRepository` pro Buch. Ohne mitgelieferten Stand
/// oder mit `reloadAll` kommen alle Fundstellen vom Server (ca. 7,5 MB).
///
/// Stammdaten: Liegt der letzte Check weniger als `checkInterval` zurück, passiert nichts. Sonst
/// fragt der Abgleich je Tabelle die Änderungen seit dem gespeicherten Zähler ab (2 Byte, wenn
/// nichts passiert ist). Bücher werden einzeln ergänzt, geändert oder gelöscht. Komponisten werden
/// bei jeder Änderung ganz neu geladen (ca. 480 KB): Schreibvarianten eines Namens haben dieselbe
/// id, eine Änderung lässt sich nicht eindeutig einem Eintrag zuordnen.
///
/// Der erste Abgleich lädt Bücher, Komponisten und EG ganz (ca. 1 MB), ebenso ein Aufruf mit
/// `fullRefreshIfDue` alle `fullRefreshInterval`. Die EG-Lieder haben keinen Änderungszähler und
/// kommen nur bei diesen vollständigen Abgleichen.
///
/// Alles wird in einer Transaktion geschrieben: Bricht der Abgleich ab, bleibt der alte Stand
/// vollständig erhalten. Abgleiche laufen nie parallel. Ein zweiter Aufruf wartet auf den
/// laufenden und sieht danach den frischen Stand. Der Actor allein reicht dafür nicht, er nimmt
/// an jedem `await` den nächsten Aufruf an.
public actor MasterDataSync {

    public enum Outcome: Equatable, Sendable {
        /// Letzter Check ist jünger als `checkInterval`, kein Request.
        case skipped
        /// Änderungen geprüft. `updated` nennt die geänderten Bereiche, leer wenn alles aktuell war.
        case checked(updated: Set<Section>)
    }

    public enum Section: Sendable { case pieces, books, composers }

    public static let checkInterval: TimeInterval = 24 * 3600
    public static let fullRefreshInterval: TimeInterval = 30 * 24 * 3600
    public static let newPiecesInterval: TimeInterval = 10 * 60

    /// Geladene Zeilen einer Tabelle. `isFull`: ganze Tabelle statt Änderungen.
    private struct Rows<T> {
        var rows: [T]
        var isFull: Bool
        var counter: Int
    }

    private let api: BlechWikiAPI
    private let db: AppDatabase
    private let snapshot: PieceSnapshot
    private let now: @Sendable () -> Date
    private var running: Task<Void, Never>?

    public init(
        api: BlechWikiAPI,
        db: AppDatabase,
        snapshot: PieceSnapshot = NoPieceSnapshot(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.db = db
        self.snapshot = snapshot
        self.now = now
    }

    /// `reloadAll` lädt alles neu vom Server, auch alle Fundstellen (ca. 8,5 MB), für den Befehl
    /// „Alle Daten neu laden“.
    public func sync(force: Bool = false, fullRefreshIfDue: Bool = false, reloadAll: Bool = false) async throws -> Outcome {
        try await exclusive {
            if !reloadAll { try await self.importSnapshotIfNew() }
            return try await self.perform(force: force, fullRefreshIfDue: fullRefreshIfDue, reloadAll: reloadAll)
        }
    }

    /// Nur neue Fundstellen holen (`Titel?titelzaehler=`, meist 2 Byte), z. B. bevor ein Buch
    /// abgeglichen wird. Ohne `force` nicht, wenn das in den letzten `newPiecesInterval` schon passiert ist.
    /// - Returns: `true`, wenn ein Request an den Server ging
    @discardableResult
    public func fetchNewPieces(force: Bool = false) async throws -> Bool {
        try await exclusive { try await self.performFetchNewPieces(force: force) }
    }

    /// Führt `body` aus, sobald kein anderer Abgleich mehr läuft. Der Abgleich läuft in einer
    /// eigenen Task. Ein Abbruch des Aufrufers muss ihn erreichen, sonst wartet ein ersetzender
    /// Abgleich den alten ganz ab.
    private func exclusive<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        while let previous = running {
            await previous.value
            if running == previous { running = nil }
        }
        let task = Task(operation: body)
        let done = Task { _ = try? await task.value }
        running = done
        defer { if running == done { running = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private var nowMillis: Int { Int(now().timeIntervalSince1970 * 1000) }

    private func performFetchNewPieces(force: Bool) async throws -> Bool {
        guard let stored = try db.syncState(), let known = stored.pieceCounter else { return false }
        if !force, let checkedAt = stored.piecesCheckedAtMillis,
           (0..<Int(Self.newPiecesInterval * 1000)).contains(nowMillis - checkedAt) {
            return false
        }
        let pieces = try await api.getPieces(after: known).map(Self.entity)
        try Task.checkCancellation()
        let checkedAt = nowMillis
        try db.write { conn in
            try AppDatabase.upsertPieces(conn, pieces)
            if !pieces.isEmpty { try Self.rebuildTitleIndex(conn) }
            var state = try AppDatabase.syncState(conn) ?? stored
            state.pieceCounter = max(known, pieces.map(\.counter).max() ?? 0)
            state.piecesCheckedAtMillis = checkedAt
            try AppDatabase.upsertSyncState(conn, state)
        }
        return true
    }

    /// Liest den mitgelieferten Stand nur, wenn er sich vom zuletzt importierten unterscheidet.
    private func importSnapshotIfNew() async throws {
        guard let stand = snapshot.stand(), try db.syncState()?.importedSnapshot != stand else { return }
        let pieces = try Self.nonEmpty(snapshot.pieces(), "Mitgelieferte Fundstellen").map(Self.entity)
        let standMillis = ISO8601DateFormatter().date(from: stand).map { Int($0.timeIntervalSince1970 * 1000) } ?? nowMillis
        try Task.checkCancellation()
        try db.write { conn in
            try AppDatabase.deleteAllPieces(conn)
            try AppDatabase.upsertPieces(conn, pieces)
            // Ohne Bücher (erster Start) bleibt der Index leer, der folgende Abgleich baut ihn
            try Self.rebuildTitleIndex(conn)
            // Abgleiche mit Buch/{id} vor dem Stand könnten Zeilen gelöscht haben, die er wieder enthält
            try AppDatabase.deleteBookChecks(conn)
            var state = try AppDatabase.syncState(conn) ?? .empty
            state.pieceCounter = pieces.map(\.counter).max()
            state.piecesCheckedAtMillis = standMillis
            state.importedSnapshot = stand
            try AppDatabase.upsertSyncState(conn, state)
        }
    }

    private func perform(force: Bool, fullRefreshIfDue: Bool, reloadAll: Bool) async throws -> Outcome {
        let stored = try db.syncState()
        let nowMillis = nowMillis
        let lastFullSync = stored?.fullSyncAtMillis
        let fullRefreshDue = fullRefreshIfDue &&
            (lastFullSync.map { nowMillis - $0 >= Int(Self.fullRefreshInterval * 1000) } ?? true)
        if !force, !reloadAll, !fullRefreshDue, let stored, stored.isComplete,
           nowMillis - stored.checkedAtMillis < Int(Self.checkInterval * 1000) {
            return .skipped
        }
        let full = reloadAll || fullRefreshDue || stored?.bookChangeCounter == nil || stored?.composerChangeCounter == nil
        let knownPieces = reloadAll ? nil : stored?.pieceCounter

        // Erst alles laden, dann schreiben, damit ein Netzfehler keinen halben Stand hinterlässt.
        // Nacheinander statt parallel, um den privat betriebenen Server nicht zu belasten.
        let books = try await load(stored?.bookChangeCounter, full: full) { try await api.getBooks(after: $0) }
        var composers = try await load(stored?.composerChangeCounter, full: full) { try await api.getComposers(after: $0) }
        if let changes = composers, !changes.isFull {
            let all = try await api.getComposers(after: 0)
            composers = Rows(rows: try Self.nonEmpty(all.rows, "Komponist"), isFull: true, counter: max(changes.counter, all.maxCounter))
        }
        let egSongs = full ? try await Self.nonEmpty(api.getEgSongs(), "EG").map(Self.entity) : nil
        let egAppendices = full ? try await api.getEgAppendices().map { EgAppendixEntity(code: $0.code, name: $0.name) } : nil
        let pieces: [PieceEntity] = if let knownPieces {
            try await api.getPieces(after: knownPieces).map(Self.entity)
        } else {
            try await Self.nonEmpty(api.getPieces(after: 0), "Fundstellen").map(Self.entity)
        }

        // Neuen Stand und Index vor der Transaktion bauen, damit die Sperre kurz bleibt
        let bookEntities = try books.map { changes in
            try Self.merge(changes, into: changes.isFull ? [] : db.books(), key: \.id, deleted: \.deleted, Self.entity)
        }
        var seenComposers = Set<String>()
        let composerEntities = composers.map { changes in
            Self.withUniqueShortNames(
                changes.rows.filter { !$0.deleted && !$0.isAlias && seenComposers.insert($0.id).inserted }.map(Self.entity)
            )
        }
        let egEntries = egSongs.map(SearchIndexBuilder.egSongEntries)
        let bookEntries = bookEntities.map(SearchIndexBuilder.bookEntries)
        let composerEntries = composerEntities.map(SearchIndexBuilder.composerEntries)

        // Abgebrochen (z. B. ersetzt durch einen neuen Abgleich): nichts mehr schreiben
        try Task.checkCancellation()
        try db.write { conn in
            if let egSongs, let egAppendices, let egEntries {
                try AppDatabase.replaceEgSongs(conn, egSongs)
                try AppDatabase.replaceEgAppendices(conn, egAppendices)
                try AppDatabase.deleteSearchEntries(conn, type: .egSong)
                try AppDatabase.insertSearchEntries(conn, egEntries)
            }
            if let books, let bookEntries {
                try AppDatabase.deleteBooks(conn, ids: books.isFull ? nil : books.rows.filter(\.deleted).map(\.id))
                try AppDatabase.upsertBooks(conn, books.rows.filter { !$0.deleted }.map(Self.entity))
                try AppDatabase.deleteSearchEntries(conn, type: .book)
                try AppDatabase.insertSearchEntries(conn, bookEntries)
            }
            if let composerEntities, let composerEntries {
                try AppDatabase.replaceComposers(conn, composerEntities)
                try AppDatabase.deleteSearchEntries(conn, type: .composer)
                try AppDatabase.insertSearchEntries(conn, composerEntries)
            }
            if reloadAll { try AppDatabase.deleteBookChecks(conn) }
            if knownPieces == nil { try AppDatabase.deleteAllPieces(conn) }
            try AppDatabase.upsertPieces(conn, pieces)
            // Titel nur aus Büchern im Verzeichnis und ohne EG-Lieder, also neu, wenn sich eins davon ändert
            if !pieces.isEmpty || books != nil || egSongs != nil {
                try Self.rebuildTitleIndex(conn)
            } else if composers != nil {
                try AppDatabase.rebuildSearchWeights(conn)
            }
            try AppDatabase.upsertSyncState(conn, SyncState(
                bookChangeCounter: books?.counter ?? stored?.bookChangeCounter,
                composerChangeCounter: composers?.counter ?? stored?.composerChangeCounter,
                pieceCounter: max(knownPieces ?? 0, pieces.map(\.counter).max() ?? 0),
                checkedAtMillis: nowMillis,
                fullSyncAtMillis: full ? nowMillis : lastFullSync,
                piecesCheckedAtMillis: nowMillis,
                importedSnapshot: stored?.importedSnapshot
            ))
        }

        var updated = Set<Section>()
        if !pieces.isEmpty { updated.insert(.pieces) }
        if books != nil { updated.insert(.books) }
        if composers != nil { updated.insert(.composers) }
        return .checked(updated: updated)
    }

    /// Mit den Gewichten, die von denselben Tabellen abhängen. Muss in einer Schreibtransaktion laufen.
    private static func rebuildTitleIndex(_ conn: SQLiteConnection) throws {
        let entries = SearchIndexBuilder.titleEntries(try AppDatabase.pieceTitles(conn), egSongs: try AppDatabase.allEgSongs(conn))
        try AppDatabase.deleteSearchEntries(conn, type: .title)
        try AppDatabase.insertSearchEntries(conn, entries)
        try AppDatabase.rebuildSearchWeights(conn)
    }

    /// Ganze Tabelle bei `full` oder unbekanntem Stand, sonst die Änderungen seit `known`.
    /// `nil`, wenn es keine Änderungen gab. Kamen nur unlesbare Einträge, sind die Zeilen leer,
    /// der Zähler rückt aber vor.
    private func load<T>(
        _ known: Int?,
        full: Bool,
        fetch: (Int) async throws -> TableRows<T>
    ) async throws -> Rows<T>? {
        let after = full ? 0 : (known ?? 0)
        let table = try await fetch(after)
        if after > 0, table.rows.isEmpty, table.maxCounter <= after { return nil }
        // Eine leere ganze Tabelle ist ein Serverfehler. Übernommen wäre das Verzeichnis leer.
        if after == 0 { _ = try Self.nonEmpty(table.rows, "\(T.self)") }
        // Die ganze Tabelle enthält keine gelöschten Einträge, ihr Zähler kann deshalb unter dem
        // bekannten liegen. Sänke er, kämen beim nächsten Abgleich alte Änderungen noch einmal.
        return Rows(rows: table.rows, isFull: after == 0, counter: max(known ?? 0, table.maxCounter))
    }

    private static func nonEmpty<T>(_ rows: [T], _ table: String) throws -> [T] {
        if rows.isEmpty { throw BlechWikiError.malformedResponse("\(table): leere Tabelle") }
        return rows
    }

    /// Stand nach Anwenden der Änderungen auf `current`, für den Suchindex.
    private static func merge<Dto, Entity, Key: Hashable>(
        _ changes: Rows<Dto>,
        into current: [Entity],
        key: KeyPath<Dto, Key>,
        deleted: KeyPath<Dto, Bool>,
        _ entity: (Dto) -> Entity
    ) -> [Entity] where Entity: KeyedEntity, Entity.Key == Key {
        var byKey = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for row in changes.rows {
            byKey[row[keyPath: key]] = row[keyPath: deleted] ? nil : entity(row)
        }
        return Array(byKey.values)
    }

    /// Ein Kurzname gehört zu genau einem Komponisten, sonst erschiene eine Fundstelle doppelt.
    /// Bei Doppeln behält der erste den Kurznamen (Stand 11/2026 keine).
    private static func withUniqueShortNames(_ composers: [ComposerEntity]) -> [ComposerEntity] {
        var seen = Set<String>()
        return composers.map { composer in
            guard let key = composer.shortName?.lowercased(), !seen.insert(key).inserted else { return composer }
            var copy = composer
            copy.shortName = nil
            return copy
        }
    }

    private static func entity(_ dto: EgSongDto) -> EgSongEntity {
        EgSongEntity(ix: dto.ix, ixUr: dto.ixUr, title: dto.title, part: dto.part, number: dto.number, occasion: dto.occasion)
    }

    private static func entity(_ dto: BookDto) -> BookEntity {
        let editor = [dto.editorFirstName, dto.editor].compactMap { $0 }.joined(separator: " ")
        return BookEntity(
            id: dto.id, shortName: dto.shortName, title: dto.title, subtitle: dto.subtitle, year: dto.year,
            editor: editor.isEmpty ? nil : editor, publisher: dto.publisher,
            publisherNumber: dto.publisherNumber, coverUrl: dto.coverUrl
        )
    }

    private static func entity(_ dto: ComposerDto) -> ComposerEntity {
        ComposerEntity(id: dto.id, shortName: dto.shortName, name: dto.name, born: dto.born, died: dto.died)
    }

    private static func entity(_ dto: PieceDto) -> PieceEntity {
        PieceEntity(
            counter: dto.counter, bookShortName: dto.bookShortName, number: dto.number, title: dto.title,
            titleNorm: SearchNormalizer.normalize(dto.title), addition: dto.addition, keySignature: dto.keySignature,
            egIx: dto.egIx, scoring: dto.scoring, composerShortName: dto.composerShortName,
            composerShortName2: dto.composerShortName2
        )
    }
}

/// Stammdaten mit Schlüssel, für `MasterDataSync.merge`.
protocol KeyedEntity {
    associatedtype Key: Hashable
    var key: Key { get }
}

extension BookEntity: KeyedEntity { var key: String { id } }
