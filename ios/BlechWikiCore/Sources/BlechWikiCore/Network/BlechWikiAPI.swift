import Foundation
import os

/// Zugriff auf die REST-API von blechwiki.de. Jede Methode ist genau ein HTTP-Request. Caching passiert eine Schicht höher. Alle Fehler kommen als `BlechWikiError`.
public protocol BlechWikiAPI: Sendable {

    /// Bücher und Komponisten sind Nachschlagetabellen mit Änderungszähler. `after` = 0 liefert
    /// die ganze Tabelle ohne gelöschte Einträge. Bei `after` > 0 kommen nur Einträge, deren
    /// letzte Änderung (auch Löschung) einen höheren Zähler hat. Einträge, die gemeinsam
    /// geändert wurden, haben denselben Zähler.
    func getBooks(after: Int) async throws -> TableRows<BookDto>

    /// Siehe `getBooks`. Schreibvarianten stehen als eigene Einträge in der Liste.
    func getComposers(after: Int) async throws -> TableRows<ComposerDto>

    /// Alle EG-Lieder, ein Eintrag je Lied und Teil. Statisch, ohne Änderungszähler.
    func getEgSongs() async throws -> [EgSongDto]

    /// Teile des EG: Stammteil, landeskirchliche Anhänge und "Add" (Lieder, die unter einem
    /// anderen, meist englischen Titel bekannt sind). Ist der Endpunkt nicht lesbar, kommt eine
    /// eingebaute Liste.
    func getEgAppendices() async throws -> [EgAppendixDto]

    /// Alle Fundstellen mit höherem Zähler als `after`, bei 0 alle (ca. 7,5 MB ohne gzip). Neue
    /// Bücher kommen so dazu. Korrekturen bekommen einen neuen Zähler, Löschungen meldet der
    /// Server nicht, siehe `getBookPieceCounters`.
    func getPieces(after: Int) async throws -> [PieceDto]

    /// Zähler (`PieceDto.counter`) aller Fundstellen, die der Server für das Buch `bookId`
    /// (`BookDto.id`) noch kennt. Fehlt einer Zeile der Zähler, gilt die Antwort als fehlerhaft,
    /// damit der Abgleich nichts löscht, was noch da ist.
    func getBookPieceCounters(_ bookId: String) async throws -> Set<Int>
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

    public func getBooks(after: Int = 0) async throws -> TableRows<BookDto> {
        try await getTable("Buch", after: after) { row in
            BookDto(
                id: try row.text("buchId"),
                shortName: try row.text("buchkurz").trimmingCharacters(in: .whitespaces),
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
        try await getTable("Komponist", after: after) { original in
            // Die Schreibweise der Feldnamen hat sich am 05.11.2026 zweimal geändert, z. B. Geboren und geboren
            let row = Row(path: original.path, values: Dictionary(
                original.values.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }
            ))
            // Seit 05.11.2026 mit geboren, gestorben und aliasvon, die Nummer zeitweise als AutoNr statt id
            if row.values["aliasvon"] != nil {
                let isAlias = row.textOrNil("aliasvon") != nil
                return ComposerDto(
                    id: try row.textOrNil("autonr") ?? row.text("id"),
                    shortName: row.textOrNil("kurz"),
                    name: try row.text("friendlykomponistname").trimmingCharacters(in: .whitespaces),
                    born: isAlias ? nil : row.textOrNil("geboren"),
                    died: isAlias ? nil : row.textOrNil("gestorben"),
                    isAlias: isAlias,
                    deleted: row.isDeleted,
                    changeCounter: try row.int("changecounter")
                )
            }
            // "Bach, Johann Sebastian (1685-1750)" oder "Armsdorf, Andreas ( alias Armsdorff, Andreas 1670-1699)"
            let details = Self.details(try row.text("komponist"))
            let isAlias = details.drop(while: { $0 == " " }).hasPrefix("alias ")
            let dates = isAlias ? (born: nil, died: nil) : Self.lifeDates(details)
            return ComposerDto(
                id: try row.text("id"),
                shortName: row.textOrNil("kurz"),
                name: try row.text("friendlykomponistname").trimmingCharacters(in: .whitespaces),
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

    public func getPieces(after: Int = 0) async throws -> [PieceDto] {
        precondition(after >= 0, "after darf nicht negativ sein: \(after)")
        // Ohne neue Bücher kommt [] zurück, das ist kein Formatfehler
        return try await get(["Titel"], [("titelzaehler", String(after))]) { json in
            try Self.rows(json, "Titel", allowNone: after > 0, Self.piece)
        }
    }

    public func getBookPieceCounters(_ bookId: String) async throws -> Set<Int> {
        try await get(["Buch", bookId]) { json in
            guard let array = json as? [Any] else { throw BlechWikiError.malformedResponse("Buch: kein Array") }
            // Zahl als Text, z. B. "63740". Ohne Zähler ließe sich nicht sagen, welche Zeile fehlt.
            return Set(try array.map { element in
                guard let object = element as? [String: Any] else { throw BlechWikiError.malformedResponse("Buch: kein Objekt") }
                let text = try Row(path: "Buch", values: object).text("titelZ").trimmingCharacters(in: .whitespaces)
                guard let counter = Int(text) else { throw BlechWikiError.malformedResponse("Buch: titelZ ist keine Zahl") }
                return counter
            })
        }
    }

    /// Liest den mitgelieferten Stand der Fundstellen (`data/fundstellen.json.gz` entpackt,
    /// dasselbe Format wie `getPieces`).
    /// - Throws: `BlechWikiError.malformedResponse`, wenn keine Zeile lesbar ist
    public static func parsePieces(_ data: Data) throws -> [PieceDto] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BlechWikiError.malformedResponse("Stand der Fundstellen: kein JSON")
        }
        return try rows(json, "Stand der Fundstellen", piece)
    }

    private static func piece(_ row: Row) throws -> PieceDto {
        PieceDto(
            counter: try row.int("Zähler"),
            bookShortName: try row.text("Quelle_kurz").trimmingCharacters(in: .whitespaces),
            number: try row.text("Seite_Nr").trimmingCharacters(in: .whitespaces),
            title: try row.text("Titel").trimmingCharacters(in: .whitespaces),
            addition: row.textOrNil("Titel2"),
            keySignature: row.textOrNil("Vorzeich"),
            // 0 bei Stücken, die kein EG-Lied sind
            egIx: (try? row.int("EGIx")).flatMap { $0 > 0 ? $0 : nil },
            scoring: row.textOrNil("Besetzung"),
            composerShortName: row.textOrNil("Kompo_kurz"),
            composerShortName2: row.textOrNil("Kompo_kurz2")
        )
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
