import Foundation
import Testing
@testable import BlechWikiCore

enum Fixtures {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

/// Merkt sich Requests und liefert feste Antworten.
final class FakeTransport: @unchecked Sendable {
    var requests: [URLRequest] = []
    var response: (Data, Int)

    init(_ fixture: String, status: Int = 200) {
        response = (Fixtures.data(fixture), status)
    }

    init(data: Data, status: Int) {
        response = (data, status)
    }

    var api: SoapBlechWikiAPI {
        SoapBlechWikiAPI(transport: { request in
            self.requests.append(request)
            return self.response
        })
    }

    var restAPI: JsonBlechWikiRestAPI {
        JsonBlechWikiRestAPI(transport: { request in
            self.requests.append(request)
            return self.response
        })
    }

    var lastBody: String { String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self) }

    /// Pfad und Query des letzten Requests, z. B. "/RestBlechWiki/api/Version?Tabelle=Buch&counter=1".
    var lastTarget: String {
        guard let url = requests.last?.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}

struct SoapEnvelopeTests {

    @Test func buildSetztMethodeImNamespace() {
        let xml = SoapEnvelope.build("GetTitel", [("Suchstring", "Lobe den")])
        #expect(xml.contains(#"<GetTitel xmlns="http://pcportal.ddns.net/"><Suchstring>Lobe den</Suchstring></GetTitel>"#))
    }

    @Test func buildOhneParameter() {
        #expect(SoapEnvelope.build("GetBücher", []).contains(#"<GetBücher xmlns="http://pcportal.ddns.net/"></GetBücher>"#))
    }

    @Test func escaping() {
        #expect("Tom & Jerry <3 \"x>".xmlEscaped == "Tom &amp; Jerry &lt;3 &quot;x&gt;")
        #expect("Ach Gott, dir muss ich's".sqlQuoted == "Ach Gott, dir muss ich''s")
        #expect("Lobe_den 100% [x]".likeEscaped == "Lobe[_]den 100[%] [[]x]")
        #expect(SoapEnvelope.soapAction("GetTitel") == "\"http://pcportal.ddns.net/GetTitel\"")
    }
}

struct DataSetParserTests {

    @Test func liestZeilenUndUeberspringtSchema() throws {
        let titles = try DataSetParser.parseRows(Fixtures.data("get_titles.xml")) { $0.text("TITEL") }
        #expect(titles.count == 14)
        #expect(titles.first == "Alles, was Odem hat, lobe den Herrn")
        #expect(titles.last == "Lobe den Herrn, o Seele mein")
        // Im Original "Lobe den Herren " mit Leerzeichen
        #expect(titles.contains("Lobe den Herren"))
    }

    @Test func leeresDiffgram() throws {
        #expect(try DataSetParser.parseRows(Fixtures.data("empty_dataset.xml")) { $0 }.isEmpty)
    }

    @Test func fehlendeSpalte() throws {
        let row = try DataSetParser.parseRows(Fixtures.data("get_titles.xml")) { $0 }.first!
        #expect(row.text("GibtEsNicht") == "")
        #expect(row.textOrNil("GibtEsNicht") == nil)
        #expect(row.intOrNil("GibtEsNicht") == nil)
    }

    @Test func ohneDiffgramIstMalformed() {
        #expect(throws: BlechWikiError.self) {
            try DataSetParser.parseRows(Fixtures.data("get_title_count.xml")) { $0 }
        }
    }

    @Test func skalarUndFault() throws {
        #expect(try DataSetParser.parseScalar(Fixtures.data("get_title_count.xml"), resultElement: "GetTitelAnzahlResult") == "14")
        #expect(DataSetParser.parseFaultString(Fixtures.data("soap_fault.xml"))?.contains("Kein schließendes Anführungszeichen") == true)
        #expect(DataSetParser.parseFaultString(Data("<html>Bad Gateway".utf8)) == nil)
    }
}

struct SoapAPITests {

    @Test func requestIstSoap11MitUmlautImHeader() async throws {
        let fake = FakeTransport("get_books.xml")
        _ = try await fake.api.getBooks()
        let request = try #require(fake.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "SOAPAction") == "\"http://pcportal.ddns.net/GetBücher\"")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/xml") == true)
    }

    @Test func maskiertApostrophUndXml() async throws {
        let fake = FakeTransport("get_fundstellen.xml")
        _ = try await fake.api.getFundstellenByTitle("Ich's & du")
        #expect(fake.lastBody.contains("<vTitel>Ich''s &amp; du</vTitel>"))
    }

    @Test func maskiertLikePlatzhalter() async throws {
        let fake = FakeTransport("get_titles.xml")
        let titles = try await fake.api.getTitles("100% Lob_")
        #expect(fake.lastBody.contains("<Suchstring>100[%] Lob[_]</Suchstring>"))
        #expect(titles.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespaces) })
    }

    @Test func zaehlerUndDatenversion() async throws {
        #expect(try await FakeTransport("get_title_count.xml").api.getTitleCount("Lobe den") == 14)
        let version = try await FakeTransport("get_data_version.xml").api.getDataVersion()
        #expect(version == DataVersionDto(lastBookNumber: 5088, lastComposerNumber: 5451, lastTitleNumber: 65738))
    }

    @Test func buecherKomponistenLieder() async throws {
        let books = try await FakeTransport("get_books.xml").api.getBooks()
        #expect(books[1].id == "30klChorRe")
        #expect(books[1].year == nil)

        let composers = try await FakeTransport("get_composers.xml").api.getComposers()
        #expect(composers.map(\.shortName) == ["Aas T W", "Abel J"])
        #expect(composers[0].died == nil)
        #expect(composers[1].died == "1928")

        let songs = try await FakeTransport("get_eg_songs.xml").api.getEgSongs()
        #expect(songs[0] == EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "alleAnhänge", number: 9999, occasion: "Abend"))
        #expect(songs.map(\.part) == ["alleAnhänge", "BEL", "Stamm"])

        let appendices = try await FakeTransport("get_eg_appendices.xml").api.getEgAppendices()
        #expect(appendices.count == 14)
        #expect(appendices.contains { $0.code == "NB" && $0.name == "Niedersachsen/Bremen" })

        #expect(try await FakeTransport("get_fundstellen.xml").api.getFundstellenByTitle("x").count == 5)
    }

    @Test func egIxUrAlsZahl() async throws {
        let fake = FakeTransport("get_fundstellen.xml")
        _ = try await fake.api.getFundstellenByEgSong(859)
        #expect(fake.lastBody.contains("<EGIxUr>859</EGIxUr>"))
        await #expect(throws: BlechWikiError.self) { try await fake.api.getFundstellenByEgSong(40_000) }
    }

    @Test func fehler() async throws {
        await #expect {
            try await FakeTransport("soap_fault.xml", status: 500).api.getFundstellenByTitle("x")
        } throws: { error in
            if case .soapFault(let text) = error as? BlechWikiError { return text.contains("Anführungszeichen") }
            return false
        }
        await #expect(throws: BlechWikiError.httpError(503)) {
            try await FakeTransport(data: Data(), status: 503).api.getBooks()
        }
        await #expect(throws: BlechWikiError.self) {
            try await FakeTransport(data: Data("<kaputt".utf8), status: 200).api.getBooks()
        }
    }
}

struct RestAPITests {

    private func fake(_ json: String, status: Int = 200) -> FakeTransport {
        FakeTransport(data: Data(json.utf8), status: status)
    }

    @Test func getLatestChangeLiefertDenHoechstenZaehler() async throws {
        let fake = fake(
            #"[{"buchId":"1891","buchkurz":"X","change":"update","changecounter":13},"# +
                #"{"buchId":"4041","buchkurz":"Y","change":"new","changecounter":107}]"#
        )

        #expect(try await fake.restAPI.getLatestChange(.books, after: 1) == 107)
        #expect(fake.lastTarget == "/RestBlechWiki/api/Version?Tabelle=Buch&counter=1")
    }

    @Test func getLatestChangeOhneAenderungenIstNil() async throws {
        #expect(try await fake("[]").restAPI.getLatestChange(.titles, after: 69) == nil)
    }

    @Test func unerwartetesJsonIstMalformedResponse() async throws {
        await #expect {
            try await fake(#"{"Message":"Fehler"}"#).restAPI.getLatestChange(.composers, after: 1)
        } throws: { error in
            if case .malformedResponse = error as? BlechWikiError { return true }
            return false
        }
        await #expect {
            try await fake("<html>Bad Gateway").restAPI.getLatestChange(.books, after: 1)
        } throws: { error in
            if case .malformedResponse = error as? BlechWikiError { return true }
            return false
        }
    }

    @Test func netzfehlerWirdZuNetwork() async throws {
        let api = JsonBlechWikiRestAPI(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect {
            try await api.getLatestChange(.books, after: 1)
        } throws: { error in
            if case .network = error as? BlechWikiError { return true }
            return false
        }
    }
}
