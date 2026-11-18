import Foundation

/// Fundstellen aus der lokalen Tabelle, die `MasterDataSync` füllt. `fundstellen` braucht kein Netz.
///
/// Löschungen meldet der Server nicht. Gelöschte Zeilen verschwinden mit dem monatlichen
/// Vollabgleich, der alle Fundstellen neu lädt (`MasterDataSync`).
public actor FundstellenRepository {

    private let db: AppDatabase
    private let sync: MasterDataSync

    public init(db: AppDatabase, sync: MasterDataSync) {
        self.db = db
        self.sync = sync
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

    /// Mit `force` neue Fundstellen holen, sonst nichts. Für alle Seiten gleich.
    /// - Returns: `true`, wenn ein Request an den Server ging
    /// - Throws: `BlechWikiError` bei Netz- oder Serverfehlern; die Daten bleiben dann unverändert
    @discardableResult
    public func refresh(_ query: FundstellenQuery, force: Bool = false) async throws -> Bool {
        force ? try await sync.fetchNewPieces(force: true) : false
    }
}
