import Foundation

/// Schlüssel eines Listeneintrags, nur zum Vergleichen: Ist ein Lied schon Favorit, steht es schon
/// in dieser Liste? Abgeleitet aus den Rohfeldern, gleich wie in der Android-App. `titelZ` taugt
/// nicht, eine korrigierte Fundstelle bekommt einen neuen Zähler.
public enum ListEntryKey {

    /// "Lobe den Herren, den mächtigen" → "t:lobe den herren den machtigen"
    public static func title(_ title: String) -> String {
        "t:" + SearchNormalizer.normalize(title)
    }

    /// "p:5084|12|grosser gott wir loben dich|satz bach"
    public static func piece(bookId: String, number: String, title: String, addition: String?) -> String {
        "p:\(bookId)|\(number.trimmingCharacters(in: .whitespaces))|\(SearchNormalizer.normalize(title))|\(SearchNormalizer.normalize(addition ?? ""))"
    }

    /// "eg:331"
    public static func eg(ix: Int) -> String {
        "eg:\(ix)"
    }
}

public enum ListsError: Error {
    /// Die Liste wurde inzwischen gelöscht.
    case listNotFound
}

/// Favoriten und eigene Listen. Die Favoriten (`favoritesId`) gibt es immer, sie lassen sich nicht
/// umbenennen oder löschen, und ein Lied steht dort höchstens einmal. In eigenen Listen darf es
/// mehrfach stehen, etwa als Eingangs- und Schlusslied.
public final class ListsRepository: Sendable {

    public static let favoritesId = ListsDatabase.favoritesId
    public static let maxCommentLength = 300

    let database: Result<ListsDatabase, any Error>
    private let db: AppDatabase
    private let preferences: UserPreferences
    private let now: @Sendable () -> Date

    /// `lists` als `Result`: Lässt sich die Datei nicht öffnen, läuft die App ohne Listen weiter,
    /// und jede Abfrage wirft den Fehler beim Öffnen.
    public init(lists: Result<ListsDatabase, any Error>, db: AppDatabase, preferences: UserPreferences,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.database = lists
        self.db = db
        self.preferences = preferences
        self.now = now
    }

    /// `false`, wenn sich die Datei nicht öffnen ließ.
    public var isAvailable: Bool {
        if case .success = database { true } else { false }
    }

    /// Fehler beim Öffnen, fürs Protokoll.
    public var openError: (any Error)? {
        if case .failure(let error) = database { error } else { nil }
    }

    private var nowMillis: Int { Int(now().timeIntervalSince1970 * 1000) }

    // MARK: Lesen

    /// Favoriten zuerst, dann die übrigen deutsch sortiert, ohne Groß-/Kleinschreibung.
    public func lists() throws -> [ListSummary] {
        let german = Locale(identifier: "de_DE")
        let all = try database.get().lists()
        let others = all.filter { !$0.isFavorites }
            .sorted { $0.name.compare($1.name, options: .caseInsensitive, locale: german) == .orderedAscending }
        return all.filter(\.isFavorites) + others
    }

    /// Liste mit Einträgen und aktuellem Stand aus Verzeichnis und Inventar. `nil`, wenn es sie nicht mehr gibt.
    public func list(id: String) throws -> ListDetail? {
        let store = try database.get()
        guard let name = try store.listName(id: id) else { return nil }
        return ListDetail(id: id, name: name, entries: try enrich(try store.entries(listId: id)))
    }

    public func favoriteKeys() throws -> Set<String> {
        try database.get().keys(listId: Self.favoritesId)
    }

    /// Kommentar am Favoriten mit `key`, für die Rückfrage beim Abschalten des Sterns.
    public func favoriteComment(key: String) throws -> String? {
        try database.get().comment(listId: Self.favoritesId, key: key)
    }

    /// Listen, in denen `key` schon steht, für „Schon enthalten“.
    public func listIds(containing key: String) throws -> Set<String> {
        try database.get().listIds(containing: key)
    }

    // MARK: Schreiben

    /// Legt eine Liste an. `nil`, wenn der Name ohne Leerraum am Rand leer ist.
    @discardableResult
    public func createList(name: String) throws -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        let millis = nowMillis
        try database.get().write { try ListsDatabase.insertList($0, id: id, name: name, nowMillis: millis) }
        return id
    }

    /// Ohne Wirkung bei den Favoriten und bei leerem Namen.
    public func renameList(id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != Self.favoritesId, !name.isEmpty else { return }
        let millis = nowMillis
        try database.get().write { try ListsDatabase.renameList($0, id: id, name: name, nowMillis: millis) }
    }

    /// Löscht die Liste mit ihren Einträgen. Ohne Wirkung bei den Favoriten.
    public func deleteList(id: String) throws {
        guard id != Self.favoritesId else { return }
        try database.get().write { try ListsDatabase.deleteList($0, id: id) }
    }

    /// Hängt `ref` unten an. In den Favoriten nur, wenn das Lied dort noch fehlt.
    public func add(_ ref: ListEntryRef, to listId: String) throws {
        let millis = nowMillis
        try database.get().write { conn in
            guard try ListsDatabase.listExists(conn, id: listId) else { throw ListsError.listNotFound }
            if listId == Self.favoritesId, try ListsDatabase.containsKey(conn, listId: listId, key: ref.key) { return }
            try ListsDatabase.appendEntry(conn, Self.record(ref, listId: listId, nowMillis: millis))
            try ListsDatabase.touchList(conn, id: listId, nowMillis: millis)
        }
    }

    /// Stern: nimmt `ref` in die Favoriten auf oder entfernt es dort.
    /// - Returns: `true`, wenn das Lied danach Favorit ist
    @discardableResult
    public func toggleFavorite(_ ref: ListEntryRef) throws -> Bool {
        let key = ref.key
        let millis = nowMillis
        return try database.get().write { conn in
            let entries = try ListsDatabase.entries(conn, listId: Self.favoritesId)
            let matching = entries.filter { $0.entryKey == key }
            if matching.isEmpty {
                try ListsDatabase.appendEntry(conn, Self.record(ref, listId: Self.favoritesId, nowMillis: millis))
            } else {
                try ListsDatabase.deleteEntries(conn, ids: matching.map(\.id))
                try ListsDatabase.setPositions(conn, ids: entries.filter { $0.entryKey != key }.map(\.id))
            }
            try ListsDatabase.touchList(conn, id: Self.favoritesId, nowMillis: millis)
            return matching.isEmpty
        }
    }

    public func remove(entryId: String) throws {
        let store = try database.get()
        guard let entry = try store.entry(id: entryId) else { return }
        let millis = nowMillis
        try store.write { conn in
            try ListsDatabase.deleteEntries(conn, ids: [entryId])
            try ListsDatabase.setPositions(conn, ids: try ListsDatabase.entries(conn, listId: entry.listId).map(\.id))
            try ListsDatabase.touchList(conn, id: entry.listId, nowMillis: millis)
        }
    }

    /// Verschiebt die Einträge an `source` vor die Stelle `destination`, wie `onMove` in SwiftUI.
    /// Schreibt alle Positionen in einer Transaktion neu.
    public func move(in listId: String, from source: IndexSet, to destination: Int) throws {
        let millis = nowMillis
        try database.get().write { conn in
            let ids = try ListsDatabase.entries(conn, listId: listId).map(\.id)
            try ListsDatabase.setPositions(conn, ids: Self.reordered(ids, from: source, to: destination))
            try ListsDatabase.touchList(conn, id: listId, nowMillis: millis)
        }
    }

    /// Leerer Kommentar löscht ihn. Gekürzt auf `maxCommentLength` Zeichen.
    public func setComment(entryId: String, comment: String?) throws {
        let store = try database.get()
        guard let entry = try store.entry(id: entryId) else { return }
        let comment = Self.normalizedComment(comment)
        let millis = nowMillis
        try store.write { conn in
            try ListsDatabase.setComment(conn, entryId: entryId, comment: comment)
            try ListsDatabase.touchList(conn, id: entry.listId, nowMillis: millis)
        }
    }

    // MARK: Hilfen

    static func normalizedComment(_ comment: String?) -> String? {
        let trimmed = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxCommentLength))
    }

    /// Wie `move(fromOffsets:toOffset:)` in SwiftUI. Indizes außerhalb von `items` zählen nicht.
    public static func reordered<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let valid = source.filter { $0 >= 0 && $0 < items.count }
        let moving = valid.map { items[$0] }
        var rest = items.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let target = min(max(destination - valid.filter { $0 < destination }.count, 0), rest.count)
        rest.insert(contentsOf: moving, at: target)
        return rest
    }

    private static func record(_ ref: ListEntryRef, listId: String, nowMillis: Int) -> ListEntryRecord {
        var record = ListEntryRecord(
            id: UUID().uuidString.lowercased(), listId: listId, position: 0, kind: ref.kind.rawValue,
            entryKey: ref.key, title: ref.title, addedAtMillis: nowMillis
        )
        switch ref {
        case .title:
            break
        case let .piece(bookId, bookTitle, number, _, addition):
            record.bookId = bookId
            record.bookTitle = bookTitle
            record.number = number
            record.addition = addition
        case let .eg(ix, ixUr, _, label):
            record.egIx = ix
            record.egIxUr = ixUr
            record.egLabel = label
        }
        return record
    }

    /// Gespeicherte Felder als `ListEntryRef`. Eine unbekannte Art (aus einer neueren App-Version)
    /// erscheint als Titel.
    private static func ref(_ record: ListEntryRecord) -> ListEntryRef {
        switch ListEntryKind(rawValue: record.kind) {
        case .piece:
            .piece(bookId: record.bookId ?? "", bookTitle: record.bookTitle ?? "", number: record.number ?? "",
                   title: record.title, addition: record.addition)
        case .eg:
            .eg(ix: record.egIx ?? 0, ixUr: record.egIxUr ?? record.egIx ?? 0, title: record.title, label: record.egLabel)
        case .title, nil:
            .title(record.title)
        }
    }

    /// Ergänzt Bücherzahl, Inventar, aktuelle EG-Nummer und Fundstellen aus dem Verzeichnis.
    /// Liegen keine Stammdaten vor, bleibt es bei den gespeicherten Feldern.
    private func enrich(_ records: [ListEntryRecord]) throws -> [ListEntryItem] {
        let refs = records.map(Self.ref)
        let owned = preferences.ownedBookIds
        let ownedBooks = Array(owned)

        var seenNorms = Set<String>()
        let titleNorms = refs.compactMap { ref -> String? in
            if case .title(let title) = ref { SearchNormalizer.normalize(title) } else { nil }
        }.filter { seenNorms.insert($0).inserted }
        let bookCounts = try db.bookCounts(titleNorms: titleNorms)
        let titleHits = Dictionary(grouping: try db.ownedHits(bookIds: ownedBooks, titleNorms: titleNorms), by: \.titleNorm)

        // Mit den Liedern, auf die Ergänzungen verweisen (ix = ixUr)
        var seenIx = Set<Int>()
        let ixs = refs.flatMap { ref -> [Int] in
            if case let .eg(ix, ixUr, _, _) = ref { [ix, ixUr] } else { [] }
        }.filter { seenIx.insert($0).inserted }
        let variants = Dictionary(grouping: try db.egSongs(ixs: ixs), by: \.ix)
        func melody(_ ix: Int, stored: Int) -> Int { variants[ix]?.first?.ixUr ?? stored }
        var seenMelodies = Set<Int>()
        let ixUrs = refs.compactMap { ref -> Int? in
            if case let .eg(ix, ixUr, _, _) = ref { melody(ix, stored: ixUr) } else { nil }
        }.filter { seenMelodies.insert($0).inserted }
        let melodyHits = Dictionary(grouping: try db.ownedMelodyHits(bookIds: ownedBooks, ixUrs: ixUrs), by: \.ixUr)
        let appendix = preferences.egAppendix

        var piecesByNumber: [String: [PieceRow]] = [:]
        var books: [String: BookEntity?] = [:]

        return try zip(records, refs).map { record, ref in
            var item = ListEntryItem(id: record.id, ref: ref, comment: record.comment, title: record.title)
            switch ref {
            case .title(let title):
                let norm = SearchNormalizer.normalize(title)
                item.bookCount = bookCounts[norm] ?? 0
                item.ownedLocations = (titleHits[norm] ?? []).map { OwnedLocation(bookTitle: $0.bookTitle, number: $0.number) }
            case let .eg(ix, ixUr, _, label):
                let song = variants[ix] ?? []
                item.title = song.first?.title ?? record.title
                item.egNumber = SearchIndexBuilder.egSongDetail(song, byIx: variants, appendix: appendix) ?? label
                item.ownedLocations = (melodyHits[melody(ix, stored: ixUr)] ?? []).map { OwnedLocation(bookTitle: $0.bookTitle, number: $0.number) }
            case let .piece(bookId, bookTitle, number, _, addition):
                let cacheKey = "\(bookId)|\(number)"
                if piecesByNumber[cacheKey] == nil { piecesByNumber[cacheKey] = try db.pieces(bookId: bookId, number: number) }
                let match = piecesByNumber[cacheKey]?.first {
                    ListEntryKey.piece(bookId: $0.bookId, number: $0.number, title: $0.title, addition: $0.addition) == record.entryKey
                }
                if books[bookId] == nil { books[bookId] = .some(try db.book(id: bookId)) }
                let book = books[bookId] ?? nil
                item.title = match?.title ?? record.title
                item.addition = match.map(\.addition) ?? addition
                item.number = match?.number ?? number
                item.bookTitle = match?.bookTitle ?? book?.title ?? bookTitle
                item.coverUrl = match?.coverUrl ?? book?.coverUrl
                item.isMissing = match == nil
                item.isOwnedBook = owned.contains(bookId)
            }
            return item
        }
    }
}
