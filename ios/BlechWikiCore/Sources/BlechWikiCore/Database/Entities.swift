import Foundation

/// `id` ist der numerische Index der API, als Text.
struct BookEntity: Equatable, Sendable {
    var id: String
    /// "buchkurz", Schlüssel für `PieceEntity.bookShortName`. Vergleich ohne Groß-/Kleinschreibung ("nordd5" / "Nordd5").
    var shortName: String
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
    /// "kurz", z. B. "Fünfgeld T". Schlüssel für `PieceEntity.composerShortName`.
    var shortName: String?
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
    /// EG: ix, Titel: normalisierter Titel wie `PieceEntity.titleNorm`, Buch: id, Komponist: id.
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

/// Ein Stück in einem Inventar-Buch mit diesem Titel, für "Bei euch: …" in der Suche.
struct OwnedHit: Equatable, Sendable {
    var titleNorm: String
    var bookId: String
    var bookTitle: String
    var number: String
}

/// Ein Satz zur Melodie `ixUr` in einem Inventar-Buch, für "Bei euch: …" bei EG-Liedern.
struct OwnedMelodyHit: Equatable, Sendable {
    var ixUr: Int
    var bookId: String
    var bookTitle: String
    var number: String
}

/// Stand des letzten Stammdaten-Abgleichs. Genau eine Zeile mit id 0.
struct SyncState: Equatable, Sendable {
    /// Höchster bekannter Änderungszähler je Tabelle, `nil` solange die Tabelle nie geladen wurde.
    var bookChangeCounter: Int?
    var composerChangeCounter: Int?
    /// Höchster bekannter `PieceEntity.counter`, `nil` solange keine Fundstellen da sind.
    var pieceCounter: Int?
    var checkedAtMillis: Int
    /// Letztes vollständiges Neuladen von Büchern, Komponisten und EG.
    var fullSyncAtMillis: Int?
    /// Wann die Fundstellen zuletzt mit dem Server abgeglichen wurden, nach dem Import der
    /// Zeitpunkt des mitgelieferten Stands. Erscheint als „Stand“ auf den Ergebnisseiten.
    var piecesCheckedAtMillis: Int?
    /// Der zuletzt importierte mitgelieferte Stand (`data/fundstellen.stand`). Ein anderer wird neu importiert.
    var importedSnapshot: String?

    static let empty = SyncState(
        bookChangeCounter: nil, composerChangeCounter: nil, pieceCounter: nil, checkedAtMillis: 0,
        fullSyncAtMillis: nil, piecesCheckedAtMillis: nil, importedSnapshot: nil
    )

    var isComplete: Bool { bookChangeCounter != nil && composerChangeCounter != nil && pieceCounter != nil }
}

/// Eine Fundstelle: ein Stück in einem Buch, Zeile aus `Titel?titelzaehler=`. Bücher und
/// Komponisten kommen über ihre Kurznamen dazu, ohne Groß-/Kleinschreibung.
struct PieceEntity: Equatable, Sendable {
    /// Fest und aufsteigend, neue Bücher bekommen höhere Zähler.
    var counter: Int
    var bookShortName: String
    var number: String
    var title: String
    /// Normalisierter Titel für Titel-Treffer und „Bei euch“, siehe SearchNormalizer.
    var titleNorm: String
    var addition: String?
    var keySignature: String?
    /// ix des EG-Lieds, über `eg_songs` zur Melodie (ixUr).
    var egIx: Int?
    var scoring: String?
    var composerShortName: String?
    var composerShortName2: String?
}

/// Eine Fundstelle mit Buch und Komponisten aus den Stammdaten.
struct PieceRow: Equatable, Sendable {
    var counter: Int
    var bookId: String
    var bookTitle: String
    var bookSubtitle: String?
    var coverUrl: String?
    var number: String
    var title: String
    var addition: String?
    var keySignature: String?
    var scoring: String?
    var composerShortName: String?
    var composerShortName2: String?
    /// Name aus der Komponisten-Tabelle, `nil` wenn der Kurzname dort fehlt.
    var composerName: String?
    var composerName2: String?
}
