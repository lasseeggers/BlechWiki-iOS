import Foundation

/// Lädt Titel, EG-Lieder, Bücher und Komponisten in die lokale Datenbank.
///
/// Ablauf: Liegt der letzte Check weniger als `checkInterval` zurück, passiert nichts. Sonst
/// fragt der Abgleich je Tabelle die Änderungen seit dem gespeicherten Zähler ab (2 Byte, wenn
/// nichts passiert ist). Titel und Bücher werden einzeln ergänzt, geändert oder gelöscht.
/// Komponisten werden bei jeder Änderung ganz neu geladen (ca. 380 KB): Schreibvarianten eines
/// Namens haben dieselbe id, eine Änderung lässt sich nicht eindeutig einem Eintrag zuordnen.
///
/// Der erste Abgleich lädt alles (ca. 2,1 MB), ebenso ein Aufruf mit `fullRefreshIfDue` alle
/// `fullRefreshInterval`. Die EG-Lieder haben keinen Änderungszähler und kommen nur bei diesen
/// vollständigen Abgleichen.
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

    public enum Section: Sendable { case titles, books, composers }

    public static let checkInterval: TimeInterval = 24 * 3600
    public static let fullRefreshInterval: TimeInterval = 30 * 24 * 3600

    /// Geladene Zeilen einer Tabelle. `isFull`: ganze Tabelle statt Änderungen.
    private struct Rows<T> {
        var rows: [T]
        var isFull: Bool
        var counter: Int
    }

    private let api: BlechWikiAPI
    private let db: AppDatabase
    private let now: @Sendable () -> Date
    private var running: Task<Outcome, Error>?

    public init(api: BlechWikiAPI, db: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.db = db
        self.now = now
    }

    public func sync(force: Bool = false, fullRefreshIfDue: Bool = false) async throws -> Outcome {
        while let previous = running {
            _ = try? await previous.value
            if running == previous { running = nil }
        }
        let task = Task { try await perform(force: force, fullRefreshIfDue: fullRefreshIfDue) }
        running = task
        defer { if running == task { running = nil } }
        // Der Abgleich läuft in einer eigenen Task. Ein Abbruch des Aufrufers muss ihn erreichen,
        // sonst wartet ein ersetzender Abgleich den alten ganz ab.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func perform(force: Bool, fullRefreshIfDue: Bool) async throws -> Outcome {
        let stored = try db.syncState()
        let nowMillis = Int(now().timeIntervalSince1970 * 1000)
        let lastFullSync = stored?.fullSyncAtMillis
        let fullRefreshDue = fullRefreshIfDue &&
            (lastFullSync.map { nowMillis - $0 >= Int(Self.fullRefreshInterval * 1000) } ?? true)
        if !force, !fullRefreshDue, let stored, stored.isComplete,
           nowMillis - stored.checkedAtMillis < Int(Self.checkInterval * 1000) {
            return .skipped
        }
        let full = fullRefreshDue || !(stored?.isComplete ?? false)

        // Erst alles laden, dann schreiben, damit ein Netzfehler keinen halben Stand hinterlässt.
        // Nacheinander statt parallel, um den privat betriebenen Server nicht zu belasten.
        let titles = try await load(stored?.titleChangeCounter, full: full) { try await api.getTitles(after: $0) }
        let books = try await load(stored?.bookChangeCounter, full: full) { try await api.getBooks(after: $0) }
        var composers = try await load(stored?.composerChangeCounter, full: full) { try await api.getComposers(after: $0) }
        if let changes = composers, !changes.isFull {
            let all = try await api.getComposers(after: 0)
            composers = Rows(rows: try Self.nonEmpty(all.rows, "Komponist"), isFull: true, counter: max(changes.counter, all.maxCounter))
        }
        let egSongs = full ? try await Self.nonEmpty(api.getEgSongs(), "EG").map(Self.entity) : nil
        let egAppendices = full ? try await api.getEgAppendices().map { EgAppendixEntity(code: $0.code, name: $0.name) } : nil

        // Neuen Stand und Index vor der Transaktion bauen, damit die Sperre kurz bleibt
        let titleEntities = try titles.map { changes in
            try Self.merge(changes, into: changes.isFull ? [] : db.titles(), key: \.ix, deleted: \.deleted) {
                TitleEntity(ix: $0.ix, title: $0.title)
            }
        }
        let bookEntities = try books.map { changes in
            try Self.merge(changes, into: changes.isFull ? [] : db.books(), key: \.id, deleted: \.deleted, Self.entity)
        }
        var seenComposers = Set<String>()
        let composerEntities = composers.map { changes in
            changes.rows.filter { !$0.deleted && !$0.isAlias && seenComposers.insert($0.id).inserted }.map(Self.entity)
        }
        let egEntries = egSongs.map(SearchIndexBuilder.egSongEntries)
        // Titel, die einem EG-Lied entsprechen, stehen nur als EG-Treffer im Index.
        // Neue EG-Lieder kommen nur mit einem vollständigen Abgleich, also immer mit Titeln.
        let titleEntries = try titleEntities.map { SearchIndexBuilder.titleEntries($0, egSongs: try egSongs ?? db.allEgSongs()) }
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
            if let titles, let titleEntries {
                try AppDatabase.deleteTitles(conn, ixs: titles.isFull ? nil : titles.rows.filter(\.deleted).map(\.ix))
                try AppDatabase.upsertTitles(conn, titles.rows.filter { !$0.deleted }.map { TitleEntity(ix: $0.ix, title: $0.title) })
                try AppDatabase.deleteSearchEntries(conn, type: .title)
                try AppDatabase.insertSearchEntries(conn, titleEntries)
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
            try AppDatabase.upsertSyncState(conn, SyncState(
                titleChangeCounter: titles?.counter ?? stored?.titleChangeCounter,
                bookChangeCounter: books?.counter ?? stored?.bookChangeCounter,
                composerChangeCounter: composers?.counter ?? stored?.composerChangeCounter,
                checkedAtMillis: nowMillis,
                fullSyncAtMillis: full ? nowMillis : lastFullSync
            ))
        }

        var updated = Set<Section>()
        if titles != nil { updated.insert(.titles) }
        if books != nil { updated.insert(.books) }
        if composers != nil { updated.insert(.composers) }
        return .checked(updated: updated)
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
        // bekannten liegen. Sänke er, hielte der Fundstellen-Cache alle Inventar-Bücher für
        // veraltet, und der nächste Abgleich höbe ihn wieder an.
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

    private static func entity(_ dto: EgSongDto) -> EgSongEntity {
        EgSongEntity(ix: dto.ix, ixUr: dto.ixUr, title: dto.title, part: dto.part, number: dto.number, occasion: dto.occasion)
    }

    private static func entity(_ dto: BookDto) -> BookEntity {
        let editor = [dto.editorFirstName, dto.editor].compactMap { $0 }.joined(separator: " ")
        return BookEntity(
            id: dto.id, title: dto.title, subtitle: dto.subtitle, year: dto.year,
            editor: editor.isEmpty ? nil : editor, publisher: dto.publisher,
            publisherNumber: dto.publisherNumber, coverUrl: dto.coverUrl
        )
    }

    private static func entity(_ dto: ComposerDto) -> ComposerEntity {
        ComposerEntity(id: dto.id, name: dto.name, born: dto.born, died: dto.died)
    }
}

/// Stammdaten mit Schlüssel, für `MasterDataSync.merge`.
protocol KeyedEntity {
    associatedtype Key: Hashable
    var key: Key { get }
}

extension TitleEntity: KeyedEntity { var key: Int { ix } }
extension BookEntity: KeyedEntity { var key: String { id } }
