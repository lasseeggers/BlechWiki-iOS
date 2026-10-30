import Foundation

/// Lädt Titel, EG-Lieder, Bücher und Komponisten in die lokale Datenbank.
///
/// Ablauf: Liegt der letzte Check weniger als `checkInterval` zurück, passiert nichts.
/// Sonst wird die Datenversion (`GetlastAutonummer`, 1,4 KB) abgefragt und nur das neu
/// geladen, dessen AutoNr sich geändert hat. Alles wird in einer Transaktion geschrieben:
/// Bricht der Abgleich ab, bleibt der alte Stand vollständig erhalten.
///
/// Abgleiche laufen nie parallel (Actor). Ein zweiter Aufruf wartet und sieht danach den frischen Stand.
///
/// Der Versionsstempel erkennt nur neue Einträge, keine Korrekturen oder Löschungen. Die zeigt
/// das Änderungsprotokoll der REST-API (`BlechWikiRestAPI.getLatestChange`, 2 Byte je Tabelle,
/// wenn nichts passiert ist). Ist der REST-Server nicht erreichbar, läuft der Abgleich ohne ihn.
/// Als Rückfallebene lädt ein Aufruf mit `fullRefreshIfDue` alle `fullRefreshInterval` alles
/// neu (ca. 2,3 MB).
public actor MasterDataSync {

    public enum Outcome: Equatable, Sendable {
        /// Letzter Check ist jünger als `checkInterval`, kein Request.
        case skipped
        /// Datenversion geprüft. `updated` nennt die neu geladenen Bereiche, leer wenn alles aktuell war.
        case checked(updated: Set<Section>)
    }

    public enum Section: Sendable { case titles, books, composers }

    public static let checkInterval: TimeInterval = 24 * 3600
    public static let fullRefreshInterval: TimeInterval = 30 * 24 * 3600

    /// Stand Oktober 2026: Bücher 122, Komponisten 78, Titel 69. Größere Werte findet die Suche auch.
    private static let probeStart = 256

    private let api: BlechWikiAPI
    private let db: AppDatabase
    private let changeLog: BlechWikiRestAPI
    private let now: @Sendable () -> Date

    public init(api: BlechWikiAPI, db: AppDatabase, changeLog: BlechWikiRestAPI, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.db = db
        self.changeLog = changeLog
        self.now = now
    }

    public func sync(force: Bool = false, fullRefreshIfDue: Bool = false) async throws -> Outcome {
        let stored = try db.syncState()
        let nowMillis = Int(now().timeIntervalSince1970 * 1000)
        let lastFullSync = stored?.fullSyncAtMillis
        let fullRefresh = fullRefreshIfDue &&
            (lastFullSync.map { nowMillis - $0 >= Int(Self.fullRefreshInterval * 1000) } ?? true)
        if !force, !fullRefresh, let stored, stored.isComplete,
           nowMillis - stored.checkedAtMillis < Int(Self.checkInterval * 1000) {
            return .skipped
        }

        let remote = try await api.getDataVersion()
        let changes = await checkChangeLog(stored)
        let titlesChanged = fullRefresh || stored?.lastTitleNumber != remote.lastTitleNumber || changes.changed.contains(.titles)
        let booksChanged = fullRefresh || stored?.lastBookNumber != remote.lastBookNumber || changes.changed.contains(.books)
        let composersChanged = fullRefresh || stored?.lastComposerNumber != remote.lastComposerNumber ||
            changes.changed.contains(.composers)

        // Erst alles laden, dann schreiben, damit ein Netzfehler keinen halben Stand hinterlässt.
        // Nacheinander statt parallel, um den privat betriebenen Server nicht zu belasten.
        let titles = titlesChanged ? try await api.getTitles("") : nil
        let egSongs = titlesChanged ? try await api.getEgSongs().map(Self.entity) : nil
        let egAppendices = titlesChanged ? try await api.getEgAppendices().map { EgAppendixEntity(code: $0.code, name: $0.name) } : nil
        let books = booksChanged ? try await api.getBooks().map(Self.entity) : nil
        let composers = composersChanged
            ? try await api.getComposers().filter { !$0.shortName.isEmpty }.map(Self.entity)
            : nil

        // Index vor der Transaktion bauen, damit die Sperre kurz bleibt
        let egEntries = egSongs.map(SearchIndexBuilder.egSongEntries)
        let titleEntries = titles.flatMap { t in egSongs.map { SearchIndexBuilder.titleEntries(t, egSongs: $0) } }
        let bookEntries = books.map(SearchIndexBuilder.bookEntries)
        let composerEntries = composers.map(SearchIndexBuilder.composerEntries)

        try db.write { conn in
            if let egSongs, let egAppendices, let egEntries, let titleEntries {
                try AppDatabase.replaceEgSongs(conn, egSongs)
                try AppDatabase.replaceEgAppendices(conn, egAppendices)
                try AppDatabase.deleteSearchEntries(conn, type: .egSong)
                try AppDatabase.deleteSearchEntries(conn, type: .title)
                try AppDatabase.insertSearchEntries(conn, egEntries)
                try AppDatabase.insertSearchEntries(conn, titleEntries)
            }
            if let books, let bookEntries {
                try AppDatabase.replaceBooks(conn, books)
                try AppDatabase.deleteSearchEntries(conn, type: .book)
                try AppDatabase.insertSearchEntries(conn, bookEntries)
            }
            if let composers, let composerEntries {
                try AppDatabase.replaceComposers(conn, composers)
                try AppDatabase.deleteSearchEntries(conn, type: .composer)
                try AppDatabase.insertSearchEntries(conn, composerEntries)
            }
            try AppDatabase.upsertSyncState(conn, SyncState(
                lastBookNumber: remote.lastBookNumber,
                lastComposerNumber: remote.lastComposerNumber,
                lastTitleNumber: remote.lastTitleNumber,
                checkedAtMillis: nowMillis,
                // Auch der erste Abgleich lädt alles und zählt als vollständig
                fullSyncAtMillis: titlesChanged && booksChanged && composersChanged ? nowMillis : lastFullSync,
                bookChangeCounter: changes.counters[.books],
                composerChangeCounter: changes.counters[.composers],
                titleChangeCounter: changes.counters[.titles]
            ))
        }

        var updated = Set<Section>()
        if titlesChanged { updated.insert(.titles) }
        if booksChanged { updated.insert(.books) }
        if composersChanged { updated.insert(.composers) }
        return .checked(updated: updated)
    }

    private struct ChangeLogState {
        /// Fehlt eine Tabelle, ist ihr Stand unbekannt.
        var counters: [ChangeTable: Int] = [:]
        var changed: Set<ChangeTable> = []
    }

    /// Fragt je Tabelle, ob es seit dem gespeicherten Zähler Änderungen gab. Bei einem Fehler
    /// bleibt der alte Zähler stehen, die Tabelle gilt als unverändert.
    private func checkChangeLog(_ stored: SyncState?) async -> ChangeLogState {
        var state = ChangeLogState()
        for table in ChangeTable.allCases {
            let known = stored.flatMap { Self.changeCounter($0, table) }
            state.counters[table] = known
            do {
                if let known {
                    if let latest = try await changeLog.getLatestChange(table, after: max(known, 1)) {
                        state.counters[table] = latest
                        state.changed.insert(table)
                    }
                } else {
                    // Erster Kontakt: Nur den Stand merken. Die Stammdaten sind entweder gerade
                    // frisch geladen oder werden über die AutoNr abgeglichen.
                    state.counters[table] = try await findLatestChange(table)
                }
            } catch {
                // REST-Server nicht erreichbar oder Format geändert: Abgleich nur über die AutoNr
            }
        }
        return state
    }

    /// Aktueller Zähler, ohne das ganze Protokoll zu laden (Titel ab Zähler 1: ca. 240 KB).
    /// Jede nicht leere Antwort enthält den höchsten Zähler, daher von oben halbieren.
    private func findLatestChange(_ table: ChangeTable) async throws -> Int {
        var after = Self.probeStart
        while true {
            if let latest = try await changeLog.getLatestChange(table, after: after) { return latest }
            if after == 1 { return 0 }
            after /= 2
        }
    }

    private static func changeCounter(_ state: SyncState, _ table: ChangeTable) -> Int? {
        switch table {
        case .titles: state.titleChangeCounter
        case .books: state.bookChangeCounter
        case .composers: state.composerChangeCounter
        }
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
        ComposerEntity(shortName: dto.shortName, name: dto.name, born: dto.born, died: dto.died)
    }
}
