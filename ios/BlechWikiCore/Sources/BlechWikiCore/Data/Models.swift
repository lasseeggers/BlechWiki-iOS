import Foundation

/// Was die Fundstellen-Ansicht laden soll. `cacheKey` identifiziert den Eintrag im Cache.
public enum FundstellenQuery: Hashable, Sendable {
    /// `ix` des Titels.
    case byTitle(Int)
    /// Alle Sätze zu einer EG-Melodie, auch unter anderen Liedtexten.
    case byEgMelody(Int)
    case byBook(String)
    /// `id` des Komponisten.
    case byComposer(String)

    public var cacheKey: String {
        switch self {
        case .byTitle(let ix): "title:\(ix)"
        case .byEgMelody(let ixUr): "eg:\(ixUr)"
        case .byBook(let bookId): "book:\(bookId)"
        case .byComposer(let id): "composer:\(id)"
        }
    }
}

public struct SearchResult: Hashable, Sendable {
    public var label: String
    /// Zusatzzeile, z. B. "EG 316", Verlag oder Lebensdaten.
    public var detail: String?
    public var query: FundstellenQuery
    /// Wo das Stück im Inventar steht. Nur für bereits geladene Bücher.
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
