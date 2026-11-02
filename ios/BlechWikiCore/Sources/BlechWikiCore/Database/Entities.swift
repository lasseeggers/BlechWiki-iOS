import Foundation

/// Titel ohne Doppel. `ix` ist der Schlüssel für die Fundstellen.
struct TitleEntity: Equatable, Sendable {
    var ix: Int
    var title: String
}

/// `id` ist der numerische Index der API, als Text.
struct BookEntity: Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var year: Int?
    var editor: String?
    var publisher: String?
    var publisherNumber: String?
    var coverUrl: String?
}

/// `id` ist der numerische Index der API, als Text. Schreibvarianten des Namens sind nicht gespeichert.
struct ComposerEntity: Equatable, Sendable {
    var id: String
    var name: String
    var born: String?
    var died: String?
}

/// Ein Eintrag pro Lied und EG-Teil. `ix` identifiziert das Lied, `ixUr` die Melodie.
/// Mehrere Lieder können dieselbe Melodie haben.
struct EgSongEntity: Equatable, Sendable {
    var ix: Int
    var ixUr: Int
    var title: String
    var part: String
    var number: Int
    var occasion: String?
}

struct EgAppendixEntity: Equatable, Sendable {
    var code: String
    var name: String
}

/// Eintrag im Volltextindex über EG-Lieder, Titel, Bücher und Komponisten. Nur `content`
/// wird indiziert, die übrigen Spalten dienen Sortierung und Anzeige.
struct SearchEntry: Equatable, Sendable {
    /// Normalisierter Text plus Schreibvarianten (ä → a und ae), siehe SearchNormalizer.
    var content: String
    /// Normalisierte Hauptform des Labels, für Ranking.
    var norm: String
    var label: String
    var detail: String?
    var type: SearchEntryType
    /// EG: ix, Titel: ix, Buch: id, Komponist: id.
    var refKey: String
    /// EG: ixUr (Melodie), sonst nil.
    var refNumber: Int?
}

enum SearchEntryType: Int, Sendable {
    case egSong = 0
    case title = 1
    case book = 2
    case composer = 3
}

struct SearchHit: Equatable, Sendable {
    var label: String
    var detail: String?
    var type: SearchEntryType
    var refKey: String
    var refNumber: Int?
}

/// Ein Stück in einem gecachten Buch, für "Im Inventar: …" in der Suche.
struct OwnedHit: Equatable, Sendable {
    var titleNorm: String
    var bookId: String
    var bookTitle: String
    var number: String
}

/// Stand des letzten Stammdaten-Abgleichs. Genau eine Zeile mit id 0.
struct SyncState: Equatable, Sendable {
    /// Höchster bekannter Änderungszähler je Tabelle, `nil` solange die Tabelle nie geladen wurde.
    var titleChangeCounter: Int?
    var bookChangeCounter: Int?
    var composerChangeCounter: Int?
    var checkedAtMillis: Int
    /// Letztes vollständiges Neuladen aller Tabellen.
    var fullSyncAtMillis: Int?

    var isComplete: Bool { titleChangeCounter != nil && bookChangeCounter != nil && composerChangeCounter != nil }
}

/// Gecachte Fundstelle, gespeichert pro Abfrage in API-Reihenfolge.
struct FundstelleEntity: Equatable, Sendable {
    var queryKey: String
    var position: Int
    var bookId: String
    var bookTitle: String
    var bookSubtitle: String?
    var number: String
    var title: String
    /// Normalisierter Titel, damit die Suche Treffer in eigenen Büchern findet.
    var titleNorm: String
    var addition: String?
    var composer: String?
    var scoring: String?
    var keySignature: String?
    var coverUrl: String?
}

struct FetchState: Equatable, Sendable {
    var queryKey: String
    var fetchedAtMillis: Int
    /// `titleChangeCounter` zum Abrufzeitpunkt. Weicht er vom aktuellen ab, gilt der Cache als veraltet.
    var titleVersion: Int?
}
