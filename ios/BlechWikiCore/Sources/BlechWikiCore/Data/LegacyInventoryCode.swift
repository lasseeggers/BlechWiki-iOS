import CryptoKit
import Foundation

/// Altes Format für Inventar-Codes, bis Version 1.1. Neue Codes erzeugt `InventoryCode`, alte
/// müssen weiter lesbar bleiben (siehe docs/ARCHITEKTUR.md, Kompatibilität).
/// Muss Byte für Byte mit `LegacyInventoryCode.kt` der Android-App übereinstimmen.
///
/// Format: `BBW-SCCC-XXXX-XXXX-…`
/// - `S`: Startwert der Hashfunktion (0 bis 31). Der Absender nimmt den kleinsten, bei dem keines
///   seiner Bücher mit einem anderen Buch im Verzeichnis denselben Hash hat.
/// - `CCC`: Prüfsumme über alle Buch-IDs (15 Bit). Erkennt Tippfehler und löst beim Empfänger
///   Kollisionen auf, die erst durch neue Bücher im Verzeichnis entstehen.
/// - `XXXX`: je Buch die ersten 20 Bit von SHA-256 über Startwert und Buch-ID.
///
/// Zeichen: Crockford-Base32 ohne I, L, O, U. Beim Lesen gelten O als 0 und I, L als 1.
enum LegacyInventoryCode {

    typealias Result = InventoryCode.Result

    /// Nur noch für Tests, damit sie alte Codes bauen können.
    static func encode(_ bookIds: [String], catalog: [String]) -> String {
        precondition(!bookIds.isEmpty, "Leeres Inventar")
        let ids = unique(bookIds)
        let idSet = Set(ids.map(bytes))
        let others = unique(catalog).filter { !idSet.contains(bytes($0)) }
        let seed = (0..<seedCount).first { seed in
            let own = ids.map { hash(seed, $0) }
            let ownSet = Set(own)
            return ownSet.count == own.count && !others.contains { ownSet.contains(hash(seed, $0)) }
        } ?? 0
        let header = (seed << checksumBits) | checksum(seed, ids)
        let groups = [header] + ids.map { hash(seed, $0) }.sorted()
        return prefix + groups.map { "-" + group($0) }.joined()
    }

    /// Der Code in `text` (bei mehreren der wahrscheinlichste, siehe `candidates`), auch mitten in
    /// einer weitergeleiteten Nachricht. Andere Striche, Zeilenumbrüche und Zitatzeichen zwischen den
    /// Gruppen sind entfernt: "BBW–0RJT—\n> GA6Y" → "BBW-0RJT-GA6Y". Gruppen nur mit Leerraum davor
    /// bleiben so getrennt.
    static func find(_ text: String) -> String? {
        candidates(in: text).first.map { groups in prefix + groups.map { ($0.dashed ? "-" : " ") + $0.text }.joined() }
    }

    static func decode(_ text: String, catalog: [String]) -> Result {
        // Steht vor dem Code noch Text wie "BBW Chor gibt", zählt der Code, der ganz aufgeht
        var first: Result?
        for groups in candidates(in: text) {
            let result = decode(groups, catalog: catalog)
            if case .valid(_, 0) = result { return result }
            first = first ?? result
        }
        return first ?? .notFound
    }

    private static func decode(_ groups: [Group], catalog: [String]) -> Result {
        // Ein Wort aus vier Zeichen hinter dem Code, nur durch Leerraum getrennt ("… GA6Y Euer Chor"),
        // sieht aus wie eine weitere Gruppe. Solche Gruppen am Ende probeweise weglassen, höchstens
        // `maxTrailingWords`, damit langer Text aus lauter solchen Wörtern nicht ewig dauert.
        var count = groups.count
        while true {
            let result = resolve(groups.prefix(count).map(\.text), catalog: catalog)
            if case .valid(_, 0) = result { return result }
            if count <= 2 || groups[count - 1].dashed || groups.count - count >= maxTrailingWords { break }
            count -= 1
        }
        // Geht der Code nicht ganz auf, zählen nur die Gruppen bis zum letzten Strich. Ohne Striche
        // lässt sich ein Code nicht sicher von Text unterscheiden.
        let dashedCount = (groups.lastIndex(where: \.dashed) ?? -1) + 1
        return dashedCount >= 2 ? resolve(groups.prefix(dashedCount).map(\.text), catalog: catalog) : .invalid
    }

    private static func resolve(_ groups: [String], catalog: [String]) -> Result {
        var values: [Int] = []
        for part in groups {
            guard let value = parseGroup(part) else { return .invalid }
            values.append(value)
        }
        if values.count < 2 { return .invalid }

        let seed = values[0] >> checksumBits
        let expectedChecksum = values[0] & ((1 << checksumBits) - 1)
        var index: [Int: [String]] = [:]
        for id in catalog { index[hash(seed, id), default: []].append(id) }
        let candidates = unique(Array(values.dropFirst())).map { index[$0] ?? [] }
        let unknown = candidates.filter(\.isEmpty).count

        if unknown == 0 {
            // Alle Hashes bekannt: Die Prüfsumme muss stimmen, sonst ist der Code beschädigt
            guard let ids = combinations(candidates).first(where: { checksum(seed, unique($0)) == expectedChecksum }) else {
                return .invalid
            }
            return .valid(bookIds: ids, unknownCount: 0)
        }
        // Mit fehlenden Büchern lässt sich die Prüfsumme nicht nachrechnen. Eindeutige übernehmen.
        // Auch wenn keins bekannt ist: Es können lauter neue Bücher sein, die das Verzeichnis noch nicht hat.
        let resolved = candidates.filter { $0.count == 1 }.map { $0[0] }
        return .valid(bookIds: resolved, unknownCount: candidates.count - resolved.count)
    }

    static func hash(_ seed: Int, _ id: String) -> Int {
        bits(sha256("\(seed):\(nfc(id))"), hashBits)
    }

    private static func checksum(_ seed: Int, _ ids: [String]) -> Int {
        bits(sha256("\(seed)\n" + ids.map(nfc).sorted(by: utf16Less).joined(separator: "\n")), checksumBits)
    }

    private static func combinations(_ candidates: [[String]]) -> [[String]] {
        // Mehrdeutige Hashes sind selten. Die Grenze verhindert eine Explosion bei vielen davon.
        // Schrittweise prüfen: Das ganze Produkt liefe bei sehr vielen davon über.
        var count = 1
        for options in candidates {
            count *= options.count
            if count > maxCombinations { return [] }
        }
        return candidates.reduce([[]]) { acc, options in
            acc.flatMap { prefix in options.map { prefix + [$0] } }
        }
    }

    private static func group(_ value: Int) -> String {
        String((0..<groupLength).reversed().map { alphabet[(value >> ($0 * 5)) & 31] })
    }

    private struct Group {
        var text: String
        /// Vor der Gruppe steht ein Strich, nicht nur Leerraum.
        var dashed: Bool
    }

    /// Mögliche Codes in `text`, der wahrscheinlichste zuerst: geschrieben wie von der App ("BBW-…"),
    /// dann mit mehreren Gruppen, sonst in der Reihenfolge im Text. Eine einzelne Gruppe nur hinter
    /// Leerraum ("BBW Chor") gilt nicht als Code.
    private static func candidates(in text: String) -> [[Group]] {
        let upper = text.uppercased()
        let candidates = pattern.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)).compactMap { match -> [Group]? in
            guard let r = Range(match.range, in: upper) else { return nil }
            var groups: [Group] = []
            var current = String.UnicodeScalarView()
            var dashed = false
            for scalar in upper[r].unicodeScalars.dropFirst(prefix.count) {
                if ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar) {
                    current.append(scalar)
                    if current.count == groupLength {
                        groups.append(Group(text: String(current), dashed: dashed))
                        current = String.UnicodeScalarView()
                        dashed = false
                    }
                } else if dashes.contains(scalar) {
                    dashed = true
                }
            }
            return groups.count >= 2 || groups.first?.dashed == true ? groups : nil
        }
        func rank(_ groups: [Group]) -> Int { groups.count < 2 ? 2 : groups[0].dashed ? 0 : 1 }
        // Stabil sortiert wie `sortedBy` in Kotlin
        return candidates.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func parseGroup(_ text: String) -> Int? {
        guard text.count == groupLength else { return nil }
        var value = 0
        for c in text {
            guard let digit = alphabet.firstIndex(of: readAliases[c] ?? c) else { return nil }
            value = (value << 5) | digit
        }
        return value
    }

    private static func bits(_ digest: SHA256.Digest, _ count: Int) -> Int {
        let bytes = Array(digest.prefix(4))
        let first = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Int(first >> UInt32(32 - count))
    }

    private static func sha256(_ text: String) -> SHA256.Digest { SHA256.hash(data: Data(text.utf8)) }

    // Gleiche Bytes wie auf Android, egal wie Umlaute zusammengesetzt sind
    private static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// Duplikate entfernen, Reihenfolge des ersten Auftretens behalten.
    private static func unique(_ items: [Int]) -> [Int] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Wie `unique`, aber Byte für Byte wie `toSet()` in Kotlin. Swift hielte "ä" und "a" + Trema
    /// für gleich, und beide Apps bauten verschiedene Codes.
    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        return items.filter { seen.insert(bytes($0)).inserted }
    }

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static let prefix = "BBW"
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let readAliases: [Character: Character] = ["O": "0", "I": "1", "L": "1"]
    private static let groupLength = 4
    private static let hashBits = 20
    private static let checksumBits = 15
    private static let seedCount = 32
    private static let maxCombinations = 256
    private static let maxTrailingWords = 5

    // Bindestrich, geschützter Bindestrich, Halbgeviert- und Geviertstrich (Autokorrektur), Minuszeichen
    private static let dashes: Set<Unicode.Scalar> = ["-", "\u{2011}", "\u{2013}", "\u{2014}", "\u{2212}"]
    // Leerraum als feste Liste (Unicode White_Space), weil \s in ICU und Java Verschiedenes meint
    private static let space = #"\t-\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000"#
    // Gruppen mit Strich und/oder Leerraum davor, danach auch Zeilenumbruch und Zitatzeichen
    // umgebrochener Mails ("-\n> "), ohne angehängte Buchstaben. Gleich in LegacyInventoryCode.kt.
    private static let pattern = try! NSRegularExpression(
        pattern: #"BBW(?:(?:[\#(space)]*[\-\u2011\u2013\u2014\u2212]|[\#(space)])[\#(space)>]*[0-9A-Z]{4}(?![0-9A-Z]))+"#
    )
}
