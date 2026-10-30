import Foundation

/// Höchste vergebene AutoNr je Tabelle. Ändert sich ein Wert, gibt es neue Einträge
/// und die zugehörigen Stammdaten müssen neu geladen werden.
public struct DataVersionDto: Equatable, Sendable {
    public var lastBookNumber: Int
    public var lastComposerNumber: Int
    public var lastTitleNumber: Int
}

public struct BookDto: Equatable, Sendable {
    /// Kurzbezeichnung, Schlüssel für `GetBuchFundstellen`. Kann Leerzeichen und Umlaute enthalten.
    public var id: String
    public var title: String
    public var subtitle: String?
    /// `nil`, wenn die API 0 oder nichts liefert.
    public var year: Int?
    /// Nachname bzw. Institution, Vorname steht in `editorFirstName`.
    public var editor: String?
    public var editorFirstName: String?
    public var publisher: String?
    public var publisherNumber: String?
    public var coverUrl: String?
}

public struct ComposerDto: Equatable, Sendable {
    public var name: String
    /// Schlüssel für `GetKomponistFundstellen`, z. B. "Fünfgeld T".
    public var shortName: String
    public var born: String?
    public var died: String?
}

public struct EgAppendixDto: Equatable, Sendable {
    /// z. B. "NB", "Stamm".
    public var code: String
    public var name: String
}

public struct EgSongDto: Equatable, Sendable {
    public var ix: Int
    /// Schlüssel für `GetEGLiederFundstellen`. Gleich für alle Anhangs-Einträge desselben Lieds.
    public var ixUr: Int
    public var title: String
    /// Anhang-Kürzel wie in `EgAppendixDto.code`, zusätzlich "alleAnhänge" und "Add".
    /// Schreibweise nicht immer konsistent ("Ol" vs. "OL").
    public var part: String
    /// Liednummer im jeweiligen Teil. 9999 bei `part` "alleAnhänge".
    public var number: Int
    public var occasion: String?
}

/// Ein Stück in einem konkreten Buch.
public struct FundstelleDto: Equatable, Sendable {
    public var bookId: String
    public var bookTitle: String
    public var bookSubtitle: String?
    /// Nummer im Buch. Text, weil nicht garantiert numerisch.
    public var number: String
    public var title: String
    /// Zusatz wie "Vorspiel" oder "Satz 2".
    public var addition: String?
    /// Rohwert, mehrere Personen durch " // " getrennt.
    public var composer: String?
    /// Besetzung, z. B. "2+2" oder "3+3".
    public var scoring: String?
    /// Vorzeichen, z. B. "1b", "0", "2#".
    public var keySignature: String?
    public var coverUrl: String?
}
