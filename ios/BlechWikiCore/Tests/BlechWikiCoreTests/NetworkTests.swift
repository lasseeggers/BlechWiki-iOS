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

    @Test func fundstellenAbDemZaehler() async throws {
        let fake = FakeTransport("""
            [{"Zähler":65670,"Quelle_kurz":"LBegleitheftKiTa 19","Seite_Nr":74,"Titel":"Lobe den Herren, den mächtigen König der Ehren",
              "Titel2":"Intonation","Vorzeich":"1b","EGIx":859,"Besetzung":"2+2","Kompo_kurz":"Koch J H E","Kompo_kurz2":""},
             {"Zähler":65669,"Quelle_kurz":"LBegleitheftKiTa 19","Seite_Nr":73,"Titel":"Ich sing dir mein Lied","Titel2":" ",
              "Vorzeich":"4b","EGIx":0,"Besetzung":"","Kompo_kurz":"Fünfgeld T","Kompo_kurz2":"Gunsenheim G"}]
            """, "[]")

        #expect(try await fake.api.getPieces(after: 65666) == [
            PieceDto(counter: 65670, bookShortName: "LBegleitheftKiTa 19", number: "74", title: "Lobe den Herren, den mächtigen König der Ehren",
                     addition: "Intonation", keySignature: "1b", egIx: 859, scoring: "2+2", composerShortName: "Koch J H E", composerShortName2: nil),
            PieceDto(counter: 65669, bookShortName: "LBegleitheftKiTa 19", number: "73", title: "Ich sing dir mein Lied",
                     addition: nil, keySignature: "4b", egIx: nil, scoring: nil, composerShortName: "Fünfgeld T", composerShortName2: "Gunsenheim G"),
        ])
        #expect(fake.target(0) == "Titel?titelzaehler=65666")
        #expect(fake.requests[0].value(forHTTPHeaderField: "User-Agent") == JsonBlechWikiAPI.defaultUserAgent)
        // Ohne neue Bücher kommt eine leere Liste, kein Fehler
        #expect(try await fake.api.getPieces(after: 65738) == [])
    }

    @Test func mitgelieferterStandHatDasselbeFormat() throws {
        let json = #"[{"Zähler":1,"Quelle_kurz":"101Bläserv","Seite_Nr":2,"Titel":"Macht hoch die Tür","Titel2":"","Vorzeich":"3b","EGIx":881,"Besetzung":"2+2","Kompo_kurz":"Bredenbach I","Kompo_kurz2":""}]"#
        #expect(try JsonBlechWikiAPI.parsePieces(Data(json.utf8)) == [
            PieceDto(counter: 1, bookShortName: "101Bläserv", number: "2", title: "Macht hoch die Tür", addition: nil, keySignature: "3b",
                     egIx: 881, scoring: "2+2", composerShortName: "Bredenbach I", composerShortName2: nil),
        ])
        #expect(throws: BlechWikiError.self) { try JsonBlechWikiAPI.parsePieces(Data(#"{"Message":"Fehler"}"#.utf8)) }
    }

    /// Wie `scripts/fundstellen-stand.sh` die Datei schreibt: Python-gzip mit Dateinamen im Kopf.
    @Test func gzipMitDateinamenImKopf() throws {
        let gzip = Data(base64Encoded: "H4sICAAAAAAC/2Z1bmRzdGVsbGVuLmpzb24Ai65Wijq8JCMntUjJylBHKbA0NScnNT67tKhKyUrJIzWtRKk2FgCjjDoSJAAAAA==")!
        #expect(String(decoding: try Gzip.decompress(gzip), as: UTF8.self) == #"[{"Zähler":1,"Quelle_kurz":"Heft"}]"#)
        #expect(throws: BlechWikiError.self) { try Gzip.decompress(Data("kein gzip, aber lang genug".utf8)) }
    }

    @Test func buecherMitCoverAusDemKurznamen() async throws {
        let fake = FakeTransport("""
            [{"buchId":"1","buchkurz":"101Bläserv","buch":"101 Bläservorspiele zum EG","untertitel":"","erscheinjahr":"1997",
              "herausgeber":"Evangelischen Posaunendienst","herausgvorname":"","verlag":"Buch & Musik ejw Stuttgtart","verlagsnummer":"",
              "zulieferung":"","relevanz":20,"vorhanden":"truetrue","changecounter":122,"change":"new"}]
            """)

        #expect(try await fake.api.getBooks(after: 0).rows == [
            BookDto(
                id: "1", shortName: "101Bläserv", title: "101 Bläservorspiele zum EG", subtitle: nil, year: 1997,
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
            ComposerDto(id: "29", shortName: "Armsdorff A", name: "Armsdorff, Andreas", born: "1670", died: "1699", isAlias: false, deleted: false, changeCounter: 78),
            ComposerDto(id: "29", shortName: "Armsdorff A", name: "Armsdorf, Andreas", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 78),
            ComposerDto(id: "2000", shortName: "Kreuter W", name: "Kreuter, Walter", born: nil, died: nil, isAlias: false, deleted: false, changeCounter: 78),
        ])
    }

    @Test func komponistenImFormatAb05112026AuchNebenDenAltenFeldern() async throws {
        let fake = FakeTransport("""
            [{"kurz":"Haan J","Komponist":"De Haan, Jacob","Geboren":"1959","Gestorben":"","FriendlyKomponistName":"De Haan, Jacob","aliasvon":"","AutoNr":1339,"change":"new","changecounter":78},
             {"kurz":"Haan J","Komponist":"Jabovsky, Tony","Geboren":"1959","Gestorben":"","FriendlyKomponistName":"Jabovsky, Tony","aliasvon":"De Haan, Jacob","AutoNr":1339,"change":"new","changecounter":78},
             {"kurz":"Kreuter W","Komponist":"Kreuter, Walter","Geboren":" ","Gestorben":" ","FriendlyKomponistName":"Kreuter, Walter","aliasvon":"","AutoNr":2000,"change":"update","changecounter":79,
              "id":"2000","komponist":"Kreuter, Walter ( - )","friendlyKomponistName":"Kreuter, Walter"}]
            """)

        #expect(try await fake.api.getComposers(after: 0).rows == [
            ComposerDto(id: "1339", shortName: "Haan J", name: "De Haan, Jacob", born: "1959", died: nil, isAlias: false, deleted: false, changeCounter: 78),
            ComposerDto(id: "1339", shortName: "Haan J", name: "Jabovsky, Tony", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 78),
            ComposerDto(id: "2000", shortName: "Kreuter W", name: "Kreuter, Walter", born: nil, died: nil, isAlias: false, deleted: false, changeCounter: 79),
        ])
    }

    @Test func komponistenMitGeborenGestorbenUndAliasvonAuchKleinGeschriebenNebenId() async throws {
        let fake = FakeTransport("""
            [{"id":"37","kurz":"Bach J S","komponist":"Bach, Johann Sebastian","geboren":"1685","gestorben":"1750","friendlyKomponistName":"Bach, Johann Sebastian","aliasvon":"","changecounter":78,"change":"new"},
             {"id":"1079","kurz":"Victoria T L d","komponist":"Victoria Abulensis, Thomas Ludovicus a","geboren":"1548","gestorben":"1611","friendlyKomponistName":"Victoria Abulensis, Thomas Ludovicus a","aliasvon":"Victoria, Tomás Luis de","changecounter":78,"change":"new"},
             {"id":"1861","kurz":"Fjarill","komponist":"Fjarill (schwedische Folk-Pop-Band)","geboren":"2004","gestorben":" ","friendlyKomponistName":"Fjarill (schwedische Folk-Pop-Band)","aliasvon":"","changecounter":78,"change":"new"}]
            """)

        #expect(try await fake.api.getComposers(after: 0).rows == [
            ComposerDto(id: "37", shortName: "Bach J S", name: "Bach, Johann Sebastian", born: "1685", died: "1750", isAlias: false, deleted: false, changeCounter: 78),
            ComposerDto(id: "1079", shortName: "Victoria T L d", name: "Victoria Abulensis, Thomas Ludovicus a", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 78),
            ComposerDto(id: "1861", shortName: "Fjarill", name: "Fjarill (schwedische Folk-Pop-Band)", born: "2004", died: nil, isAlias: false, deleted: false, changeCounter: 78),
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

    @Test func zaehlerDerFundstellenEinesBuchs() async throws {
        let row = #"{"buch":"Bläsermusik 2025 - Württemberg","nr":"4","titel":"Minuet","zus":"","komponist":"","besetzung":"","vorzeichen":"","titelZ":%@,"buchId":"4035","quellekurz":"WBH2025"}"#
        let fake = FakeTransport(
            "[\(row.replacingOccurrences(of: "%@", with: #""63740""#)),\(row.replacingOccurrences(of: "%@", with: #""63739""#))]",
            "[\(row.replacingOccurrences(of: "%@", with: "null"))]"
        )

        #expect(try await fake.api.getBookPieceCounters("4035") == [63740, 63739])
        #expect(fake.target(0) == "Buch/4035")
        // Ohne titelZ ließe sich nicht sagen, was fehlt: lieber nichts abgleichen
        await #expect(throws: BlechWikiError.self) { try await fake.api.getBookPieceCounters("4035") }
    }

    @Test func egTeile() async throws {
        let fake = FakeTransport(#"[{"EGTeilkurz":"Add","EGTeil":"Ergänzungen"},{"EGTeilkurz":"NB","EGTeil":"Niedersachsen/Bremen"}]"#)
        #expect(try await fake.api.getEgAppendices() == [
            EgAppendixDto(code: "Add", name: "Ergänzungen"),
            EgAppendixDto(code: "NB", name: "Niedersachsen/Bremen"),
        ])
        #expect(fake.target(0) == "EG?anhaenge=true")
    }

    @Test func egTeileBeiFehlerAusDerEingebautenListe() async throws {
        for fake in [FakeTransport(#"{"Message":"Fehler"}"#, status: 500), FakeTransport("[]")] {
            let appendices = try await fake.api.getEgAppendices()
            #expect(appendices.count == 15)
            #expect(appendices.first { $0.code == "NB" }?.name == "Niedersachsen/Bremen")
        }
    }

    @Test func fehler() async throws {
        await #expect(throws: BlechWikiError.httpError(500)) {
            try await FakeTransport(#"{"Message":"Fehler"}"#, status: 500).api.getBookPieceCounters("999999")
        }
        await #expect(throws: BlechWikiError.malformedResponse("Titel: kein Array")) {
            try await FakeTransport(#"{"Message":"Fehler"}"#).api.getPieces(after: 1)
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

/// Der echte Stand aus `data/`, damit ein kaputtes Format schon beim Testen auffällt. Im
/// öffentlichen Repo fehlt `data/`, dort läuft der Test nicht.
private let snapshotDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../data").standardizedFileURL

@Suite(.enabled(if: FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent("fundstellen.json.gz").path)))
struct MitgelieferterStandTests {

    @Test func istLesbarUndVollstaendig() throws {
        let stand = try String(contentsOf: snapshotDirectory.appendingPathComponent("fundstellen.stand"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ISO8601DateFormatter().date(from: stand) != nil)

        let data = try Gzip.decompress(Data(contentsOf: snapshotDirectory.appendingPathComponent("fundstellen.json.gz")))
        let pieces = try JsonBlechWikiAPI.parsePieces(data)
        #expect(pieces.count > 30_000)
        #expect(pieces.contains { $0.egIx == 859 && $0.bookShortName == "WBH2025" })
    }
}
