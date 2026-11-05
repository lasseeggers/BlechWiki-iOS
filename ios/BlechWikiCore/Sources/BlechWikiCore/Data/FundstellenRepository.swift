import Foundation

/// Fundstellen aus der lokalen Tabelle, die `MasterDataSync` füllt. `fundstellen` braucht kein Netz.
///
/// Löschungen meldet der Server nicht. `refresh` gleicht deshalb ein Buch mit `Buch/{id}` ab,
/// höchstens alle `maxAge`: Zeilen, die dort fehlen, sind gelöscht oder korrigiert (eine Korrektur
/// kommt mit neuem Zähler über `MasterDataSync.fetchNewPieces`).
public actor FundstellenRepository {

    public static let maxAge: TimeInterval = 30 * 24 * 3600

    private let api: BlechWikiAPI
    private let db: AppDatabase
    private let sync: MasterDataSync
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<Bool, Error>] = [:]

    public init(api: BlechWikiAPI, db: AppDatabase, sync: MasterDataSync, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.db = db
        self.sync = sync
        self.now = now
    }

    /// Komponisten mit ihrem Namen aus dem Verzeichnis, sonst mit dem Kurznamen, z. B. "Hassler H L".
    public nonisolated func fundstellen(_ query: FundstellenQuery) throws -> [Fundstelle] {
        try db.pieces(query).map {
            let composer = [$0.composerName ?? $0.composerShortName, $0.composerName2 ?? $0.composerShortName2]
                .compactMap { $0 }.joined(separator: " // ")
            return Fundstelle(
                bookId: $0.bookId, bookTitle: $0.bookTitle, bookSubtitle: $0.bookSubtitle, number: $0.number,
                title: $0.title, addition: $0.addition, composer: composer.isEmpty ? nil : composer,
                scoring: $0.scoring, keySignature: $0.keySignature, coverUrl: $0.coverUrl
            )
        }
    }

    /// Wann die Fundstellen zuletzt mit dem Server abgeglichen wurden, sonst der Zeitpunkt des
    /// mitgelieferten Stands. `nil`, solange noch keine Fundstellen da sind. Für alle Abfragen gleich.
    public nonisolated func fetchedAt(_ query: FundstellenQuery) throws -> Date? {
        guard let state = try db.syncState(), state.pieceCounter != nil, let millis = state.piecesCheckedAtMillis else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    /// Bücher: neue Fundstellen holen und mit `Buch/{id}` abgleichen, wenn das länger als
    /// `maxAge` her ist oder `force` gesetzt ist. Andere Seiten: mit `force` neue Fundstellen
    /// holen, sonst nichts.
    /// - Returns: `true`, wenn ein Request an den Server ging
    /// - Throws: `BlechWikiError` bei Netz- oder Serverfehlern; die Daten bleiben dann unverändert
    @discardableResult
    public func refresh(_ query: FundstellenQuery, force: Bool = false) async throws -> Bool {
        guard case .byBook(let bookId) = query else {
            return force ? try await sync.fetchNewPieces(force: true) : false
        }
        // Gleichzeitige Aufrufe für dasselbe Buch warten aufeinander. Der zweite sieht danach
        // den frischen Abgleich und schickt keinen eigenen Request.
        while let running = inFlight[bookId] {
            _ = try? await running.value
            if inFlight[bookId] == running { inFlight[bookId] = nil }
        }
        let task = Task { try await check(bookId, force: force) }
        inFlight[bookId] = task
        defer { if inFlight[bookId] == task { inFlight[bookId] = nil } }
        return try await task.value
    }

    private func check(_ bookId: String, force: Bool) async throws -> Bool {
        if !force, isFresh(try db.bookCheckedAtMillis(bookId)) { return false }
        // Erst neue Zeilen holen: Eine Korrektur soll nicht fehlen, wenn ihre alte Fassung gleich gelöscht wird
        try await sync.fetchNewPieces(force: force)
        let onServer = try await api.getBookPieceCounters(bookId)
        // Eine leere Antwort hieße, alles zu löschen. Das wäre eher ein Serverfehler, und ein
        // gelöschtes Buch verschwindet ohnehin mit dem nächsten Abgleich der Bücher.
        let removed = onServer.isEmpty ? [] : try db.countersOfBook(bookId).filter { !onServer.contains($0) }
        let checkedAt = Int(now().timeIntervalSince1970 * 1000)
        try db.write { conn in
            try AppDatabase.deletePieces(conn, counters: removed)
            if !removed.isEmpty { try AppDatabase.rebuildSearchWeights(conn) }
            try AppDatabase.upsertBookCheck(conn, bookId: bookId, checkedAtMillis: checkedAt)
        }
        return true
    }

    private func isFresh(_ checkedAtMillis: Int?) -> Bool {
        guard let checkedAtMillis else { return false }
        let ageMillis = Int(now().timeIntervalSince1970 * 1000) - checkedAtMillis
        // Zeitpunkt in der Zukunft (Uhr war verstellt): sonst bliebe der Eintrag bis dahin frisch
        return ageMillis >= 0 && ageMillis < Int(Self.maxAge * 1000)
    }
}
