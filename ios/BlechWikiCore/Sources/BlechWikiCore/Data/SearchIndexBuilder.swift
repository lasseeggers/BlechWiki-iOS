import Foundation

/// Baut die Einträge für `search_index` aus den Stammdaten.
enum SearchIndexBuilder {

    static let stammteil = "Stamm"
    private static let alleAnhaenge = "alleAnhänge"
    private static let maxAppendixNumbers = 3

    /// Ein Eintrag pro Lied (`EgSongEntity.ix`), nicht pro EG-Teil.
    static func egSongEntries(_ songs: [EgSongEntity]) -> [SearchEntry] {
        groupedInOrder(songs, by: \.ix).map { variants in
            let song = variants[0]
            return SearchEntry(
                content: SearchNormalizer.indexContent(song.title),
                norm: SearchNormalizer.normalize(song.title),
                label: song.title,
                detail: egNumberLabel(variants),
                type: .egSong,
                refKey: String(song.ix),
                refNumber: song.ixUr
            )
        }
    }

    /// Titel, die schon als EG-Lied im Index stehen, werden übersprungen.
    static func titleEntries(_ titles: [String], egSongs: [EgSongEntity]) -> [SearchEntry] {
        let egNorms = Set(egSongs.map { SearchNormalizer.normalize($0.title) })
        var seen = Set<String>()
        return titles.compactMap { title in
            let norm = SearchNormalizer.normalize(title)
            // API vergleicht Titel ohne Groß-/Kleinschreibung, Duplikate nur in der Schreibweise sind dieselbe Abfrage
            guard !norm.isEmpty, !egNorms.contains(norm), seen.insert(title.lowercased()).inserted else { return nil }
            return SearchEntry(
                content: SearchNormalizer.indexContent(title),
                norm: norm,
                label: title,
                detail: nil,
                type: .title,
                refKey: title,
                refNumber: nil
            )
        }
    }

    static func bookEntries(_ books: [BookEntity]) -> [SearchEntry] {
        books.map { book in
            let detail = [book.subtitle, book.publisher, book.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            return SearchEntry(
                content: SearchNormalizer.indexContent([book.title, book.subtitle].compactMap { $0 }.joined(separator: " ")),
                norm: SearchNormalizer.normalize(book.title),
                label: book.title,
                detail: detail.isEmpty ? nil : detail,
                type: .book,
                refKey: book.id,
                refNumber: nil
            )
        }
    }

    static func composerEntries(_ composers: [ComposerEntity]) -> [SearchEntry] {
        composers.map { composer in
            SearchEntry(
                content: SearchNormalizer.indexContent(composer.name),
                norm: SearchNormalizer.normalize(composer.name),
                label: composer.name,
                detail: lifeDates(composer),
                type: .composer,
                refKey: composer.shortName,
                refNumber: nil
            )
        }
    }

    /// "EG 316" für den Stammteil, "EG 573" für den Anhang der eigenen Landeskirche
    /// (`appendix`), sonst z. B. "EG 573 (NB) · 612 (W)".
    static func egNumberLabel(_ variants: [EgSongEntity], appendix: String? = nil) -> String? {
        if let stamm = variants.first(where: { $0.part == stammteil }) { return "EG \(stamm.number)" }
        // Groß-/Kleinschreibung der Teil-Kürzel ist in der API nicht einheitlich ("Ol" vs. "OL")
        if let appendix, let own = variants.first(where: { $0.part.caseInsensitiveCompare(appendix) == .orderedSame }) {
            return "EG \(own.number)"
        }
        let byNumber = groupedInOrder(variants.filter { $0.part != alleAnhaenge }, by: \.number)
            .sorted { $0[0].number < $1[0].number }
        if byNumber.isEmpty { return nil }
        let shown = byNumber.prefix(maxAppendixNumbers).map { group in
            let parts = Array(Set(group.map(\.part))).sorted(by: utf16Less)
            return "\(group[0].number) (\(parts.joined(separator: ", ")))"
        }.joined(separator: " · ")
        return "EG \(shown)" + (byNumber.count > maxAppendixNumbers ? " …" : "")
    }

    static func lifeDates(_ composer: ComposerEntity) -> String? {
        switch (composer.born, composer.died) {
        case let (born?, died?): return "\(born)–\(died)"
        case let (born?, nil): return "geb. \(born)"
        case let (nil, died?): return "gest. \(died)"
        default: return nil
        }
    }
}

/// Gruppiert wie Kotlins `groupBy`: Gruppen in der Reihenfolge des ersten Auftretens.
public func groupedInOrder<T, K: Hashable>(_ items: [T], by key: (T) -> K) -> [[T]] {
    var index: [K: Int] = [:]
    var groups: [[T]] = []
    for item in items {
        let k = key(item)
        if let i = index[k] {
            groups[i].append(item)
        } else {
            index[k] = groups.count
            groups.append([item])
        }
    }
    return groups
}

/// Sortierung wie `String.compareTo` in Kotlin/Java: UTF-16-Codeeinheiten, ohne Unicode-Normalisierung.
func utf16Less(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}
