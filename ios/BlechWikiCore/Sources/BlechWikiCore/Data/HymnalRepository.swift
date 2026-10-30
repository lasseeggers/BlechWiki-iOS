import Foundation

/// Gesangbuch zum Blättern: Stammteil und Anhang der gewählten Landeskirche, nach Anlass.
public final class HymnalRepository: Sendable {

    private let db: AppDatabase
    private let settings: SettingsRepository

    public init(db: AppDatabase, settings: SettingsRepository) {
        self.db = db
        self.settings = settings
    }

    /// Neu aufrufen, sobald `DataChanges` eine Änderung meldet (Abgleich, Landeskirche gewechselt).
    public func hymnal() throws -> Hymnal {
        let appendix = try settings.selectedEgAppendix()
        return Hymnal(appendix: appendix, sections: HymnalSections.build(try db.hymnalSongs(appendix: appendix?.code)))
    }
}

enum HymnalSections {

    static let fallbackOccasion = "Weitere Lieder"

    /// Abschnitte in der Reihenfolge, in der die Anlässe im Stammteil vorkommen. Lieder aus dem
    /// Anhang kommen in den Abschnitt mit gleichem Anlass. Im Anhang wechseln die Anlässe
    /// ständig (Niedersachsen/Bremen: 53 Wechsel bei 27 Anlässen), eine Überschrift bei jedem
    /// Wechsel wäre unübersichtlich. Anlässe, die es nur im Anhang gibt, stehen am Ende.
    static func build(_ songs: [EgSongEntity]) -> [HymnalSection] {
        var seen = Set<String>()
        let unique = songs.filter { seen.insert("\($0.part.lowercased())|\($0.number)|\($0.ix)").inserted }
        let stamm = unique.filter { $0.part == SearchIndexBuilder.stammteil }
        let appendix = unique.filter { $0.part != SearchIndexBuilder.stammteil }
        let ordered = sortedByNumber(stamm) + sortedByNumber(appendix)
        return groupedInOrder(ordered, by: occasion).map { group in
            HymnalSection(
                occasion: occasion(group[0]),
                songs: group.map { song in
                    HymnalSong(
                        ix: song.ix, ixUr: song.ixUr, title: song.title, number: song.number,
                        isAppendix: song.part != SearchIndexBuilder.stammteil
                    )
                }
            )
        }
    }

    /// Stabil wie Kotlins `sortedBy`: Gleiche Nummern behalten ihre Reihenfolge.
    private static func sortedByNumber(_ songs: [EgSongEntity]) -> [EgSongEntity] {
        songs.enumerated()
            .sorted { $0.element.number != $1.element.number ? $0.element.number < $1.element.number : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Anlass ist in der API teils mit Zeilenumbruch oder doppelten Leerzeichen gespeichert.
    private static func occasion(_ song: EgSongEntity) -> String {
        let cleaned = (song.occasion ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? fallbackOccasion : cleaned
    }
}
