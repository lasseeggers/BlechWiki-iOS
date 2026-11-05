import Foundation

/// Baut die Einträge für `search_index` aus den Stammdaten.
enum SearchIndexBuilder {

    static let stammteil = "Stamm"
    /// Lieder, die auch unter einem anderen, meist englischen Titel bekannt sind. Ihre Nummern
    /// (601 bis 611) sind keine EG-Nummern. `ixUr` ist der `ix` des Lieds im EG.
    static let ergaenzungen = "Add"
    private static let maxAppendixNumbers = 3

    /// Ein Eintrag pro Lied (`EgSongEntity.ix`), nicht pro EG-Teil.
    static func egSongEntries(_ songs: [EgSongEntity]) -> [SearchEntry] {
        let byIx = Dictionary(grouping: songs, by: \.ix)
        return groupedInOrder(songs, by: \.ix).map { variants in
            let song = variants[0]
            return SearchEntry(
                content: SearchNormalizer.indexContent(song.title),
                norm: SearchNormalizer.normalize(song.title),
                label: song.title,
                detail: egSongDetail(variants, byIx: byIx),
                type: .egSong,
                refKey: String(song.ix),
                refNumber: song.ixUr
            )
        }
    }

    /// Ein Eintrag je normalisiertem Titel aus `titles` (Titel aller Fundstellen, mit Doppeln).
    /// Schreibweisen wie „heiligen“ und „Heiligen“ werden ein Treffer, angezeigt in der häufigsten.
    /// Titel, die schon als EG-Lied im Index stehen, werden übersprungen.
    static func titleEntries(_ titles: [String], egSongs: [EgSongEntity]) -> [SearchEntry] {
        let egNorms = Set(egSongs.map { SearchNormalizer.normalize($0.title) })
        return groupedInOrder(titles, by: SearchNormalizer.normalize).compactMap { spellings in
            let norm = SearchNormalizer.normalize(spellings[0])
            guard !norm.isEmpty, !egNorms.contains(norm) else { return nil }
            // Bei Gleichstand die erste in UTF-16-Ordnung, wie auf Android
            let counts = Dictionary(spellings.map { ($0, 1) }, uniquingKeysWith: +)
            let label = counts.sorted { $0.value != $1.value ? $0.value > $1.value : utf16Less($0.key, $1.key) }[0].key
            return SearchEntry(
                content: SearchNormalizer.indexContent(label),
                norm: norm,
                label: label,
                detail: nil,
                type: .title,
                refKey: norm,
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
                refKey: composer.id,
                refNumber: nil
            )
        }
    }

    /// "EG 316" für den Stammteil, "EG 573" für den Anhang der eigenen Landeskirche
    /// (`appendix`), sonst z. B. "EG 573 (NB) · 612 (W)".
    static func egNumberLabel(_ allVariants: [EgSongEntity], appendix: String? = nil) -> String? {
        let variants = allVariants.filter { $0.part != ergaenzungen }
        if let stamm = variants.first(where: { $0.part == stammteil }) { return "EG \(stamm.number)" }
        // Groß-/Kleinschreibung der Teil-Kürzel ist in der API nicht einheitlich ("Ol" vs. "OL")
        if let appendix, let own = variants.first(where: { $0.part.caseInsensitiveCompare(appendix) == .orderedSame }) {
            return "EG \(own.number)"
        }
        let byNumber = groupedInOrder(variants, by: \.number)
            .sorted { $0[0].number < $1[0].number }
        if byNumber.isEmpty { return nil }
        let shown = byNumber.prefix(maxAppendixNumbers).map { group in
            let parts = Array(Set(group.map(\.part))).sorted(by: utf16Less)
            return "\(group[0].number) (\(parts.joined(separator: ", ")))"
        }.joined(separator: " · ")
        return "EG \(shown)" + (byNumber.count > maxAppendixNumbers ? " …" : "")
    }

    /// Wie `egNumberLabel`. Für Lieder aus den Ergänzungen der Verweis auf das Lied im EG, z. B.
    /// „im EG als „Komm, sag es allen weiter“, EG 225“. `byIx` muss das Lied mit `ix` = `ixUr` enthalten.
    static func egSongDetail(_ variants: [EgSongEntity], byIx: [Int: [EgSongEntity]], appendix: String? = nil) -> String? {
        guard let song = variants.first else { return nil }
        if variants.contains(where: { $0.part != ergaenzungen }) { return egNumberLabel(variants, appendix: appendix) }
        let original = (byIx[song.ixUr] ?? []).filter { $0.part != ergaenzungen }
        guard let title = original.first?.title else { return nil }
        return ["im EG als „\(title)“", egNumberLabel(original, appendix: appendix)].compactMap { $0 }.joined(separator: ", ")
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
