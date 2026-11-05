import Foundation

/// Was die Fundstellen-Ansicht zeigen soll. `cacheKey` identifiziert die Abfrage als Text.
public enum FundstellenQuery: Hashable, Sendable {
    /// Alle Stücke mit diesem Titel, normalisiert (SearchNormalizer), also auch in anderer Schreibweise.
    case byTitle(String)
    /// Alle Sätze zu einer EG-Melodie, auch unter anderen Liedtexten.
    case byEgMelody(Int)
    case byBook(String)
    /// `id` des Komponisten.
    case byComposer(String)

    public var cacheKey: String {
        switch self {
        case .byTitle(let titleNorm): "title:\(titleNorm)"
        case .byEgMelody(let ixUr): "eg:\(ixUr)"
        case .byBook(let bookId): "book:\(bookId)"
        case .byComposer(let id): "composer:\(id)"
        }
    }

    /// Titel-Abfrage für einen angezeigten Titel wie "Herr, das Licht deiner Liebe".
    public static func title(_ title: String) -> FundstellenQuery {
        .byTitle(SearchNormalizer.normalize(title))
    }
}

public struct SearchResult: Hashable, Sendable {
    public var label: String
    /// Zusatzzeile, z. B. "EG 316", Verlag oder Lebensdaten.
    public var detail: String?
    public var query: FundstellenQuery
    /// EG-Treffer: `ix` des Lieds. `query` nennt nur die Melodie, zu der mehrere Lieder gehören können.
    public var egIx: Int?
    /// Wo das Stück im Inventar steht, bei EG-Liedern alle Sätze zur Melodie.
    public var ownedLocations: [OwnedLocation] = []
    /// Für Buch-Treffer: steht im Inventar.
    public var isOwnedBook = false
}

public struct OwnedLocation: Hashable, Sendable {
    public var bookTitle: String
    public var number: String
}

public struct SearchResults: Equatable, Sendable {
    public var egSongs: [SearchResult] = []
    public var titles: [SearchResult] = []
    public var books: [SearchResult] = []
    public var composers: [SearchResult] = []

    public init() {}

    public var isEmpty: Bool { egSongs.isEmpty && titles.isEmpty && books.isEmpty && composers.isEmpty }
}

public struct Fundstelle: Hashable, Sendable {
    public var bookId: String
    public var bookTitle: String
    public var bookSubtitle: String?
    public var number: String
    public var title: String
    public var addition: String?
    public var composer: String?
    public var scoring: String?
    public var keySignature: String?
    public var coverUrl: String?
}

/// Komponist, auf dessen Suchergebnisse ein Name verlinkt. `lifeDates` wie im Komponisten-Treffer der Suche.
public struct ComposerLink: Hashable, Sendable {
    public var name: String
    public var id: String
    public var lifeDates: String?
}

/// Namen, wie sie in Fundstellen und Büchern stehen.
public enum ComposerNames {

    /// Komponistenfeld einer Fundstelle, z. B. "Gershwin, George // Hahn, Jürgen".
    public static func split(_ field: String) -> [String] {
        field.components(separatedBy: " // ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Herausgeber stehen als "Traugott Fünfgeld" in den Buchdaten, Komponisten als
    /// "Fünfgeld, Traugott". Letztes Wort wird Nachname, auch bei "Ben van den Bosch" → "Bosch, Ben van den".
    public static func fromEditor(_ editor: String) -> String? {
        let trimmed = editor.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " "), space > trimmed.startIndex else { return nil }
        let first = trimmed[..<space].trimmingCharacters(in: .whitespaces)
        return "\(trimmed[trimmed.index(after: space)...]), \(first)"
    }
}

public struct EgAppendix: Hashable, Sendable, Identifiable {
    public var code: String
    public var name: String
    public var id: String { code }
}

/// Ein Lied in der Gesangbuch-Übersicht. `number` im Stammteil oder im Anhang der Landeskirche.
public struct HymnalSong: Hashable, Sendable, Identifiable {
    public var ix: Int
    public var ixUr: Int
    public var title: String
    public var number: Int
    public var isAppendix: Bool
    public var id: String { "\(isAppendix)-\(number)-\(ix)" }
}

/// Lieder zu einem Anlass wie „Advent“ oder „Abend“, Stammteil vor Anhang, jeweils nach Nummer.
public struct HymnalSection: Hashable, Sendable, Identifiable {
    public var occasion: String
    public var songs: [HymnalSong]
    public var id: String { occasion }
}

/// Stammteil plus Anhang von `appendix`, in der Reihenfolge der Anlässe im Stammteil.
public struct Hymnal: Equatable, Sendable {
    public var appendix: EgAppendix?
    public var sections: [HymnalSection]
}

public struct BookItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var year: Int?
    /// Herausgeber, Vorname vorangestellt.
    public var editor: String?
    public var publisher: String?
    /// Bestellnummer beim Verlag.
    public var publisherNumber: String?
    public var coverUrl: String?
    public var isOwned: Bool
    /// Titel, Untertitel, Herausgeber und Verlag wie von `SearchNormalizer.indexContent`, zum Filtern.
    public var searchText: String
}

/// Auswahlliste für das Inventar. Bei aktivem Filter ist nur `filtered` gesetzt.
public struct BookSections: Equatable, Sendable {
    public var suggested: [BookItem] = []
    public var choralBooks: [BookItem] = []
    public var all: [BookItem] = []
    public var filtered: [BookItem]?
}

/// Was ein eingefügter Inventar-Code enthält.
public enum InventoryImport: Equatable, Sendable {
    case noCode
    case invalid
    /// `books` in Verzeichnisreihenfolge. `unknownCount`: Bücher, die das eigene Verzeichnis nicht kennt.
    case ready(books: [BookItem], unknownCount: Int)
}

public struct OfflineStatus: Equatable, Sendable {
    public var owned: Int
    public var available: Int

    public init(owned: Int, available: Int) {
        self.owned = owned
        self.available = available
    }
}

/// Zustand des Stammdaten-Abgleichs, wie ihn die UI braucht.
public enum SyncStatus: Equatable, Sendable {
    case idle
    case running
    /// Wartet auf den nächsten Versuch nach einem Fehler.
    case waiting(afterFailure: Bool)
    case failed
}

/// Art eines Listeneintrags, so steht sie in der Datenbank.
public enum ListEntryKind: String, Sendable {
    case title, piece, eg
}

/// Was in eine Liste kommt, mit den Rohfeldern, aus denen `ListEntryKey` den Schlüssel bildet.
/// Die Felder zur Anzeige werden mitgespeichert, damit ein Eintrag auch ohne Stammdaten lesbar bleibt.
public enum ListEntryRef: Hashable, Sendable {
    /// Lied unabhängig vom Buch, aus einem Titel-Treffer.
    case title(String)
    /// Konkrete Fundstelle: dieses Stück in diesem Buch.
    case piece(bookId: String, bookTitle: String, number: String, title: String, addition: String?)
    /// EG-Lied. `label` ist die Nummer, wie sie beim Hinzufügen zu sehen war, z. B. „EG 316“.
    case eg(ix: Int, ixUr: Int, title: String, label: String?)

    public var key: String {
        switch self {
        case .title(let title): ListEntryKey.title(title)
        case let .piece(bookId, _, number, title, addition): ListEntryKey.piece(bookId: bookId, number: number, title: title, addition: addition)
        case .eg(let ix, _, _, _): ListEntryKey.eg(ix: ix)
        }
    }

    public var kind: ListEntryKind {
        switch self {
        case .title: .title
        case .piece: .piece
        case .eg: .eg
        }
    }

    public var title: String {
        switch self {
        case .title(let title): title
        case .piece(_, _, _, let title, _): title
        case .eg(_, _, let title, _): title
        }
    }
}

/// Eine Liste in der Übersicht.
public struct ListSummary: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var entryCount: Int

    public var isFavorites: Bool { id == ListsRepository.favoritesId }
}

/// Ein Eintrag einer Liste, ergänzt um den aktuellen Stand des Verzeichnisses und des Inventars.
public struct ListEntryItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var ref: ListEntryRef
    public var comment: String?
    /// Bei EG-Liedern und Fundstellen aus dem Verzeichnis, sonst wie gespeichert.
    public var title: String
    /// Titel: in wie vielen Büchern ein Stück mit diesem Titel steht.
    public var bookCount: Int?
    /// Titel und EG-Lieder: wo das Lied im Inventar steht, bei EG-Liedern alle Sätze zur Melodie.
    public var ownedLocations: [OwnedLocation] = []
    /// EG-Lieder: Nummer passend zur Landeskirche, z. B. „EG 316“.
    public var egNumber: String?
    /// Fundstellen: Buch, Nummer im Heft und Zusatz wie „Vorspiel“.
    public var bookTitle: String?
    public var number: String?
    public var addition: String?
    public var coverUrl: String?
    /// Fundstelle, die es im Verzeichnis nicht mehr gibt.
    public var isMissing = false
    /// Fundstelle in einem Buch aus dem Inventar.
    public var isOwnedBook = false
}

public struct ListDetail: Equatable, Sendable {
    public var id: String
    public var name: String
    public var entries: [ListEntryItem]

    public var isFavorites: Bool { id == ListsRepository.favoritesId }
}
