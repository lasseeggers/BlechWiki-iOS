import Foundation

/// Suche ausschließlich in der lokalen Datenbank. Kein Netzwerkzugriff.
public final class SearchRepository: Sendable {

    private let db: AppDatabase
    private let preferences: UserPreferences

    public init(db: AppDatabase, preferences: UserPreferences) {
        self.db = db
        self.preferences = preferences
    }

    /// Dauert wenige Millisekunden. Neu aufrufen, sobald `DataChanges` eine Änderung meldet
    /// (erster Abgleich, Einstellungen, Inhalt eines Inventar-Buchs geladen).
    public func search(_ query: String) throws -> SearchResults {
        guard let match = SearchNormalizer.matchExpression(query) else { return SearchResults() }
        let norm = SearchNormalizer.normalize(query)
        let egNumber = Self.egNumber(query)

        let egByNumber = try egNumber.map { try db.egSongsByNumber($0) } ?? []
        var seen = Set<String>()
        let rawEg = (egByNumber + (try db.search(match: match, type: .egSong, norm: norm, limit: Self.limitEg)))
            .filter { seen.insert($0.refKey).inserted }
        let rawTitles = try db.search(match: match, type: .title, norm: norm, limit: Self.limitTitles)
        let rawBooks = try db.search(match: match, type: .book, norm: norm, limit: Self.limitOther)
        let rawComposers = try db.search(match: match, type: .composer, norm: norm, limit: Self.limitOther)

        let appendix = preferences.egAppendix
        let owned = preferences.ownedBookIds
        // Mit den Liedern, auf die Ergänzungen verweisen (ix = ixUr)
        var seenIx = Set<Int>()
        let ixs = rawEg.flatMap { [Int($0.refKey), $0.refNumber].compactMap { $0 } }.filter { seenIx.insert($0).inserted }
        let variants = Dictionary(grouping: try db.egSongs(ixs: ixs), by: \.ix)
        func variantsOf(_ hit: SearchHit) -> [EgSongEntity] { Int(hit.refKey).flatMap { variants[$0] } ?? [] }

        var eg = rawEg
        if let egNumber {
            // Stammteil und eigener Anhang vor Nummern aus anderen Landeskirchen (stabil sortiert)
            eg = eg.enumerated().sorted { a, b in
                let pa = isPreferred(variantsOf(a.element), number: egNumber, appendix: appendix) ? 0 : 1
                let pb = isPreferred(variantsOf(b.element), number: egNumber, appendix: appendix) ? 0 : 1
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)
        }

        let ownedHits = try ownedHits(owned, labels: (eg + rawTitles).map(\.label))
        let byNorm = Dictionary(grouping: ownedHits, by: \.titleNorm)
        func locations(_ label: String) -> [OwnedLocation] {
            (byNorm[SearchNormalizer.normalize(label)] ?? []).map { OwnedLocation(bookTitle: $0.bookTitle, number: $0.number) }
        }

        var results = SearchResults()
        results.egSongs = eg.map { hit in
            var result = toResult(hit)
            result.detail = SearchIndexBuilder.egSongDetail(variantsOf(hit), byIx: variants, appendix: appendix) ?? hit.detail
            result.ownedLocations = locations(hit.label)
            return result
        }
        results.titles = rawTitles.map { hit in
            var result = toResult(hit)
            result.ownedLocations = locations(hit.label)
            return result
        }
        results.books = rawBooks.map { hit in
            var result = toResult(hit)
            result.isOwnedBook = owned.contains(hit.refKey)
            return result
        }
        results.composers = rawComposers.map(toResult)
        return results
    }

    private func ownedHits(_ ownedBookIds: Set<String>, labels: [String]) throws -> [OwnedHit] {
        if ownedBookIds.isEmpty || labels.isEmpty { return [] }
        var seen = Set<String>()
        let norms = labels.map(SearchNormalizer.normalize).filter { seen.insert($0).inserted }
        return try db.ownedHits(
            queryKeys: ownedBookIds.map { FundstellenQuery.byBook($0).cacheKey },
            titleNorms: norms
        )
    }

    private func isPreferred(_ variants: [EgSongEntity], number: Int, appendix: String?) -> Bool {
        variants.contains { song in
            song.number == number && (song.part == SearchIndexBuilder.stammteil ||
                (appendix.map { song.part.caseInsensitiveCompare($0) == .orderedSame } ?? false))
        }
    }

    /// Komponisten zu Namen wie "Fünfgeld, Traugott", für Links auf ihre Suchergebnisse.
    /// Schlüssel ist der Name. Namen ohne Eintrag (z. B. "NN") fehlen.
    public func composerLinks(names: some Collection<String>) throws -> [String: ComposerLink] {
        let entities = try db.composers(names: Array(Set(names)))
        return Dictionary(entities.map {
            ($0.name, ComposerLink(name: $0.name, id: $0.id, lifeDates: SearchIndexBuilder.lifeDates($0)))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func toResult(_ hit: SearchHit) -> SearchResult {
        let query: FundstellenQuery = switch hit.type {
        case .egSong: .byEgMelody(hit.refNumber ?? 0)
        case .title: .byTitle(Int(hit.refKey) ?? 0)
        case .book: .byBook(hit.refKey)
        case .composer: .byComposer(hit.refKey)
        }
        return SearchResult(label: hit.label, detail: hit.detail, query: query)
    }

    /// "316", "EG 316", "eg316", "EG-316", "„316“". Auf der normalisierten Anfrage, damit Satzzeichen
    /// und Leerraum wie auf Android zählen.
    static func egNumber(_ query: String) -> Int? {
        let norm = SearchNormalizer.normalize(query)
        let range = NSRange(norm.startIndex..., in: norm)
        guard let match = egNumberPattern.firstMatch(in: norm, range: range),
              let r = Range(match.range(at: 1), in: norm) else { return nil }
        return Int(norm[r])
    }

    private static let egNumberPattern = try! NSRegularExpression(pattern: "^(?:eg ?)?([0-9]{1,4})$")
    private static let limitEg = 20
    private static let limitTitles = 50
    private static let limitOther = 20
}
