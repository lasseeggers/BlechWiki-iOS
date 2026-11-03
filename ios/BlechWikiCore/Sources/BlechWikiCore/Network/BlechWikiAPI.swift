import Foundation
import os

/// Zugriff auf die REST-API von blechwiki.de. Jede Methode ist genau ein HTTP-Request. Caching passiert eine Schicht höher. Alle Fehler kommen als `BlechWikiError`.
public protocol BlechWikiAPI: Sendable {

    /// Titel, Bücher und Komponisten sind Nachschlagetabellen mit Änderungszähler. `after` = 0
    /// liefert die ganze Tabelle ohne gelöschte Einträge. Bei `after` > 0 kommen nur Einträge,
    /// deren letzte Änderung (auch Löschung) einen höheren Zähler hat. Einträge, die gemeinsam
    /// geändert wurden, haben denselben Zähler.
    func getTitles(after: Int) async throws -> TableRows<TitleDto>

    /// Siehe `getTitles`.
    func getBooks(after: Int) async throws -> TableRows<BookDto>

    /// Siehe `getTitles`. Schreibvarianten stehen als eigene Einträge in der Liste.
    func getComposers(after: Int) async throws -> TableRows<ComposerDto>

    /// Alle EG-Lieder, ein Eintrag je Lied und Teil. Statisch, ohne Änderungszähler.
    func getEgSongs() async throws -> [EgSongDto]

    /// Teile des EG: Stammteil, landeskirchliche Anhänge und "Add" (Lieder, die unter einem
    /// anderen, meist englischen Titel bekannt sind). Ist der Endpunkt nicht lesbar, kommt eine
    /// eingebaute Liste.
    func getEgAppendices() async throws -> [EgAppendixDto]

    /// `ix` ist `TitleDto.ix`.
    func getFundstellenByTitle(_ ix: Int) async throws -> [FundstelleDto]

    /// Alle Sätze zur Melodie `ixUr`, auch unter anderem Liedtext.
    func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto]

    /// `bookId` ist `BookDto.id`.
    func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto]

    /// `composerId` ist `ComposerDto.id`.
    func getFundstellenByComposer(_ composerId: String) async throws -> [FundstelleDto]
}

/// REST-API von Dieter Kipp, Beschreibung in docs/ARCHITEKTUR.md.
public final class JsonBlechWikiAPI: BlechWikiAPI {

    /// Schickt einen Request und liefert Body und Statuscode. Austauschbar für Tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let defaultBaseURL = URL(string: "https://pcportal.ddns.net/RestBlechWiki1/api/")!
    /// "BlechWiki-iOS/1.0.0", Version aus dem Bundle von App bzw. Share Extension.
    public static let defaultUserAgent =
        "BlechWiki-iOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"

    private static let log = Logger(subsystem: "blechwiki.eggers.media", category: "API")

    /// Cover gibt es als `mini60/`, `mini120/`, `mini240/` und im Original, siehe `CoverUrls`.
    private static let coverBaseURL = "https://teddymuetze.ddns.net/Bilder/BilderBuch/mini60/"

    /// Rückfall für `getEgAppendices`, Stand `EG?anhaenge=true` vom 03.11.2026. Auch für die Auswahl
    /// der Landeskirche, solange das Verzeichnis noch nicht geladen ist.
    public static let egAppendices = [
        EgAppendixDto(code: "Add", name: "Ergänzungen"),
        EgAppendixDto(code: "BEL", name: "Baden/Elsaß/Lothringen"),
        EgAppendixDto(code: "BT", name: "Bayern/Thüringen"),
        EgAppendixDto(code: "HN", name: "Hessen-Nassau"),
        EgAppendixDto(code: "KW", name: "Kurhessen-Waldeck"),
        EgAppendixDto(code: "M", name: "Mecklenburg"),
        EgAppendixDto(code: "NB", name: "Niedersachsen/Bremen"),
        EgAppendixDto(code: "N", name: "Nordelbien"),
        EgAppendixDto(code: "OL", name: "Oldenburg"),
        EgAppendixDto(code: "Ö", name: "Österreich"),
        EgAppendixDto(code: "P", name: "Pfalz"),
        EgAppendixDto(code: "R", name: "Reformierte"),
        EgAppendixDto(code: "RWL", name: "Rheinland/Westfalen/Lippe"),
        EgAppendixDto(code: "Stamm", name: "Stammteil"),
        EgAppendixDto(code: "W", name: "Württemberg"),
    ]

    private let baseURL: URL
    private let userAgent: String
    private let transport: Transport

    public init(
        baseURL: URL = JsonBlechWikiAPI.defaultBaseURL,
        userAgent: String = JsonBlechWikiAPI.defaultUserAgent,
        transport: @escaping Transport = JsonBlechWikiAPI.urlSessionTransport()
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.transport = transport
    }

    public static func urlSessionTransport() -> Transport {
        let config = URLSessionConfiguration.default
        // Höchstens so lange ohne neue Daten, wie bei OkHttp in der Android-App
        config.timeoutIntervalForRequest = 30
        // Die ganze Titeltabelle hat 1,2 MB ohne Kompression. Auch bei 5 KB/s soll sie ankommen.
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        return { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func getTitles(after: Int = 0) async throws -> TableRows<TitleDto> {
        try await getTable("Titel", after: after) { row in
            TitleDto(
                ix: try row.int("ix"),
                title: try row.text("titel").trimmingCharacters(in: .whitespaces),
                deleted: row.isDeleted,
                changeCounter: try row.int("changecounter")
            )
        }
    }

    public func getBooks(after: Int = 0) async throws -> TableRows<BookDto> {
        try await getTable("Buch", after: after) { row in
            BookDto(
                id: try row.text("buchId"),
                title: try row.text("buch").trimmingCharacters(in: .whitespaces),
                subtitle: row.textOrNil("untertitel"),
                year: row.textOrNil("erscheinjahr").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                editor: row.textOrNil("herausgeber"),
                editorFirstName: row.textOrNil("herausgvorname"),
                publisher: row.textOrNil("verlag"),
                publisherNumber: row.textOrNil("verlagsnummer"),
                coverUrl: Self.coverUrl(try row.text("buchkurz")),
                deleted: row.isDeleted,
                changeCounter: try row.int("changecounter")
            )
        }
    }

    public func getComposers(after: Int = 0) async throws -> TableRows<ComposerDto> {
        try await getTable("Komponist", after: after) { row in
            // "Bach, Johann Sebastian (1685-1750)" oder "Armsdorf, Andreas ( alias Armsdorff, Andreas 1670-1699)"
            let details = Self.details(try row.text("komponist"))
            let isAlias = details.drop(while: { $0 == " " }).hasPrefix("alias ")
            let dates = isAlias ? (born: nil, died: nil) : Self.lifeDates(details)
            return ComposerDto(
                id: try row.text("id"),
                name: try row.text("friendlyKomponistName").trimmingCharacters(in: .whitespaces),
                born: dates.born,
                died: dates.died,
                isAlias: isAlias,
                deleted: row.isDeleted,
                changeCounter: try row.int("changecounter")
            )
        }
    }

    public func getEgSongs() async throws -> [EgSongDto] {
        try await get(["EG"]) { json in
            try Self.rows(json, "EG") { row in
                EgSongDto(
                    ix: try row.int("ix"),
                    ixUr: try row.int("ixUr"),
                    title: try row.text("lied").trimmingCharacters(in: .whitespaces),
                    part: try row.text("egTeil"),
                    number: try row.int("nr"),
                    occasion: row.textOrNil("anlass")
                )
            }
        }
    }

    public func getEgAppendices() async throws -> [EgAppendixDto] {
        do {
            let appendices = try await get(["EG"], [("anhaenge", "true")]) { json in
                try Self.rows(json, "EG") { row in
                    EgAppendixDto(
                        code: try row.text("EGTeilkurz").trimmingCharacters(in: .whitespaces),
                        name: try row.text("EGTeil").trimmingCharacters(in: .whitespaces)
                    )
                }
            }
            return appendices.isEmpty ? Self.egAppendices : appendices
        } catch let error as BlechWikiError {
            // Ohne Liste der Landeskirchen soll nicht der ganze Abgleich scheitern
            Self.log.warning("EG-Teile nicht geladen, nehme die eingebaute Liste: \(String(describing: error))")
            return Self.egAppendices
        }
    }

    public func getFundstellenByTitle(_ ix: Int) async throws -> [FundstelleDto] {
        try await getFundstellen("Titel", String(ix))
    }

    public func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto] {
        try await getFundstellen("EG", String(ixUr))
    }

    public func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto] {
        try await getFundstellen("Buch", bookId)
    }

    public func getFundstellenByComposer(_ composerId: String) async throws -> [FundstelleDto] {
        try await getFundstellen("Komponist", composerId)
    }

    private func getTable<T>(_ table: String, after: Int, mapRow: (Row) throws -> T) async throws -> TableRows<T> {
        precondition(after >= 0, "after darf nicht negativ sein: \(after)")
        return try await get(["Version"], [("Tabelle", table), ("counter", String(after))]) { json in
            // Zähler auch aus Zeilen, die sich nicht lesen lassen. Sonst fragte jeder weitere
            // Abgleich dieselben Änderungen wieder ab.
            let counters = (json as? [Any] ?? []).compactMap { element in
                (element as? [String: Any]).flatMap { try? Row(path: "Version", values: $0).int("changecounter") }
            }
            // Bei Änderungen kann auch nur ein einziger, unlesbarer Eintrag kommen. Das ist kein
            // Formatwechsel, solange sich wenigstens der Zähler lesen lässt.
            let rows = try Self.rows(json, "Version", allowNone: after > 0 && !counters.isEmpty, mapRow)
            return TableRows(rows: rows, maxCounter: counters.max() ?? 0)
        }
    }

    private func getFundstellen(_ resource: String, _ key: String) async throws -> [FundstelleDto] {
        try await get([resource, key]) { json in
            try Self.rows(json, resource) { row in
                FundstelleDto(
                    bookId: try row.text("buchId"),
                    bookTitle: try row.text("buch").trimmingCharacters(in: .whitespaces),
                    number: try row.text("nr").trimmingCharacters(in: .whitespaces),
                    title: try row.text("titel").trimmingCharacters(in: .whitespaces),
                    addition: row.textOrNil("zus"),
                    composer: row.textOrNil("komponist"),
                    scoring: row.textOrNil("besetzung"),
                    keySignature: row.textOrNil("vorzeichen"),
                    coverUrl: Self.coverUrl(try row.text("quellekurz"))
                )
            }
        }
    }

    /// `segments` werden an `baseURL` angehängt und wie `params` URL-kodiert.
    private func get<T>(_ segments: [String], _ params: [(String, String)] = [], parse: (Any) throws -> T) async throws -> T {
        let url = segments.reduce(baseURL) { $0.appendingPathComponent($1) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !params.isEmpty { components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
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
            throw BlechWikiError.malformedResponse("\(segments.joined(separator: "/")): kein JSON")
        }
        return try parse(json)
    }

    /// Zeilen, denen ein Pflichtfeld fehlt, werden übersprungen. Sonst hielte ein einziger
    /// fehlerhafter Eintrag auf dem Server jeden Abgleich auf. Ist keine Zeile lesbar, hat sich
    /// wohl das Format geändert, dann gilt die ganze Antwort als fehlerhaft, außer bei `allowNone`.
    private static func rows<T>(_ json: Any, _ path: String, allowNone: Bool = false, _ mapRow: (Row) throws -> T) throws -> [T] {
        guard let array = json as? [Any] else { throw BlechWikiError.malformedResponse("\(path): kein Array") }
        var result: [T] = []
        var firstError: Error?
        for element in array {
            do {
                guard let object = element as? [String: Any] else { throw BlechWikiError.malformedResponse("\(path): kein Objekt") }
                result.append(try mapRow(Row(path: path, values: object)))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            if result.isEmpty, !allowNone { throw firstError }
            log.warning("\(path): \(array.count - result.count) von \(array.count) Zeilen übersprungen, z. B. \(String(describing: firstError))")
        }
        return result
    }

    private static func coverUrl(_ bookShortName: String) -> String {
        coverBaseURL + bookShortName.trimmingCharacters(in: .whitespaces) + ".jpg"
    }

    /// Inhalt der letzten Klammer am Ende des Namens, sonst "".
    private static func details(_ name: String) -> Substring {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return "" }
        return trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
    }

    /// "1685-1750", "1954- ", "um 1600-nach 1650", "-1700" oder " - ".
    static func lifeDates(_ details: Substring) -> (born: String?, died: String?) {
        guard let split = details.firstIndex(of: "-") else { return (nil, nil) }
        func part(_ text: Substring) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (part(details[..<split]), part(details[details.index(after: split)...]))
    }

    /// Eine Zeile der Antwort. Fehlende Pflichtfelder werden zu `BlechWikiError.malformedResponse`.
    struct Row {
        let path: String
        let values: [String: Any]

        /// Text oder Zahl als Text. Die API liefert z. B. `nr` als "113".
        func text(_ key: String) throws -> String {
            switch values[key] {
            case let text as String: return text
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.stringValue
            default: throw BlechWikiError.malformedResponse("\(path): Feld \(key) fehlt")
            }
        }

        /// Leere Texte liefert die API als "" oder `null`.
        func textOrNil(_ key: String) -> String? {
            guard let text = try? text(key) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Zahl oder Zahl als Text.
        func int(_ key: String) throws -> Int {
            switch values[key] {
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                if let value = Int(exactly: number.doubleValue) { return value }
            case let text as String:
                if let value = Int(text) { return value }
            default: break
            }
            throw BlechWikiError.malformedResponse("\(path): Feld \(key) fehlt")
        }

        var isDeleted: Bool { textOrNil("change") == "delete" }
    }
}
