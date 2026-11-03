import Foundation

/// Das Inventar: die Bücher, die der Chor besitzt. Der Inhalt markierter Bücher wird im
/// Hintergrund geladen (`GetBuchFundstellen`, ca. 40 KB pro Buch) und steht danach offline bereit.
public final class MyBooksRepository: Sendable {

    private let db: AppDatabase
    private let preferences: UserPreferences

    public init(db: AppDatabase, preferences: UserPreferences) {
        self.db = db
        self.preferences = preferences
    }

    public var ownedBookIds: Set<String> { preferences.ownedBookIds }

    public func books() throws -> [BookItem] {
        let owned = preferences.ownedBookIds
        return try db.books().map { Self.item($0, isOwned: owned.contains($0.id)) }
    }

    /// Bücher für die Auswahlliste. Mit `filter` eine gefilterte Liste, sonst Vorschläge und alle Bücher.
    public func sections(filter: String) throws -> BookSections {
        Self.buildSections(try books(), appendix: preferences.egAppendix, filter: filter)
    }

    /// Ein Buch mit Stammdaten (Jahr, Verlag), `nil` solange der Abgleich fehlt.
    public func book(id: String) throws -> BookItem? {
        try db.book(id: id).map { Self.item($0, isOwned: preferences.ownedBookIds.contains($0.id)) }
    }

    /// Wie viele markierte Bücher schon offline vorliegen.
    public func offlineStatus() throws -> OfflineStatus {
        let ids = preferences.ownedBookIds
        if ids.isEmpty { return OfflineStatus(owned: 0, available: 0) }
        let fetched = try db.fetchedKeys(ids.map { FundstellenQuery.byBook($0).cacheKey })
        return OfflineStatus(owned: ids.count, available: fetched.count)
    }

    public func setOwned(_ bookId: String, owned: Bool) {
        preferences.setBookOwned(bookId, owned: owned)
    }

    /// Code zum Teilen, `nil` bei leerem Inventar.
    public func inventoryCode() throws -> String? {
        InventoryCode.encode(Array(preferences.ownedBookIds))
    }

    /// Liest einen Inventar-Code aus `text`, z. B. einer ganzen weitergeleiteten Nachricht.
    /// Nach einem Verzeichnis-Abgleich erneut aufrufen, damit neue Bücher erscheinen.
    public func inventoryImport(_ text: String) throws -> InventoryImport {
        let items = try books()
        switch InventoryCode.decode(text, catalog: items.map(\.id)) {
        case .notFound: return .noCode
        case .invalid: return .invalid
        case let .valid(bookIds, unknownCount):
            let ids = Set(bookIds)
            return .ready(books: items.filter { ids.contains($0.id) }, unknownCount: unknownCount)
        }
    }

    public func importInventory(_ bookIds: [String], replace: Bool) {
        preferences.addOwnedBooks(bookIds, replace: replace)
    }

    static func buildSections(_ items: [BookItem], appendix: String?, filter: String) -> BookSections {
        let textFilter = TextFilter(filter)
        if !textFilter.isEmpty {
            return BookSections(filtered: items.filter { textFilter.matchesWords($0.searchText.split(separator: " ").map(String.init)) })
        }
        return BookSections(
            suggested: appendix.map { code in items.filter { RegionKeywords.matches($0.searchText, appendixCode: code) } } ?? [],
            choralBooks: items.filter { $0.searchText.contains("choralbuch") },
            all: items
        )
    }

    private static func item(_ book: BookEntity, isOwned: Bool) -> BookItem {
        BookItem(
            id: book.id, title: book.title, subtitle: book.subtitle, year: book.year, editor: book.editor,
            publisher: book.publisher, publisherNumber: book.publisherNumber, coverUrl: book.coverUrl,
            isOwned: isOwned,
            // Mit ae/oe/ue-Varianten, damit der Filter "blaeser" wie "bläser" findet
            searchText: SearchNormalizer.indexContent([book.title, book.subtitle, book.editor, book.publisher].compactMap { $0 }.joined(separator: " "))
        )
    }
}

public final class SettingsRepository: Sendable {

    private let db: AppDatabase
    private let preferences: UserPreferences

    public init(db: AppDatabase, preferences: UserPreferences) {
        self.db = db
        self.preferences = preferences
    }

    /// EG-Anhänge der Landeskirchen, ohne Stammteil und Ergänzungen, deutsch sortiert. Vor dem ersten
    /// Abgleich die eingebaute Liste, damit die Einführung auch ohne Netz eine Auswahl zeigt.
    public func egAppendices() throws -> [EgAppendix] {
        let german = Locale(identifier: "de_DE")
        let stored = try db.egAppendices().map { EgAppendix(code: $0.code, name: $0.name) }
        let list = stored.isEmpty ? JsonBlechWikiAPI.egAppendices.map { EgAppendix(code: $0.code, name: $0.name) } : stored
        return list
            .filter { $0.code != SearchIndexBuilder.stammteil && $0.code != SearchIndexBuilder.ergaenzungen }
            // SQLite sortiert "Österreich" sonst hinter "Württemberg"
            .sorted { $0.name.compare($1.name, locale: german) == .orderedAscending }
    }

    public func selectedEgAppendix() throws -> EgAppendix? {
        guard let code = preferences.egAppendix else { return nil }
        return try egAppendices().first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    public func selectEgAppendix(_ code: String?) {
        preferences.setEgAppendix(code)
    }

    /// Wann das Verzeichnis zuletzt als aktuell bestätigt wurde.
    public func lastCheckedAt() throws -> Date? {
        guard let state = try db.syncState(), state.isComplete else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(state.checkedAtMillis) / 1000)
    }

    /// `true`, sobald einmal alle Stammdaten lokal vorliegen.
    public func hasData() throws -> Bool { try db.syncState()?.isComplete == true }

    /// Ob die Einführung beim Start erscheinen soll. Wer schon eine Landeskirche oder Bücher eingetragen
    /// hat, kennt die App schon und bekommt sie nicht zu sehen. Einmal beim Start
    /// abfragen: Während der Einführung wählt der Nutzer selbst eine Landeskirche.
    public func needsOnboarding() -> Bool {
        if preferences.onboardingDone { return false }
        if preferences.egAppendix != nil || !preferences.ownedBookIds.isEmpty {
            preferences.setOnboardingDone()
            return false
        }
        return true
    }

    public func finishOnboarding() {
        preferences.setOnboardingDone()
    }
}
