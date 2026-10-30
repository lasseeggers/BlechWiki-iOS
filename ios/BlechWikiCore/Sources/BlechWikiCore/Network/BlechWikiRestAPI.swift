import Foundation

/// JSON-REST-API, die die App BlechWikiDK nutzt (`teddymuetze.ddns.net`). Gleicher Datenbestand
/// wie der LiteraService. Liefert, was SOAP nicht kann: ein Änderungsprotokoll der Stammdaten.
///
/// Jede Methode ist genau ein HTTP-Request. Alle Fehler kommen als `BlechWikiError`.
public protocol BlechWikiRestAPI: Sendable {

    /// Höchster Änderungszähler in `table` oberhalb von `after`, `nil` wenn es seitdem keine
    /// Änderung gab. Das Protokoll enthält neue, geänderte und gelöschte Einträge.
    func getLatestChange(_ table: ChangeTable, after: Int) async throws -> Int?
}

/// Tabellen im Änderungsprotokoll. `rawValue` ist der Name in der API.
public enum ChangeTable: String, CaseIterable, Sendable {
    case titles = "Titel"
    case books = "Buch"
    case composers = "Komponist"
}

public final class JsonBlechWikiRestAPI: BlechWikiRestAPI {

    public static let defaultBaseURL = URL(string: "https://teddymuetze.ddns.net/RestBlechWiki/api/")!

    private let baseURL: URL
    private let userAgent: String
    private let transport: SoapBlechWikiAPI.Transport

    public init(
        baseURL: URL = JsonBlechWikiRestAPI.defaultBaseURL,
        userAgent: String = SoapBlechWikiAPI.defaultUserAgent,
        transport: @escaping SoapBlechWikiAPI.Transport = SoapBlechWikiAPI.urlSessionTransport()
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.transport = transport
    }

    public func getLatestChange(_ table: ChangeTable, after: Int) async throws -> Int? {
        // counter=0 liefert die ganze Tabelle statt des Protokolls
        precondition(after >= 1, "after muss mindestens 1 sein: \(after)")
        return try await get("Version", ("Tabelle", table.rawValue), ("counter", String(after))) { json in
            try Self.array(json, "Version").compactMap { Self.intOrNil(try Self.object($0, "Version")["changecounter"]) }.max()
        }
    }

    private func get<T>(_ path: String, _ params: (String, String)..., parse: (Any) throws -> T) async throws -> T {
        try await get(path, params, parse: parse)
    }

    private func get<T>(_ path: String, _ params: [(String, String)], parse: (Any) throws -> T) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch let error as BlechWikiError {
            throw error
        } catch {
            throw BlechWikiError.network(error.localizedDescription)
        }
        guard 200..<300 ~= status else { throw BlechWikiError.httpError(status) }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw BlechWikiError.malformedResponse("\(path): kein JSON")
        }
        return try parse(json)
    }

    private static func array(_ json: Any, _ path: String) throws -> [Any] {
        guard let array = json as? [Any] else { throw BlechWikiError.malformedResponse("\(path): kein Array") }
        return array
    }

    private static func object(_ json: Any, _ path: String) throws -> [String: Any] {
        guard let object = json as? [String: Any] else { throw BlechWikiError.malformedResponse("\(path): kein Objekt") }
        return object
    }

    /// Zahl oder Zahl als Text, wie `intOrNull` in kotlinx.serialization.
    private static func intOrNil(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return Int(exactly: number.doubleValue)
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }
}
