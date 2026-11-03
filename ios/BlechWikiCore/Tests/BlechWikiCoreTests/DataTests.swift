import Foundation
import Testing
@testable import BlechWikiCore

struct InventoryCodeTests {

    private let catalog = ["WBH2025", "BläshBay22", "101Bläserv", "30klChorRe", "ZGLE 84", "RomantischesSpielbuch"]

    private func roundTrip(_ ids: [String], sender: [String]? = nil, receiver: [String]? = nil) -> InventoryCode.Result {
        InventoryCode.decode(InventoryCode.encode(ids, catalog: sender ?? catalog), catalog: receiver ?? catalog)
    }

    /// Codes aus der Kotlin-Implementierung (InventoryCode.kt). Weicht einer ab, können
    /// Android und iOS keine Inventare mehr austauschen.
    @Test func gleicheCodesWieAndroid() {
        let catalog = self.catalog + ["Fünfgeld T", "Ach Gott, dir muss ich's"]
        #expect(InventoryCode.encode(["WBH2025"], catalog: catalog) == "BBW-0RJT-GA6Y")
        #expect(InventoryCode.encode(["WBH2025", "BläshBay22", "ZGLE 84"], catalog: catalog) == "BBW-02J3-086P-GA6Y-SXQM")
        #expect(InventoryCode.encode(["101Bläserv", "Fünfgeld T", "Ach Gott, dir muss ich's", "RomantischesSpielbuch"], catalog: catalog)
            == "BBW-01CY-5RTT-TQY1-WP83-YS8B")
        #expect(InventoryCode.decode("BBW-02J3-086P-GA6Y-SXQM", catalog: catalog)
            == .valid(bookIds: ["ZGLE 84", "BläshBay22", "WBH2025"].sorted { InventoryCode.hash(0, $0) < InventoryCode.hash(0, $1) }, unknownCount: 0))
    }

    @Test func eineGruppeJeBuch() {
        let code = InventoryCode.encode(["WBH2025", "BläshBay22"], catalog: catalog)
        #expect(code.range(of: #"^BBW(-[0-9A-HJKMNP-TV-Z]{4}){3}$"#, options: .regularExpression) != nil)
    }

    @Test func hinUndZurueck() {
        guard case let .valid(ids, unknown) = roundTrip(["WBH2025", "BläshBay22", "ZGLE 84"]) else { Issue.record(); return }
        #expect(Set(ids) == ["WBH2025", "BläshBay22", "ZGLE 84"])
        #expect(unknown == 0)
    }

    @Test func codeMittenInNachrichtUndKleingeschrieben() {
        let code = InventoryCode.encode(["WBH2025"], catalog: catalog)
        let message = "Hallo zusammen, hier unser Inventar:\n\(code.lowercased())\nViele Grüße"
        #expect(InventoryCode.decode(message, catalog: catalog) == .valid(bookIds: ["WBH2025"], unknownCount: 0))
    }

    @Test func zerlegteUmlauteGebenDenselbenCode() {
        let decomposed = "BläshBay22".decomposedStringWithCanonicalMapping
        #expect(InventoryCode.encode(["BläshBay22"], catalog: catalog) == InventoryCode.encode([decomposed], catalog: catalog))
    }

    @Test func ohneCode() {
        #expect(InventoryCode.decode("Lobe den Herren, BBW", catalog: catalog) == .notFound)
    }

    @Test func geaenderteGruppeNieFalschesBuch() {
        let code = InventoryCode.encode(["WBH2025", "BläshBay22"], catalog: catalog)
        let broken = String(code.dropLast()) + (code.last == "0" ? "1" : "0")
        switch InventoryCode.decode(broken, catalog: catalog) {
        case .valid(_, let unknown): #expect(unknown == 1)
        case let other: #expect(other == .invalid)
        }
    }

    @Test func fehlendesBuchBeimEmpfaenger() {
        let result = roundTrip(["WBH2025", "BläshBay22"], receiver: catalog.filter { $0 != "BläshBay22" })
        #expect(result == .valid(bookIds: ["WBH2025"], unknownCount: 1))
    }

    @Test func nurNeueBuecherSindUnbekannt() {
        #expect(roundTrip(["Neu2027"], sender: catalog + ["Neu2027"]) == .valid(bookIds: [], unknownCount: 1))
    }

    /// Gültig und vollständig aufgelöst: die Bücher, sonst `nil`.
    private func books(_ text: String, catalog: [String]) -> Set<String>? {
        guard case let .valid(ids, 0) = InventoryCode.decode(text, catalog: catalog) else { return nil }
        return Set(ids)
    }

    @Test func umgebrochenerCodeInZitierterMail() {
        let catalog = self.catalog + ["Fünfgeld T", "Ach Gott, dir muss ich's"]
        let mail = "> Hier unser Inventar:\n> BBW-02J3-086P-\n> GA6Y-SXQM\n> Viele Grüße"
        #expect(books(mail, catalog: catalog) == ["WBH2025", "BläshBay22", "ZGLE 84"])
        #expect(InventoryCode.find(mail) == "BBW-02J3-086P-GA6Y-SXQM")
    }

    @Test func leerraumUndAndereStricheStattBindestrich() {
        let catalog = self.catalog + ["Fünfgeld T", "Ach Gott, dir muss ich's"]
        for text in ["BBW 0RJT GA6Y", "BBW—0RJT—GA6Y", "BBW\u{2011}0RJT\u{2011}GA6Y", "BBW\u{2212}0RJT\u{2212}GA6Y",
                     "BBW – 0RJT – GA6Y", "bbw-0rjt -\n ga6y", "BBW\u{00A0}0RJT\u{00A0}GA6Y"] {
            #expect(books(text, catalog: catalog) == ["WBH2025"], "\(text)")
        }
        #expect(InventoryCode.find("BBW—0RJT—GA6Y") == "BBW-0RJT-GA6Y")
        #expect(InventoryCode.find("BBW 0RJT GA6Y") == "BBW 0RJT GA6Y")
    }

    /// Ein Wort aus vier Zeichen hinter dem Code ist keine weitere Gruppe.
    @Test func wortHinterDemCode() {
        let catalog = self.catalog + ["Fünfgeld T", "Ach Gott, dir muss ich's"]
        #expect(books("Hier: BBW-0RJT-GA6Y Euer Chor", catalog: catalog) == ["WBH2025"])
        #expect(books("BBW 0RJT GA6Y\nEuer Chor", catalog: catalog) == ["WBH2025"])
        #expect(books("BBW-0RJT-GA6Y Ufer", catalog: catalog) == ["WBH2025"])
    }

    @Test func fliesstextIstKeinCode() {
        #expect(InventoryCode.decode("Der BBW Chor probt", catalog: catalog) == .notFound)
        #expect(InventoryCode.find("Der BBW Chor probt") == nil)
        #expect(books("Im BBW Chor gibt es BBW-0RJT-GA6Y", catalog: catalog + ["Fünfgeld T", "Ach Gott, dir muss ich's"]) == ["WBH2025"])
        // Ohne Strich und ohne passende Bücher nicht von Text zu unterscheiden
        #expect(InventoryCode.decode("BBW will dich", catalog: catalog) == .invalid)
        #expect(InventoryCode.decode("BBW 0RJT GA6Y", catalog: ["ZGLE 84"]) == .invalid)
        #expect(InventoryCode.decode("BBW-0RJT-GA6Y", catalog: ["ZGLE 84"]) == .valid(bookIds: [], unknownCount: 1))
    }

    @Test func nurKopfgruppe() {
        #expect(InventoryCode.decode("BBW-0RJT", catalog: catalog) == .invalid)
    }

    @Test func leererKatalog() {
        let code = InventoryCode.encode(["WBH2025", "BläshBay22"], catalog: catalog)
        #expect(InventoryCode.decode(code, catalog: []) == .valid(bookIds: [], unknownCount: 2))
    }

    /// Kotlin vergleicht IDs Byte für Byte. Kanonisch gleiche IDs in NFC und NFD zählen dort doppelt,
    /// also auch hier, sonst bauten beide Apps verschiedene Codes. Gleicher Wert in InventoryCodeTest.kt.
    @Test func idsInNfcUndNfdZaehlenWieInKotlinDoppelt() {
        let nfc = "Bläser", nfd = "Bläser".decomposedStringWithCanonicalMapping
        #expect(InventoryCode.encode([nfc, nfd], catalog: [nfc, nfd]) == "BBW-0MFE-H6E3-H6E3")
    }

    @Test func kollisionen() {
        var seen: [Int: String] = [:]
        var pair: (String, String)?
        for i in 0..<100_000 {
            let id = "Buch\(i)"
            if let previous = seen.updateValue(id, forKey: InventoryCode.hash(0, id)) { pair = (previous, id); break }
        }
        let (a, b) = pair!
        #expect(roundTrip([a], sender: [a, b], receiver: [a, b]) == .valid(bookIds: [a], unknownCount: 0))
        #expect(roundTrip([a], sender: [a], receiver: [a, b]) == .valid(bookIds: [a], unknownCount: 0))
    }
}

struct SearchNormalizerTests {

    @Test func normalize() {
        #expect(SearchNormalizer.normalize("Abend ist es Herr; die Stunde") == "abend ist es herr die stunde")
        #expect(SearchNormalizer.normalize("Lobe den Herren, den mächtigen") == "lobe den herren den machtigen")
        #expect(SearchNormalizer.normalize("Großer Gott") == "grosser gott")
        #expect(SearchNormalizer.normalize("Ach Gott, dir muss ich's") == "ach gott dir muss ich s")
        #expect(SearchNormalizer.normalize("Noël nouvelet") == "noel nouvelet")
        #expect(SearchNormalizer.normalize("#Zuhause ") == "zuhause")
    }

    /// Buchstaben ohne Zerlegung in NFD bleiben ein Wort.
    @Test func normalizeErsetztLigaturenUndSonderbuchstaben() {
        #expect(SearchNormalizer.normalize("Søren Kierkegaard") == "soren kierkegaard")
        #expect(SearchNormalizer.normalize("ÆBLESKIVER Œuvre") == "aebleskiver oeuvre")
        #expect(SearchNormalizer.normalize("Łódź, Đorđe") == "lodz dorde")
        #expect(SearchNormalizer.normalize("Fazıl Say") == "fazil say")
        #expect(SearchNormalizer.normalize("ﬁnale ﬂöte") == "finale flote")
        #expect(SearchNormalizer.normalize("STRAẞE") == "strasse")
        #expect(SearchNormalizer.indexContent("Søren Ørsted, Flöte") == "soren orsted flote floete")
    }

    /// Zerlegte Umlaute (z. B. aus macOS-Dateinamen) wie fertige.
    @Test func zerlegteUmlaute() {
        let nfd = { (text: String) in text.decomposedStringWithCanonicalMapping }
        #expect(SearchNormalizer.normalize(nfd("Lobe den Herren, den mächtigen")) == "lobe den herren den machtigen")
        #expect(SearchNormalizer.indexContent(nfd("Fünfgeld, Traugott")) == "funfgeld traugott fuenfgeld")
        #expect(SearchNormalizer.transcribe(nfd("Händel")) == "haendel")
        #expect(TextFilter(nfd("Händel")).matches("Haendels Tochter"))
        #expect(TextFilter("haendel").matches(nfd("Händels Tochter")))
    }

    @Test func indexContent() {
        #expect(SearchNormalizer.indexContent("Fünfgeld, Traugott") == "funfgeld traugott fuenfgeld")
        #expect(SearchNormalizer.indexContent("Lobe den Herren") == "lobe den herren")
    }

    @Test func matchExpression() {
        #expect(SearchNormalizer.matchExpression("Lob Herr mächt") == "lob* herr* macht*")
        #expect(SearchNormalizer.matchExpression("ich's") == "ich* s*")
        #expect(SearchNormalizer.matchExpression("a OR b NEAR \"c\"*") == "a* or* b* near* c*")
        #expect(SearchNormalizer.matchExpression("  ,;- ") == nil)
    }

    /// Sehr lange Anfragen sprengten den FTS-Ausdrucksbaum.
    @Test func matchExpressionOhneDoppelteUndHoechstens16Woerter() {
        #expect(SearchNormalizer.matchExpression("lob Herr LOB herr lob") == "lob* herr*")
        let words = (0..<5000).map { "w\($0)" }
        #expect(SearchNormalizer.matchExpression(words.joined(separator: " ")) == words.prefix(16).map { "\($0)*" }.joined(separator: " "))
    }

    @Test func egNummer() {
        for query in ["316", "EG 316", "eg316", " 316 ", "EG-316", "„316“", "316.", "EG\u{00A0}316", "0316"] {
            #expect(SearchRepository.egNumber(query) == 316, "\(query)")
        }
        for query in ["12345", "EG 316 1", "３１６", "Lied 316", "e.g. 316", ""] {
            #expect(SearchRepository.egNumber(query) == nil, "\(query)")
        }
    }

    @Test func textFilter() {
        #expect(TextFilter("  ").isEmpty)
        #expect(TextFilter("").matches("irgendwas"))
        #expect(TextFilter("riegl vors").matches("Lobe den Herren", "Vorspiel", "Riegler, Thomas"))
        #expect(!TextFilter("riegl vors").matches("Lobe den Herren", nil, "Riegler, Thomas"))
        #expect(TextFilter("113").matches("113", "Lobe den Herren"))
        #expect(!TextFilter("13").matches("113", "Lobe den Herren"))
        #expect(TextFilter("Händel").matches("Haendels Tochter"))
        #expect(TextFilter("haendel").matches("Händels Tochter"))
        #expect(TextFilter("handel").matches("Händels Tochter"))
    }

    @Test func regionKeywords() {
        #expect(RegionKeywords.matches("blaserheft 2022 bayern", appendixCode: "BT"))
        #expect(RegionKeywords.matches("blasermusik 2025 wurttemberg", appendixCode: "W"))
        #expect(RegionKeywords.matches("landeskirche hannovers", appendixCode: "NB"))
        #expect(RegionKeywords.matches("bayerischer posaunenchorverband", appendixCode: "BT"))
        #expect(RegionKeywords.matches("eg anhang nb", appendixCode: "NB"))
        #expect(RegionKeywords.matches("ekg posaunenchoralbuch rwl", appendixCode: "RWL"))
        #expect(RegionKeywords.matches("oldenburger blaserheft", appendixCode: "ol"))
        #expect(!RegionKeywords.matches("kurhessisches jungblaserheft", appendixCode: "HN"))
        #expect(!RegionKeywords.matches("blaserheft 2022 bayern", appendixCode: "W"))
        #expect(!RegionKeywords.matches("blaserheft", appendixCode: "Stamm"))
    }
}

struct SearchIndexBuilderTests {

    private func song(_ part: String, _ number: Int, ix: Int = 1) -> EgSongEntity {
        EgSongEntity(ix: ix, ixUr: ix, title: "Lied", part: part, number: number, occasion: nil)
    }

    @Test func ergaenzungZeigtDasLiedImEG() {
        let add = EgSongEntity(ix: 1320, ixUr: 316, title: "It's me, oh Lord", part: "Add", number: 605, occasion: nil)
        let original = ["R", "RWL"].map {
            EgSongEntity(ix: 316, ixUr: 316, title: "Du, Herr, gabst uns dein festes Wort", part: $0, number: 570, occasion: nil)
        }
        let byIx = Dictionary(grouping: original + [add], by: \.ix)
        #expect(SearchIndexBuilder.egSongDetail([add], byIx: byIx)
            == "im EG als „Du, Herr, gabst uns dein festes Wort“, EG 570 (R, RWL)")
        #expect(SearchIndexBuilder.egSongDetail([add], byIx: byIx, appendix: "RWL")
            == "im EG als „Du, Herr, gabst uns dein festes Wort“, EG 570")
        #expect(SearchIndexBuilder.egNumberLabel([add]) == nil)
        #expect(SearchIndexBuilder.egSongDetail([add], byIx: [:]) == nil)
    }

    @Test func egNumberLabel() {
        #expect(SearchIndexBuilder.egNumberLabel([song("NB", 600), song("Stamm", 316)]) == "EG 316")
        #expect(SearchIndexBuilder.egNumberLabel([song("P", 673), song("BEL", 673), song("W", 612)])
            == "EG 612 (W) · 673 (BEL, P)")
        let variants = [song("Ol", 600), song("W", 612)]
        #expect(SearchIndexBuilder.egNumberLabel(variants, appendix: "OL") == "EG 600")
        #expect(SearchIndexBuilder.egNumberLabel(variants, appendix: "NB") == "EG 600 (Ol) · 612 (W)")
        #expect(SearchIndexBuilder.egNumberLabel([song("A", 1), song("B", 2), song("C", 3), song("D", 4)]) == "EG 1 (A) · 2 (B) · 3 (C) …")
        #expect(SearchIndexBuilder.egNumberLabel([]) == nil)
    }

    @Test func titleEntriesUeberspringtEgUndVerweistAufDenIx() {
        let eg = [EgSongEntity(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "P", number: 673, occasion: nil)]
        let entries = SearchIndexBuilder.titleEntries(
            [TitleEntity(ix: 10, title: "Abend ist es, Herr, die Stunde"), TitleEntity(ix: 4292, title: "Kanon"), TitleEntity(ix: 8358, title: "Kanon")],
            egSongs: eg
        )
        #expect(entries.map(\.label) == ["Kanon", "Kanon"])
        #expect(entries.map(\.refKey) == ["4292", "8358"])
    }
}

struct HymnalSectionsTests {

    private func song(_ ix: Int, _ part: String, _ number: Int, _ occasion: String?) -> EgSongEntity {
        EgSongEntity(ix: ix, ixUr: ix, title: "Lied \(ix)", part: part, number: number, occasion: occasion)
    }

    @Test func anhangsliederStehenImAbschnittIhresAnlassesHinterDemStammteil() {
        let sections = HymnalSections.build([
            song(1, "Stamm", 1, "Advent"),
            song(2, "Stamm", 23, "Weihnachten"),
            song(3, "NB", 536, "Advent"),
            song(4, "NB", 539, "Weihnachten"),
            song(5, "NB", 571, "Advent"),
        ])

        #expect(sections.map(\.occasion) == ["Advent", "Weihnachten"])
        #expect(sections[0].songs.map(\.number) == [1, 536, 571])
        #expect(sections[0].songs.map(\.isAppendix) == [false, true, true])
    }

    @Test func anlassNurImAnhangKommtAnsEndeLeerraumWirdBereinigt() {
        let sections = HymnalSections.build([
            song(10, "OL", 600, "Plattdeutsche\nLieder"),
            song(1, "Stamm", 1, " Advent "),
            song(2, "Stamm", 2, nil),
        ])

        #expect(sections.map(\.occasion) == ["Advent", HymnalSections.fallbackOccasion, "Plattdeutsche Lieder"])
    }

    /// Geschütztes Leerzeichen und Zeilentrenner zählen wie auf Android als Leerraum.
    @Test func unicodeLeerraumImAnlass() {
        let sections = HymnalSections.build([
            song(1, "Stamm", 1, "Loben und Danken"),
            song(2, "Stamm", 2, "Loben\u{00A0}und\u{2028}Danken"),
            song(3, "Stamm", 3, "\u{3000}Advent\u{00A0}"),
        ])

        #expect(sections.map(\.occasion) == ["Loben und Danken", "Advent"])
        #expect(sections[0].songs.map(\.number) == [1, 2])
    }

    @Test func doppelteEintraegeNurEinmal() {
        let sections = HymnalSections.build([song(10, "OL", 600, "Abend"), song(10, "Ol", 600, "Abend")])
        #expect(sections.flatMap(\.songs).count == 1)
    }
}
