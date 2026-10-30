import CryptoKit
import Foundation

/// Kurzer Code für ein Inventar, zum Weitergeben per Messenger oder Mail, ohne Server.
/// Muss Byte für Byte mit `InventoryCode.kt` der Android-App übereinstimmen.
///
/// Format: `BBW-SCCC-XXXX-XXXX-…`
/// - `S`: Startwert der Hashfunktion (0 bis 31). Der Absender nimmt den kleinsten, bei dem keines
///   seiner Bücher mit einem anderen Buch im Verzeichnis denselben Hash hat.
/// - `CCC`: Prüfsumme über alle Buch-IDs (15 Bit). Erkennt Tippfehler und löst beim Empfänger
///   Kollisionen auf, die erst durch neue Bücher im Verzeichnis entstehen.
/// - `XXXX`: je Buch die ersten 20 Bit von SHA-256 über Startwert und Buch-ID.
///
/// Zeichen: Crockford-Base32 ohne I, L, O, U. Beim Lesen gelten O als 0 und I, L als 1.
public enum InventoryCode {

    public enum Result: Equatable, Sendable {
        /// Im Text steht kein Code.
        case notFound
        /// Code gefunden, aber beschädigt.
        case invalid
        /// `unknownCount`: Bücher, die im eigenen Verzeichnis fehlen oder nicht eindeutig sind.
        case valid(bookIds: [String], unknownCount: Int)
    }

    public static func encode(_ bookIds: [String], catalog: [String]) -> String {
        precondition(!bookIds.isEmpty, "Leeres Inventar")
        let ids = unique(bookIds)
        let idSet = Set(ids)
        let others = unique(catalog).filter { !idSet.contains($0) }
        let seed = (0..<seedCount).first { seed in
            let own = ids.map { hash(seed, $0) }
            let ownSet = Set(own)
            return ownSet.count == own.count && !others.contains { ownSet.contains(hash(seed, $0)) }
        } ?? 0
        let header = (seed << checksumBits) | checksum(seed, ids)
        let groups = [header] + ids.map { hash(seed, $0) }.sorted()
        return prefix + groups.map { "-" + group($0) }.joined()
    }

    /// Der erste Code in `text`, auch mitten in einer weitergeleiteten Nachricht.
    public static func find(_ text: String) -> String? {
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..., in: upper)
        guard let match = pattern.firstMatch(in: upper, range: range), let r = Range(match.range, in: upper) else { return nil }
        return String(upper[r])
    }

    public static func decode(_ text: String, catalog: [String]) -> Result {
        guard let code = find(text) else { return .notFound }
        var values: [Int] = []
        for part in code.dropFirst(prefix.count).split(whereSeparator: { $0 == "-" || $0 == "–" }) {
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
        let count = candidates.reduce(1) { $0 * $1.count }
        if count > maxCombinations { return [] }
        return candidates.reduce([[]]) { acc, options in
            acc.flatMap { prefix in options.map { prefix + [$0] } }
        }
    }

    private static func group(_ value: Int) -> String {
        String((0..<groupLength).reversed().map { alphabet[(value >> ($0 * 5)) & 31] })
    }

    private static func parseGroup(_ text: Substring) -> Int? {
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
    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }

    private static let prefix = "BBW"
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let readAliases: [Character: Character] = ["O": "0", "I": "1", "L": "1"]
    private static let groupLength = 4
    private static let hashBits = 20
    private static let checksumBits = 15
    private static let seedCount = 32
    private static let maxCombinations = 256

    // Gruppen mit Bindestrich (auch Halbgeviertstrich nach Autokorrektur), ohne angehängte Buchstaben
    private static let pattern = try! NSRegularExpression(pattern: "BBW(?:[-–][0-9A-Z]{4}(?![0-9A-Z]))+")
}
