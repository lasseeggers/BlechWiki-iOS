import Foundation
import Testing
@testable import BlechWikiCore

/// Merkt sich Requests und liefert der Reihe nach feste Antworten.
final class FakeTransport: @unchecked Sendable {
    var requests: [URLRequest] = []
    var responses: [(Data, Int)]

    init(_ bodies: String..., status: Int = 200) {
        responses = bodies.map { (Data($0.utf8), status) }
    }

    var api: JsonBlechWikiAPI {
        JsonBlechWikiAPI(baseURL: URL(string: "https://example.org/RestBlechWiki/api/")!, transport: { request in
            self.requests.append(request)
            return self.responses.count > 1 ? self.responses.removeFirst() : self.responses[0]
        })
    }

    /// Pfad und Query eines Requests ohne Basis-URL, z. B. "Version?Tabelle=Buch&counter=0".
    func target(_ index: Int) -> String {
        guard let url = requests[index].url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let path = components.path.replacingOccurrences(of: "/RestBlechWiki/api/", with: "")
        return path + (components.query.map { "?" + $0 } ?? "")
    }
}

/// Antworten gekürzt aus echten Abrufen vom 30.10.2026, wie in der Android-App.
struct RestAPITests {

    @Test func titelAusDemProtokollMitLoeschungen() async throws {
        let fake = FakeTransport("""
            [{"titelohneKomma":"Alle Augen warten auf dich Herre","titel":"Alle Augen warten auf dich, Herre","ix":10374,"changecounter":68,"change":"new"},
             {"titelohneKomma":"Kanon","titel":"Kanon ","ix":8358,"changecounter":69,"change":"delete"}]
            """)

        let titles = try await fake.api.getTitles(after: 66)

        #expect(titles.maxCounter == 69)
        #expect(titles.rows == [
            TitleDto(ix: 10374, title: "Alle Augen warten auf dich, Herre", deleted: false, changeCounter: 68),
            TitleDto(ix: 8358, title: "Kanon", deleted: true, changeCounter: 69),
        ])
        #expect(fake.target(0) == "Version?Tabelle=Titel&counter=66")
        #expect(fake.requests[0].value(forHTTPHeaderField: "User-Agent") == JsonBlechWikiAPI.defaultUserAgent)
    }

    @Test func buecherMitCoverAusDemKurznamen() async throws {
        let fake = FakeTransport("""
            [{"buchId":"1","buchkurz":"101Bläserv","buch":"101 Bläservorspiele zum EG","untertitel":"","erscheinjahr":"1997",
              "herausgeber":"Evangelischen Posaunendienst","herausgvorname":"","verlag":"Buch & Musik ejw Stuttgtart","verlagsnummer":"",
              "zulieferung":"","relevanz":20,"vorhanden":"truetrue","changecounter":122,"change":"new"}]
            """)

        #expect(try await fake.api.getBooks(after: 0).rows == [
            BookDto(
                id: "1", title: "101 Bläservorspiele zum EG", subtitle: nil, year: 1997,
                editor: "Evangelischen Posaunendienst", editorFirstName: nil, publisher: "Buch & Musik ejw Stuttgtart",
                publisherNumber: nil, coverUrl: "https://teddymuetze.ddns.net/Bilder/BilderBuch/mini60/101Bläserv.jpg",
                deleted: false, changeCounter: 122
            ),
        ])
        #expect(fake.target(0) == "Version?Tabelle=Buch&counter=0")
    }

    @Test func komponistenMitLebensdatenUndSchreibvarianten() async throws {
        let fake = FakeTransport("""
            [{"id":"29","kurz":"Armsdorff A","komponist":"Armsdorff, Andreas (1670-1699)","friendlyKomponistName":"Armsdorff, Andreas","changecounter":78,"change":"new"},
             {"id":"29","kurz":"Armsdorff A","komponist":"Armsdorf, Andreas ( alias Armsdorff, Andreas 1670-1699)","friendlyKomponistName":"Armsdorf, Andreas","changecounter":78,"change":"new"},
             {"id":"2000","kurz":"Kreuter W","komponist":"Kreuter, Walter ( - )","friendlyKomponistName":"Kreuter, Walter","changecounter":78,"change":"update"}]
            """)

        #expect(try await fake.api.getComposers(after: 0).rows == [
            ComposerDto(id: "29", name: "Armsdorff, Andreas", born: "1670", died: "1699", isAlias: false, deleted: false, changeCounter: 78),
            ComposerDto(id: "29", name: "Armsdorf, Andreas", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 78),
            ComposerDto(id: "2000", name: "Kreuter, Walter", born: nil, died: nil, isAlias: false, deleted: false, changeCounter: 78),
        ])
    }

    @Test func lebensdatenInAllenSchreibweisenDerApi() {
        func dates(_ text: Substring) -> [String?] {
            let d = JsonBlechWikiAPI.lifeDates(text)
            return [d.born, d.died]
        }
        #expect(dates("1954- ") == ["1954", nil])
        #expect(dates("-1700") == [nil, "1700"])
        #expect(dates("um 1600-nach 1650") == ["um 1600", "nach 1650"])
        #expect(dates("16. Jh.-") == ["16. Jh.", nil])
        #expect(dates("") == [nil, nil])
    }

    @Test func egLiederEinEintragJeTeil() async throws {
        let fake = FakeTransport("""
            [{"nr":674,"nr2":1,"lied":"Der Friede des Herrn sei mit euch allen","anlass":"Liturgische Gesänge","ix":188,"ixUr":188,"egTeil":"N"}]
            """)

        #expect(try await fake.api.getEgSongs() == [
            EgSongDto(ix: 188, ixUr: 188, title: "Der Friede des Herrn sei mit euch allen", part: "N", number: 674, occasion: "Liturgische Gesänge"),
        ])
        #expect(fake.target(0) == "EG")
    }

    @Test func fundstellenUeberDieSchluesselDerStammdaten() async throws {
        let fake = FakeTransport("""
            [{"buch":"Bläsermusik 2025 - Württemberg","nr":"113","titel":"Lobe den Herren, den mächtigen König der Ehren","zus":"",
              "komponist":"Fünfgeld, Traugott","besetzung":"2+2","vorzeichen":"1b","titelZ":null,"buchId":"4035","quellekurz":"WBH2025"}]
            """)
        let api = fake.api
        let expected = [
            FundstelleDto(
                bookId: "4035", bookTitle: "Bläsermusik 2025 - Württemberg", number: "113",
                title: "Lobe den Herren, den mächtigen König der Ehren", addition: nil, composer: "Fünfgeld, Traugott",
                scoring: "2+2", keySignature: "1b", coverUrl: "https://teddymuetze.ddns.net/Bilder/BilderBuch/mini60/WBH2025.jpg"
            ),
        ]

        #expect(try await api.getFundstellenByTitle(10374) == expected)
        #expect(try await api.getFundstellenByEgSong(859) == expected)
        #expect(try await api.getFundstellenByBook("4035") == expected)
        #expect(try await api.getFundstellenByComposer("2000") == expected)
        #expect((0..<4).map(fake.target) == ["Titel/10374", "EG/859", "Buch/4035", "Komponist/2000"])
    }

    @Test func fehler() async throws {
        await #expect(throws: BlechWikiError.httpError(500)) {
            try await FakeTransport(#"{"Message":"Fehler"}"#, status: 500).api.getFundstellenByBook("999999")
        }
        await #expect(throws: BlechWikiError.malformedResponse("Version: kein Array")) {
            try await FakeTransport(#"{"Message":"Fehler"}"#).api.getTitles(after: 1)
        }
        let offline = JsonBlechWikiAPI(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: BlechWikiError.self) { try await offline.getEgSongs() }
    }

    /// Ein Eintrag ohne Pflichtfeld darf nicht den ganzen Abgleich aufhalten.
    @Test func zeileOhnePflichtfeldWirdUebersprungen() async throws {
        let fake = FakeTransport("""
            [{"buchId":"1","buchkurz":null,"buch":"Kaputt","changecounter":122,"change":"new"},
             {"buchId":"2","buchkurz":"Heft","buch":"Heft","changecounter":123,"change":"new"}]
            """)

        let books = try await fake.api.getBooks(after: 0)
        #expect(books.rows.map(\.id) == ["2"])
        #expect(books.maxCounter == 123)
    }

    /// Ein neues Buch ohne Kurznamen allein im Änderungsprotokoll: kein Fehler, sonst scheiterte
    /// jeder Abgleich bis zum nächsten Vollabgleich. Der Zähler zählt trotzdem.
    @Test func aenderungenNurMitUnlesbarerZeile() async throws {
        let fake = FakeTransport(#"[{"buchId":"3","buchkurz":null,"buch":"Neu","changecounter":124,"change":"new"}]"#)

        #expect(try await fake.api.getBooks(after: 123) == TableRows(rows: [], maxCounter: 124))
        // Ohne lesbaren Zähler bleibt es ein Formatfehler
        await #expect(throws: BlechWikiError.self) {
            try await FakeTransport(#"[{"buchId":"3","buch":"Neu"}]"#).api.getBooks(after: 123)
        }
    }

    /// Ist keine Zeile lesbar, hat sich das Format geändert. Dann lieber nichts übernehmen.
    @Test func ohneLesbareZeileIstDieAntwortFehlerhaft() async throws {
        await #expect(throws: BlechWikiError.malformedResponse("Version: Feld buchkurz fehlt")) {
            try await FakeTransport(#"[{"buchId":"1","buch":"Kaputt","changecounter":122}]"#).api.getBooks(after: 0)
        }
    }
}
