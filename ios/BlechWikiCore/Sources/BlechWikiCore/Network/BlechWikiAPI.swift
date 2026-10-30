import Foundation

/// Zugriff auf den LiteraService von blechwiki.de. Jede Methode ist genau ein HTTP-Request.
/// Caching passiert eine Schicht höher. Alle Fehler kommen als `BlechWikiError`.
public protocol BlechWikiAPI: Sendable {

    func getDataVersion() async throws -> DataVersionDto

    /// Eindeutige Titel, die `query` als Teilstring enthalten. Leerer `query` liefert alle (~10.000).
    func getTitles(_ query: String) async throws -> [String]

    func getTitleCount(_ query: String) async throws -> Int

    func getBooks() async throws -> [BookDto]

    func getComposers() async throws -> [ComposerDto]

    func getEgAppendices() async throws -> [EgAppendixDto]

    /// Alle EG-Lieder aus Stammteil und allen Anhängen.
    func getEgSongs() async throws -> [EgSongDto]

    /// Fundstellen zum exakten Titel (Groß-/Kleinschreibung egal).
    func getFundstellenByTitle(_ title: String) async throws -> [FundstelleDto]

    /// Fundstellen zu einem EG-Lied, inklusive Titelvarianten.
    func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto]

    func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto]

    /// `shortName` ist `ComposerDto.shortName`, nicht der volle Name.
    func getFundstellenByComposer(_ shortName: String) async throws -> [FundstelleDto]
}

public final class SoapBlechWikiAPI: BlechWikiAPI {

    /// Schickt einen Request und liefert Body und Statuscode. Austauschbar für Tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let defaultEndpoint = URL(string: "https://pcportal.ddns.net/LiteraService/service1.asmx")!
    public static let defaultUserAgent = "BetterBlechWiki-iOS/0.1"

    private let endpoint: URL
    private let userAgent: String
    private let transport: Transport

    public init(
        endpoint: URL = SoapBlechWikiAPI.defaultEndpoint,
        userAgent: String = SoapBlechWikiAPI.defaultUserAgent,
        transport: @escaping Transport = SoapBlechWikiAPI.urlSessionTransport()
    ) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.transport = transport
    }

    public static func urlSessionTransport() -> Transport {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        // GetTitel("") liefert ~1 MB ohne Kompression
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        return { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func getDataVersion() async throws -> DataVersionDto {
        let pairs = try await callRows("GetlastAutonummer") { ($0.text("tbl"), try $0.int("lastNr")) }
        let numbers = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        func number(_ table: String) throws -> Int {
            guard let value = numbers[table] else {
                throw BlechWikiError.malformedResponse("AutoNr für Tabelle \(table) fehlt")
            }
            return value
        }
        return DataVersionDto(
            lastBookNumber: try number("Buch"),
            // Schreibweise so in der API
            lastComposerNumber: try number("Kommponist"),
            lastTitleNumber: try number("Titel")
        )
    }

    public func getTitles(_ query: String = "") async throws -> [String] {
        try await callRows("GetTitel", ("Suchstring", query.likeEscaped.sqlQuoted)) { $0.text("TITEL") }
    }

    public func getTitleCount(_ query: String = "") async throws -> Int {
        let text = try await callScalar("GetTitelAnzahl", ("Suchstring", query.likeEscaped.sqlQuoted))
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BlechWikiError.malformedResponse("Keine Zahl: '\(text)'")
        }
        return value
    }

    public func getBooks() async throws -> [BookDto] {
        try await callRows("GetBücher") { row in
            BookDto(
                id: row.text("BuchId"),
                title: row.text("Buch"),
                subtitle: row.textOrNil("Untertitel"),
                year: row.intOrNil("Erscheinjahr").flatMap { $0 > 0 ? $0 : nil },
                editor: row.textOrNil("Herausgeber"),
                editorFirstName: row.textOrNil("Herausg_vorname"),
                publisher: row.textOrNil("VERLAG"),
                publisherNumber: row.textOrNil("Verlagsnummer"),
                coverUrl: row.textOrNil("ImgUrl")
            )
        }
    }

    public func getComposers() async throws -> [ComposerDto] {
        try await callRows("GetKomponisten") { row in
            ComposerDto(
                name: row.text("Komponist"),
                shortName: row.text("kurz"),
                born: row.textOrNil("Geboren"),
                died: row.textOrNil("Gestorben")
            )
        }
    }

    public func getEgAppendices() async throws -> [EgAppendixDto] {
        try await callRows("GetEGLkAnhänge") { EgAppendixDto(code: $0.text("EGTeilkurz"), name: $0.text("EGTeil")) }
    }

    public func getEgSongs() async throws -> [EgSongDto] {
        try await callRows("GetEGLieder2", mapRow: Self.toEgSong)
    }

    public func getFundstellenByTitle(_ title: String) async throws -> [FundstelleDto] {
        try await callRows("GetTitelFundstellen", ("vTitel", title.sqlQuoted), mapRow: Self.toFundstelle)
    }

    public func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto] {
        // Parameter ist im WSDL ein short
        guard Int(Int16.min)...Int(Int16.max) ~= ixUr else {
            throw BlechWikiError.malformedResponse("ixUr außerhalb des short-Bereichs: \(ixUr)")
        }
        return try await callRows("GetEGLiederFundstellen", ("EGIxUr", String(ixUr)), mapRow: Self.toFundstelle)
    }

    public func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto] {
        try await callRows("GetBuchFundstellen", ("vQuellekurz", bookId.sqlQuoted), mapRow: Self.toFundstelle)
    }

    public func getFundstellenByComposer(_ shortName: String) async throws -> [FundstelleDto] {
        try await callRows("GetKomponistFundstellen", ("vKomponist", shortName.sqlQuoted), mapRow: Self.toFundstelle)
    }

    private static func toEgSong(_ row: DataSetParser.Row) throws -> EgSongDto {
        EgSongDto(
            ix: try row.int("Ix"),
            ixUr: try row.int("IxUr"),
            title: row.text("Lied"),
            part: row.text("Teil"),
            number: try row.int("Nr"),
            occasion: row.textOrNil("Anlass")
        )
    }

    private static func toFundstelle(_ row: DataSetParser.Row) -> FundstelleDto {
        FundstelleDto(
            bookId: row.text("BuchId"),
            bookTitle: row.text("Buch"),
            bookSubtitle: row.textOrNil("UNTERTITEL"),
            number: row.text("Nr"),
            title: row.text("TITEL"),
            addition: row.textOrNil("Zus"),
            composer: row.textOrNil("Komponist"),
            scoring: row.textOrNil("Besetzung"),
            keySignature: row.textOrNil("Vorzeich"),
            coverUrl: row.textOrNil("ImgURL")
        )
    }

    private func callRows<T>(
        _ method: String,
        _ params: (String, String)...,
        mapRow: (DataSetParser.Row) throws -> T
    ) async throws -> [T] {
        let data = try await call(method, params)
        return try DataSetParser.parseRows(data, mapRow)
    }

    private func callScalar(_ method: String, _ params: (String, String)...) async throws -> String {
        let data = try await call(method, params)
        return try DataSetParser.parseScalar(data, resultElement: "\(method)Result")
    }

    private func call(_ method: String, _ params: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Methodennamen wie "GetBücher" enthalten Umlaute, der Server erwartet sie als UTF-8
        request.setValue(SoapEnvelope.soapAction(method), forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(SoapEnvelope.build(method, params).utf8)

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch let error as BlechWikiError {
            throw error
        } catch {
            throw BlechWikiError.network(error.localizedDescription)
        }
        switch status {
        case 200..<300: return data
        case 500: throw BlechWikiError.soapFault(DataSetParser.parseFaultString(data) ?? "HTTP 500 ohne Fault")
        default: throw BlechWikiError.httpError(status)
        }
    }
}
