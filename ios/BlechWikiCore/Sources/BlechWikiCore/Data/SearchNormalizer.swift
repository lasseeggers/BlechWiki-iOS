import Foundation

/// Bringt Index und Suchanfragen auf dieselbe Form: Kleinbuchstaben, nur a–z und 0–9,
/// Wörter durch ein Leerzeichen getrennt. Damit reicht der einfache FTS4-Tokenizer, und
/// Satzzeichen ("Herr; die" vs. "Herr, die") spielen keine Rolle.
enum SearchNormalizer {

    /// "Lobe den Herren, den mächtigen" → "lobe den herren den machtigen"
    static func normalize(_ text: String) -> String {
        fold(text.lowercased().replacingOccurrences(of: "ß", with: "ss"))
    }

    /// Indexinhalt: `normalize` plus Umschreibung mit ae/oe/ue für Wörter mit Umlaut,
    /// damit sowohl "machtig" als auch "maechtig" trifft.
    static func indexContent(_ text: String) -> String {
        let primary = normalize(text)
        let lower = text.lowercased()
        guard lower.contains("ä") || lower.contains("ö") || lower.contains("ü") else { return primary }
        let primaryTokens = Set(primary.split(separator: " "))
        let extra = transcribe(text).split(separator: " ").filter { !primaryTokens.contains($0) }
        return extra.isEmpty ? primary : primary + " " + extra.joined(separator: " ")
    }

    /// Wie `normalize`, aber Umlaute als ae/oe/ue: "Händel" → "haendel". Gleiche Wortgrenzen wie `normalize`.
    static func transcribe(_ text: String) -> String {
        fold(
            text.lowercased()
                .replacingOccurrences(of: "ä", with: "ae")
                .replacingOccurrences(of: "ö", with: "oe")
                .replacingOccurrences(of: "ü", with: "ue")
                .replacingOccurrences(of: "ß", with: "ss")
        )
    }

    /// FTS-MATCH-Ausdruck: jedes Wort als Präfix, alle Wörter müssen vorkommen. `nil` bei leerer Anfrage.
    /// Jedes Wort nur einmal und höchstens `maxQueryWords`: Einige Tausend Wörter sprengen sonst
    /// den Ausdrucksbaum von FTS ("expression tree is too large").
    static func matchExpression(_ query: String) -> String? {
        var seen = Set<Substring>()
        let tokens = normalize(query).split(separator: " ").filter { seen.insert($0).inserted }.prefix(maxQueryWords)
        return tokens.isEmpty ? nil : tokens.map { "\($0)*" }.joined(separator: " ")
    }

    static let maxQueryWords = 16

    /// Buchstaben, die NFD nicht in Grundbuchstabe und Akzent zerlegt. Ohne Ersatz würden sie zu
    /// Wortgrenzen ("Søren" → "s ren"). Erwartet Kleinbuchstaben.
    private static let letterReplacements: [Unicode.Scalar: String] = [
        "æ": "ae", "ø": "o", "œ": "oe", "ł": "l", "đ": "d", "ı": "i",
        "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st",
    ]

    /// Ersetzt `letterReplacements`, zerlegt Akzente (NFD), entfernt Kombinationszeichen und ersetzt
    /// alles außer a–z und 0–9 durch ein Leerzeichen. Gleiche Regeln wie `Normalizer` + `\p{Mn}` auf Android.
    private static func fold(_ text: String) -> String {
        var replaced = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let replacement = letterReplacements[scalar] {
                replaced.append(contentsOf: replacement.unicodeScalars)
            } else {
                replaced.append(scalar)
            }
        }
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in String(replaced).decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            let v = scalar.value
            if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(result)
    }
}

/// Filter für kleine Listen im Speicher (Buchinhalt, Bücherauswahl). Gleiche Regeln wie die
/// Hauptsuche: Jedes eingegebene Wort muss als Wortanfang vorkommen, Reihenfolge egal,
/// Umlaute als ä, a oder ae.
public struct TextFilter: Sendable {

    private let tokens: [String]
    // Schreibvariante der Eingabe, damit "Händel" auch "Haendel" findet
    private let transcribed: [String]

    public init(_ query: String) {
        tokens = SearchNormalizer.normalize(query).split(separator: " ").map(String.init)
        let transcribed = SearchNormalizer.transcribe(query).split(separator: " ").map(String.init)
        self.transcribed = transcribed.count == tokens.count ? transcribed : tokens
    }

    /// `true` bei leerer Anfrage.
    public var isEmpty: Bool { tokens.isEmpty }

    public func matches(_ fields: String?...) -> Bool { matchesWords(Self.indexWords(fields)) }

    /// Wie `matches`, mit vorab berechneten Wörtern aus `indexWords`. Für große Listen und häufige Eingaben.
    public func matchesWords(_ words: [String]) -> Bool {
        if tokens.isEmpty { return true }
        return tokens.indices.allSatisfy { i in
            words.contains { $0.hasPrefix(tokens[i]) || $0.hasPrefix(transcribed[i]) }
        }
    }

    public static func indexWords(_ fields: [String?]) -> [String] {
        SearchNormalizer.indexContent(fields.compactMap { $0 }.joined(separator: " "))
            .split(separator: " ").map(String.init)
    }
}
