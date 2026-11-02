import Foundation

/// Ordnet Bücher grob einer Landeskirche zu, anhand von Wörtern in Titel, Untertitel,
/// Herausgeber und Verlag. Trifft laut Datenbestand etwa 120 der 786 Bücher, vor allem die
/// Jahreshefte ("Bläserheft 2022 Bayern") und regionale Choralbücher. Nur für Vorschläge
/// gedacht, nicht als verlässliche Zuordnung.
enum RegionKeywords {

    /// Schlüssel: EG-Anhang-Kürzel in Großbuchstaben. Werte: Wortanfänge in normalisierter Form.
    private static let keywords: [String: [String]] = [
        "BEL": ["baden", "elsass", "lothringen"],
        "BT": ["bayern", "bayerisch", "thuringen", "thuringisch"],
        "HN": ["hessen", "nassau", "ekhn"],
        "KW": ["kurhessen", "waldeck", "ekkw"],
        "M": ["mecklenburg", "nordkirche"],
        "NB": ["niedersachsen", "niedersachsisch", "hannover", "bremen", "bremisch", "braunschweig", "schaumburg"],
        "N": ["nordelbien", "nordelbisch", "nordkirche", "hamburg", "schleswig"],
        "OL": ["oldenburg"],
        "Ö": ["osterreich"],
        "P": ["pfalz", "pfalzisch"],
        "R": ["reformiert"],
        "RWL": ["rheinland", "rheinisch", "westfalen", "westfalisch", "lippe", "lippisch"],
        "W": ["wurttemberg", "wurttembergisch"],
    ]

    /// `normalizedText` wie von `SearchNormalizer.normalize` oder `indexContent`.
    static func matches(_ normalizedText: String, appendixCode: String) -> Bool {
        let code = appendixCode.uppercased()
        guard let words = keywords[code] else { return false }
        // Kürzel wie "RWL" oder "NB" stehen in Titeln wie "EG Anhang NB" als eigenes Wort
        let codeToken = code.count >= 2 ? code.lowercased() : nil
        return normalizedText.split(separator: " ").contains { token in
            token == codeToken.map { Substring($0) } || words.contains { token.hasPrefix($0) }
        }
    }
}

/// Die Netzwerkschicht liefert das kleinste Cover (`…/BilderBuch/mini60/<Kurzname>.jpg`,
/// 42 × 60 px). Laut Betreiber gibt es jedes Cover außerdem als `mini120/` (83 × 120 px,
/// ca. 24 KB), `mini240/` und im Original direkt unter `BilderBuch/` (ca. 1000 × 1444 px,
/// ca. 200 KB). Aufrufer sollten bei einem Ladefehler auf die `mini60`-URL zurückfallen.
public enum CoverUrls {

    private static let apiSize = "/mini60/"

    /// Für Listen.
    public static func thumbnail(_ apiUrl: String?) -> URL? {
        apiUrl.flatMap { URL(string: $0.replacingOccurrences(of: apiSize, with: "/mini120/")) }
    }

    /// Für die große Darstellung im Buchkopf und die Vollbildansicht.
    public static func full(_ apiUrl: String?) -> URL? {
        apiUrl.flatMap { URL(string: $0.replacingOccurrences(of: apiSize, with: "/")) }
    }

    public static func api(_ apiUrl: String?) -> URL? {
        apiUrl.flatMap { URL(string: $0) }
    }
}
