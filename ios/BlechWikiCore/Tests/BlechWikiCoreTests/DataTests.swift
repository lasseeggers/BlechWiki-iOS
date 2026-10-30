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

    @Test func egNumberLabel() {
        #expect(SearchIndexBuilder.egNumberLabel([song("NB", 600), song("Stamm", 316)]) == "EG 316")
        #expect(SearchIndexBuilder.egNumberLabel([song("alleAnhänge", 9999), song("P", 673), song("BEL", 673), song("W", 612)])
            == "EG 612 (W) · 673 (BEL, P)")
        let variants = [song("Ol", 600), song("W", 612)]
        #expect(SearchIndexBuilder.egNumberLabel(variants, appendix: "OL") == "EG 600")
        #expect(SearchIndexBuilder.egNumberLabel(variants, appendix: "NB") == "EG 600 (Ol) · 612 (W)")
        #expect(SearchIndexBuilder.egNumberLabel([song("A", 1), song("B", 2), song("C", 3), song("D", 4)]) == "EG 1 (A) · 2 (B) · 3 (C) …")
        #expect(SearchIndexBuilder.egNumberLabel([song("alleAnhänge", 9999)]) == nil)
    }

    @Test func titleEntriesUeberspringtEgUndDubletten() {
        let eg = [EgSongEntity(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "P", number: 673, occasion: nil)]
        let entries = SearchIndexBuilder.titleEntries(
            ["Abend ist es, Herr, die Stunde", "Herr, das Licht deiner Liebe", "Herr, das Licht Deiner Liebe", "Anderer Titel"],
            egSongs: eg
        )
        #expect(entries.map(\.label) == ["Herr, das Licht deiner Liebe", "Anderer Titel"])
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

    @Test func doppelteEintraegeNurEinmal() {
        let sections = HymnalSections.build([song(10, "OL", 600, "Abend"), song(10, "Ol", 600, "Abend")])
        #expect(sections.flatMap(\.songs).count == 1)
    }
}
