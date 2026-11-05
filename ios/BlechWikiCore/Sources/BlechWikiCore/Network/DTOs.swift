import Foundation

/// `deleted` und `changeCounter` wie bei allen Stammdaten: Jeder Eintrag trägt den Zähler
/// seiner letzten Änderung. Gelöschte Einträge kommen nur in der Abfrage ab einem Zähler vor.
public struct BookDto: Equatable, Sendable {
    /// Fester numerischer Index. Kommt von der API als Text.
    public var id: String
    /// "buchkurz", z. B. "WBH2025". Schlüssel für `PieceDto.bookShortName`, Groß-/Kleinschreibung weicht dort ab.
    public var shortName: String
    public var title: String
    public var subtitle: String?
    /// `nil`, wenn die API 0 oder nichts liefert.
    public var year: Int?
    /// Nachname bzw. Institution, Vorname steht in `editorFirstName`.
    public var editor: String?
    public var editorFirstName: String?
    public var publisher: String?
    public var publisherNumber: String?
    /// Kleinstes Cover (`mini60`), aus dem Kurznamen des Buchs gebildet.
    public var coverUrl: String
    public var deleted: Bool
    public var changeCounter: Int
}

/// Ein Name eines Komponisten. Schreibvarianten stehen als eigene Einträge mit derselben `id`
/// und `isAlias` = `true` in der Tabelle.
public struct ComposerDto: Equatable, Sendable {
    /// Fester numerischer Index. Kommt von der API als Text.
    public var id: String
    /// "kurz", z. B. "Fünfgeld T", gleich für alle Schreibvarianten. Schlüssel für `PieceDto.composerShortName`.
    public var shortName: String?
    /// "Nachname, Vorname", so wie der Name in den Fundstellen steht.
    public var name: String
    /// z. B. "1685", "um 1600" oder `nil`.
    public var born: String?
    public var died: String?
    public var isAlias: Bool
    public var deleted: Bool
    public var changeCounter: Int
}

/// Antwort einer Nachschlagetabelle (Titel, Bücher, Komponisten). `maxCounter` ist der höchste
/// Änderungszähler aller gelieferten Einträge, auch der übersprungenen, denen ein Pflichtfeld
/// fehlt, und 0 bei leerer Antwort. Der Abgleich merkt sich diesen Zähler, sonst käme ein
/// unlesbarer Eintrag bei jedem Abgleich wieder.
public struct TableRows<T: Sendable>: Sendable {
    public var rows: [T]
    public var maxCounter: Int

    public init(rows: [T], maxCounter: Int) {
        self.rows = rows
        self.maxCounter = maxCounter
    }
}

extension TableRows: Equatable where T: Equatable {}

public struct EgAppendixDto: Equatable, Sendable {
    /// z. B. "NB", "Stamm", "Add".
    public var code: String
    public var name: String
}

public struct EgSongDto: Equatable, Sendable {
    public var ix: Int
    /// Melodie, Schlüssel für die Fundstellen. Gleich für alle Lieder nach derselben Melodie.
    public var ixUr: Int
    public var title: String
    /// Teil-Kürzel wie in `EgAppendixDto.code`.
    /// Schreibweise nicht immer wie dort ("Ol" vs. "OL").
    public var part: String
    /// Liednummer im jeweiligen Teil.
    public var number: Int
    public var occasion: String?
}

/// Ein Stück in einem konkreten Buch, eine Zeile aus `Titel?titelzaehler=`.
public struct PieceDto: Equatable, Sendable {
    /// "Zähler", fest und aufsteigend. Gleich `titelZ` in `Buch/{id}`.
    public var counter: Int
    /// "Quelle_kurz", wie `BookDto.shortName`.
    public var bookShortName: String
    /// Nummer im Buch.
    public var number: String
    public var title: String
    /// Zusatz wie "Vorspiel" oder "Satz 2".
    public var addition: String?
    /// Vorzeichen, z. B. "1b", "0", "2#".
    public var keySignature: String?
    /// `EgSongDto.ix` des Lieds, `nil` wenn es kein EG-Lied ist.
    public var egIx: Int?
    /// Besetzung, z. B. "2+2" oder "3+3".
    public var scoring: String?
    /// Wie `ComposerDto.shortName`.
    public var composerShortName: String?
    /// Zweiter Komponist oder Bearbeiter.
    public var composerShortName2: String?
}
