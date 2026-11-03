import CryptoKit
import Foundation

/// Kurzer Code für ein Inventar, zum Weitergeben per Messenger oder Mail, ohne Server.
/// Muss Bit für Bit mit `InventoryCode.kt` der Android-App übereinstimmen.
///
/// Format: `BW2` und danach ein Bitstrom in Crockford-Base32, ohne Striche, damit ein Doppelklick
/// den ganzen Code markiert.
/// - 4 Bit `k`: Ordnung des Exp-Golomb-Codes. Der Absender nimmt die kleinste mit dem kürzesten Code.
/// - 20 Bit Prüfsumme: die ersten 20 Bit von SHA-256 über die IDs, aufsteigend, mit Komma getrennt.
/// - je Buch, aufsteigend, der Abstand zur vorigen ID minus 1 (beim ersten die ID selbst),
///   Exp-Golomb der Ordnung `k`. Bei Reihen ist der Abstand 0 und kostet `k` + 1 Bit.
/// - Nullen bis zum vollen Zeichen. Jedes Codewort enthält eine 1, Nullen am Ende sind kein Buch.
///
/// Der Code enthält die numerischen Buch-IDs (`buchId`) selbst. Der Empfänger braucht kein
/// gleiches Verzeichnis, ein ihm unbekanntes Buch erscheint nach dem nächsten Abgleich.
///
/// Codes im alten Format `BBW-…` liest `LegacyInventoryCode`.
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

    /// Code für die numerischen IDs in `bookIds`, andere zählen nicht. `nil`, wenn keine übrig bleibt.
    public static func encode(_ bookIds: [String]) -> String? {
        let ids = Array(Set(bookIds.compactMap(parseId))).sorted()
        guard !ids.isEmpty else { return nil }
        let gaps = ids.indices.map { ids[$0] - ($0 == 0 ? -1 : ids[$0 - 1]) - 1 }
        func length(_ order: Int) -> Int { gaps.reduce(0) { $0 + expGolombLength($1, order) } }
        // Die kleinste Ordnung mit dem kürzesten Code, wie `minBy` in Kotlin
        var order = 0
        for k in 1...maxOrder where length(k) < length(order) { order = k }
        var bits = BitWriter()
        bits.write(order, orderBits)
        bits.write(checksum(ids), checksumBits)
        for gap in gaps { bits.writeExpGolomb(gap, order) }
        return prefix + bits.base32()
    }

    /// Der Code in `text`, auch mitten in einer weitergeleiteten Nachricht, ohne Trennzeichen und
    /// mit 0 und 1 statt O, I und L: "bw2-08ro8 fj…" → "BW208R08FJ…". Neue Codes vor alten.
    public static func find(_ text: String) -> String? {
        let candidates = Self.candidates(in: text)
        return candidates.first { $0.ids != nil }?.code
            ?? LegacyInventoryCode.find(text)
            ?? candidates.first?.code
    }

    public static func decode(_ text: String, catalog: [String]) -> Result {
        var damaged = false
        for candidate in candidates(in: text) {
            guard let ids = candidate.ids?.map(String.init) else {
                damaged = true
                continue
            }
            let known = Set(catalog)
            let found = ids.filter(known.contains)
            return .valid(bookIds: found, unknownCount: ids.count - found.count)
        }
        let legacy = LegacyInventoryCode.decode(text, catalog: catalog)
        return legacy == .notFound && damaged ? .invalid : legacy
    }

    /// `ids`: `nil`, wenn der Code nicht aufgeht.
    private struct Candidate {
        var code: String
        var ids: [Int]?
    }

    /// Codes im neuen Format in `text`, in der Reihenfolge im Text. Zwischen den Zeichen dürfen
    /// Striche, Leerraum und Zitatzeichen stehen, falls jemand den Code aufteilt oder eine Mail ihn
    /// umbricht. Wo der Code endet, entscheidet die Prüfsumme: Die Teile werden nacheinander
    /// angehängt, bis sie aufgeht. Ein Wort dahinter ("… Euer Chor") bleibt so draußen.
    private static func candidates(in text: String) -> [Candidate] {
        // Einzelne Unicode-Zeichen statt Characters: "\r\n" wäre sonst eines, wie in Kotlin nicht
        let upper = Array(text.uppercased().unicodeScalars)
        let prefixScalars = Array(prefix.unicodeScalars)
        var result: [Candidate] = []
        var at = 0
        while at + prefixScalars.count <= upper.count {
            defer { at += 1 }
            guard Array(upper[at..<at + prefixScalars.count]) == prefixScalars, at == 0 || !isCodeChar(upper[at - 1]) else { continue }
            let start = at + prefixScalars.count
            let parts = Self.parts(upper, start: start)
            var chars: [Unicode.Scalar] = []
            var ids: [Int]?
            for part in parts {
                if part.contains(where: { digit($0) == nil }) || chars.count + part.count > maxLength { break }
                chars += part
                ids = parse(chars)
                if ids != nil { break }
            }
            if let ids {
                result.append(Candidate(code: prefix + String(chars.map { alphabet[digit($0)!] }), ids: ids))
            } else if let first = parts.first, isCodeChar(upper[start]) {
                // Nur angehängte Zeichen gelten als beschädigter Code, sonst ist es Text wie "BW2 ist"
                result.append(Candidate(code: prefix + String(String.UnicodeScalarView(first)), ids: nil))
            }
        }
        return result
    }

    /// Folgen aus Buchstaben und Ziffern ab `start`, getrennt nur durch `separators`.
    private static func parts(_ text: [Unicode.Scalar], start: Int) -> [[Unicode.Scalar]] {
        var parts: [[Unicode.Scalar]] = []
        var i = start
        while true {
            while i < text.count && separators.contains(text[i]) { i += 1 }
            let end = text[i...].firstIndex { !isCodeChar($0) } ?? text.count
            if end == i { return parts }
            parts.append(Array(text[i..<end]))
            i = end
        }
    }

    /// IDs aus den Zeichen hinter `BW2`, `nil`, wenn der Code beschädigt ist.
    private static func parse(_ chars: [Unicode.Scalar]) -> [Int]? {
        var bits = BitReader(chars)
        guard let order = bits.read(orderBits), let expected = bits.read(checksumBits) else { return nil }
        var ids: [Int] = []
        var previous = -1
        while bits.hasOne() {
            var zeros = 0
            while !bits.next() { zeros += 1 }
            guard zeros <= maxZeros, let rest = bits.read(zeros + order) else { return nil }
            let gap = ((1 << (zeros + order)) | rest) - (1 << order)
            previous += gap + 1
            guard previous <= maxId else { return nil }
            ids.append(previous)
        }
        return !ids.isEmpty && checksum(ids) == expected ? ids : nil
    }

    /// Nur Zahlen ohne führende Null, sonst käme beim Empfänger eine andere ID an.
    private static func parseId(_ id: String) -> Int? {
        let utf8 = Array(id.utf8)
        guard (1...10).contains(utf8.count), utf8.allSatisfy({ (48...57).contains($0) }),
              utf8.count == 1 || utf8[0] != 48, let value = Int(id), value <= maxId else { return nil }
        return value
    }

    private static func expGolombLength(_ value: Int, _ order: Int) -> Int {
        let length = Int.bitWidth - (value + (1 << order)).leadingZeroBitCount
        return 2 * length - 1 - order
    }

    private static func checksum(_ ids: [Int]) -> Int {
        let hash = Array(SHA256.hash(data: Data(ids.map(String.init).joined(separator: ",").utf8)))
        let first = Int(hash[0]) << 16 | Int(hash[1]) << 8 | Int(hash[2])
        return first >> (24 - checksumBits)
    }

    private static func isCodeChar(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) || ("A"..."Z").contains(c) }

    private static func digit(_ c: Unicode.Scalar) -> Int? {
        let c = readAliases[c] ?? c
        return alphabet.firstIndex(of: Character(c))
    }

    /// Bitstrom, höchstwertiges Bit zuerst.
    private struct BitWriter {
        private var bits: [Bool] = []

        mutating func write(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }

        mutating func writeExpGolomb(_ value: Int, _ order: Int) {
            let shifted = value + (1 << order)
            let length = Int.bitWidth - shifted.leadingZeroBitCount
            write(0, length - 1 - order)
            write(shifted, length)
        }

        func base32() -> String {
            String(stride(from: 0, to: bits.count, by: 5).map { start in
                let chunk = bits[start..<min(start + 5, bits.count)]
                let value = chunk.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
                return InventoryCode.alphabet[value << (5 - chunk.count)]
            })
        }
    }

    /// Liest die Bits aus gültigen Base32-Zeichen.
    private struct BitReader {
        private let bits: [Bool]
        private var position = 0

        init(_ chars: [Unicode.Scalar]) {
            bits = chars.flatMap { c in
                let value = InventoryCode.digit(c)!
                return (0..<5).reversed().map { (value >> $0) & 1 == 1 }
            }
        }

        func hasOne() -> Bool { bits[position...].contains(true) }

        mutating func next() -> Bool {
            defer { position += 1 }
            return bits[position]
        }

        mutating func read(_ count: Int) -> Int? {
            guard position + count <= bits.count else { return nil }
            var value = 0
            for _ in 0..<count { value = value << 1 | (next() ? 1 : 0) }
            return value
        }
    }

    private static let prefix = "BW2"
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let readAliases: [Unicode.Scalar: Unicode.Scalar] = ["O": "0", "I": "1", "L": "1"]
    private static let orderBits = 4
    private static let maxOrder = 15
    private static let checksumBits = 20
    private static let maxId = Int(Int32.max)
    // Mehr Nullen ergäben eine ID über maxId
    private static let maxZeros = 32
    // Alle 755 Bücher ergeben 220 Zeichen. Die Grenze hält langen Text hinter "BW2" kurz.
    private static let maxLength = 2000

    // Bindestrich, geschützter Bindestrich, Halbgeviert- und Geviertstrich, Minuszeichen, Zitatzeichen
    // umgebrochener Mails und Leerraum als feste Liste (Unicode White_Space). Gleich in InventoryCode.kt.
    private static let separators: Set<Unicode.Scalar> = Set((
        "-\u{2011}\u{2013}\u{2014}\u{2212}>\t\n\u{0B}\u{0C}\r \u{85}\u{A0}\u{1680}"
            + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"
    ).unicodeScalars)
}
