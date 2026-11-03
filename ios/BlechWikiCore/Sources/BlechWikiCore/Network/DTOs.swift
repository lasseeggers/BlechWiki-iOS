import Foundation

/// Titel ohne Doppel. `ix` ist fest und Schlüssel für die Fundstellen.
///
/// `deleted` und `changeCounter` wie bei allen Stammdaten: Jeder Eintrag trägt den Zähler
/// seiner letzten Änderung. Gelöschte Einträge kommen nur in der Abfrage ab einem Zähler vor.
public struct TitleDto: Equatable, Sendable {
    public var ix: Int
    public var title: String
    public var deleted: Bool
    public var changeCounter: Int
}

public struct BookDto: Equatable, Sendable {
    /// Fester numerischer Index, Schlüssel für die Fundstellen. Kommt von der API als Text.
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
    /// Kleinstes Cover (`mini60`), aus dem Kurznamen des Buchs gebildet.
    public var coverUrl: String
    public var deleted: Bool
    public var changeCounter: Int
}

/// Ein Name eines Komponisten. Schreibvarianten stehen als eigene Einträge mit derselben `id`
/// und `isAlias` = `true` in der Tabelle.
public struct ComposerDto: Equatable, Sendable {
    /// Fester numerischer Index, Schlüssel für die Fundstellen. Kommt von der API als Text.
    public var id: String
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

/// Ein Stück in einem konkreten Buch.
public struct FundstelleDto: Equatable, Sendable {
    /// Wie `BookDto.id`.
    public var bookId: String
    public var bookTitle: String
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
    /// Wie `BookDto.coverUrl`.
    public var coverUrl: String
}
