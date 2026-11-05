import Compression
import Foundation

/// Mitgelieferter Stand aller Fundstellen, erzeugt von `scripts/fundstellen-stand.sh`. Erspart
/// einer neuen Installation 7,5 MB vom Server, der kein gzip kann. Wie `PieceSnapshot` auf Android.
public protocol PieceSnapshot: Sendable {
    /// Zeitpunkt des Stands (ISO 8601), `nil` ohne mitgelieferten Stand. Liest nur eine kleine Datei.
    func stand() -> String?

    /// Alle Zeilen, ca. 7,5 MB JSON. Nur lesen, wenn `stand` neu ist.
    func pieces() throws -> [PieceDto]
}

/// Für Tests und Builds ohne Stand (öffentliches Repo): Die Fundstellen kommen dann vom Server.
public struct NoPieceSnapshot: PieceSnapshot {
    public init() {}
    public func stand() -> String? { nil }
    public func pieces() throws -> [PieceDto] { [] }
}

/// Liest `fundstellen.stand` und `fundstellen.json.gz` aus dem App-Bundle. Die Build-Phase
/// „Fundstellen-Stand“ kopiert sie aus `data/`.
public struct BundlePieceSnapshot: PieceSnapshot {

    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func stand() -> String? {
        guard let url = bundle.url(forResource: "fundstellen", withExtension: "stand"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func pieces() throws -> [PieceDto] {
        guard let url = bundle.url(forResource: "fundstellen.json", withExtension: "gz") else { return [] }
        return try JsonBlechWikiAPI.parsePieces(try Gzip.decompress(Data(contentsOf: url)))
    }
}

/// Entpackt gzip (RFC 1952). `NSData.decompressed(using: .zlib)` kann nur rohes DEFLATE, der
/// gzip-Kopf davor und die Prüfsumme danach müssen weg.
enum Gzip {

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw invalid }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw invalid }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        // Dateiname und Kommentar, jeweils mit 0 abgeschlossen
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw invalid }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw invalid }
        // Die letzten 4 Byte sind die Länge modulo 2^32, Little Endian
        let size = bytes[(bytes.count - 4)...].reversed().reduce(0) { $0 << 8 | Int($1) }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        let result = try (deflate as NSData).decompressed(using: .zlib) as Data
        guard result.count % (1 << 32) == size else { throw invalid }
        return result
    }

    private static let invalid = BlechWikiError.malformedResponse("Stand der Fundstellen: kein gültiges gzip")
}
