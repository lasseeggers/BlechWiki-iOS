import Foundation
import SQLite3
import Testing
@testable import BlechWikiCore

/// API mit festen Daten, zählt Abrufe. Die Tabellen verhalten sich wie auf dem Server:
/// `after` = 0 liefert alle nicht gelöschten Einträge, sonst alle mit höherem Änderungszähler,
/// gelöschte eingeschlossen.
final class StubAPI: BlechWikiAPI, @unchecked Sendable {
    var titles = [
        TitleDto(ix: 1, title: "Lobe den Herren, den mächtigen König der Ehren", deleted: false, changeCounter: 60),
        TitleDto(ix: 2, title: "Lobe den Herrn, o Seele mein", deleted: false, changeCounter: 60),
        TitleDto(ix: 3, title: "Großer Gott, wir loben dich", deleted: false, changeCounter: 62),
        TitleDto(ix: 4, title: "Nun danket alle Gott", deleted: false, changeCounter: 69),
    ]
    var egSongs = [
        EgSongDto(ix: 316, ixUr: 859, title: "Lobe den Herren, den mächtigen König der Ehren", part: "Stamm", number: 316, occasion: nil),
        EgSongDto(ix: 900, ixUr: 900, title: "Ein Lied aus Niedersachsen", part: "NB", number: 600, occasion: nil),
        EgSongDto(ix: 901, ixUr: 901, title: "Ein Lied aus Bayern", part: "BT", number: 600, occasion: nil),
        EgSongDto(ix: 1317, ixUr: 316, title: "Go, tell it on the mountain", part: "Add", number: 602, occasion: "Abendmahl"),
    ]
    var books = [
        BookDto(id: "2271", title: "Bläserheft 2022 Bayern", subtitle: "Alte und neue Bläsermusik", year: 2022, editor: nil, editorFirstName: nil,
                publisher: "VPBay", publisherNumber: nil, coverUrl: "https://x/BilderBuch/mini60/BläshBay22.jpg", deleted: false, changeCounter: 122),
        BookDto(id: "17", title: "Posaunenchoralbuch", subtitle: nil, year: nil, editor: "Riegler", editorFirstName: "Thomas",
                publisher: nil, publisherNumber: nil, coverUrl: "https://x/BilderBuch/mini60/Choral.jpg", deleted: false, changeCounter: 120),
    ]
    var composers = [
        ComposerDto(id: "1", name: "Fünfgeld, Traugott", born: "1971", died: nil, isAlias: false, deleted: false, changeCounter: 78),
    ]
    var appendices = [
        EgAppendixDto(code: "Stamm", name: "Stammteil"), EgAppendixDto(code: "Add", name: "Ergänzungen"),
        EgAppendixDto(code: "W", name: "Württemberg"), EgAppendixDto(code: "Ö", name: "Österreich"),
    ]
    var fundstellenCalls: [String] = []
    /// Abrufe der Stammdaten, ohne Fundstellen.
    var calls: [String] = []
    /// Aufruf, der fehlschlägt, z. B. "getBooks" (jedes `after`).
    var failOn: String?

    private func record(_ name: String) throws {
        calls.append(name)
        if let failOn, name == failOn || name.hasPrefix(failOn + "(") { throw BlechWikiError.network("Testfehler bei \(name)") }
    }

    private func since<T>(_ rows: [T], _ after: Int, deleted: KeyPath<T, Bool>, counter: KeyPath<T, Int>) -> TableRows<T> {
        let result = after == 0 ? rows.filter { !$0[keyPath: deleted] } : rows.filter { $0[keyPath: counter] > after }
        return TableRows(rows: result, maxCounter: result.map { $0[keyPath: counter] }.max() ?? 0)
    }

    func getTitles(after: Int) async throws -> TableRows<TitleDto> {
        try record("getTitles(\(after))")
        return since(titles, after, deleted: \.deleted, counter: \.changeCounter)
    }

    func getBooks(after: Int) async throws -> TableRows<BookDto> {
        try record("getBooks(\(after))")
        return since(books, after, deleted: \.deleted, counter: \.changeCounter)
    }

    func getComposers(after: Int) async throws -> TableRows<ComposerDto> {
        try record("getComposers(\(after))")
        return since(composers, after, deleted: \.deleted, counter: \.changeCounter)
    }

    func getEgAppendices() async throws -> [EgAppendixDto] { try record("getEgAppendices"); return appendices }
    func getEgSongs() async throws -> [EgSongDto] { try record("getEgSongs"); return egSongs }
    func getFundstellenByTitle(_ ix: Int) async throws -> [FundstelleDto] {
        fundstellenCalls.append("title:\(ix)")
        return [fundstelle("2271", "Bläserheft 2022 Bayern", "12", "Nun danket alle Gott")]
    }
    func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto] {
        fundstellenCalls.append("eg:\(ixUr)")
        return [fundstelle("2271", "Bläserheft 2022 Bayern", "43", "Lobe den Herren, den mächtigen König der Ehren")]
    }
    func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto] {
        fundstellenCalls.append("book:\(bookId)")
        return [
            fundstelle(bookId, "Bläserheft 2022 Bayern", "43", "Lobe den Herren, den mächtigen König der Ehren"),
            fundstelle(bookId, "Bläserheft 2022 Bayern", "44", "Lobe den Herren, den mächtigen König der Ehren"),
        ]
    }
    func getFundstellenByComposer(_ composerId: String) async throws -> [FundstelleDto] { [] }

    private func fundstelle(_ bookId: String, _ book: String, _ nr: String, _ title: String) -> FundstelleDto {
        FundstelleDto(bookId: bookId, bookTitle: book, number: nr, title: title, addition: nil, composer: nil, scoring: "2+2", keySignature: "1b",
                      coverUrl: "https://x/BilderBuch/mini60/BläshBay22.jpg")
    }
}

@MainActor
struct RepositoryTests {

    let api = StubAPI()
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

    private func container() async throws -> AppContainer {
        let container = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        _ = try await MasterDataSync(api: api, db: container.db).sync()
        return container
    }

    @Test func sucheFindetWortanfaengeInBeliebigerReihenfolge() async throws {
        let c = try await container()
        let results = try c.search.search("herr lob mächt")
        #expect(results.egSongs.map(\.label) == ["Lobe den Herren, den mächtigen König der Ehren"])
        #expect(results.egSongs.first?.detail == "EG 316")
        // EG-Lied steht nicht zusätzlich unter Titel
        #expect(!results.titles.contains { $0.label.hasPrefix("Lobe den Herren, den") })
        #expect(try c.search.search("haendel").isEmpty)
        #expect(try c.search.search("fuenfgeld").composers.map(\.label) == ["Fünfgeld, Traugott"])
        #expect(try c.search.search("fuenfgeld").composers.first?.query == .byComposer("1"))
        #expect(try c.search.search("nun danket").titles.first?.query == .byTitle(4))
    }

    @Test func komponistenLinksNurFuerBekannteNamen() async throws {
        let c = try await container()
        let names = ComposerNames.split("Fünfgeld, Traugott // NN")
        #expect(names == ["Fünfgeld, Traugott", "NN"])
        #expect(try c.search.composerLinks(names: names) ==
            ["Fünfgeld, Traugott": ComposerLink(name: "Fünfgeld, Traugott", id: "1", lifeDates: "geb. 1971")])
        #expect(ComposerNames.fromEditor("Traugott Fünfgeld") == "Fünfgeld, Traugott")
        #expect(ComposerNames.fromEditor("Ben van den Bosch") == "Bosch, Ben van den")
        #expect(ComposerNames.fromEditor("ADU-Verlag") == nil)
    }

    @Test func egNummerBevorzugtEigenenAnhang() async throws {
        let c = try await container()
        #expect(try c.search.search("EG 316").egSongs.first?.query == .byEgMelody(859))
        c.preferences.setEgAppendix("BT")
        let results = try c.search.search("600")
        #expect(results.egSongs.map(\.label) == ["Ein Lied aus Bayern", "Ein Lied aus Niedersachsen"])
        #expect(results.egSongs.first?.detail == "EG 600")
    }

    @Test func ergaenzungVerweistAufDasLiedImEG() async throws {
        let c = try await container()
        let hit = try #require(try c.search.search("go tell it").egSongs.first)
        #expect(hit.detail == "im EG als „Lobe den Herren, den mächtigen König der Ehren“, EG 316")
        #expect(hit.query == .byEgMelody(316))
        // Die Nummern der Ergänzungen sind keine EG-Nummern
        #expect(try c.search.search("602").egSongs.isEmpty)
    }

    @Test func inventarTrefferInDerSuche() async throws {
        let c = try await container()
        c.myBooks.setOwned("2271", owned: true)
        try await c.fundstellen.refresh(.byBook("2271"))
        let hit = try #require(try c.search.search("lobe den herren den").egSongs.first)
        #expect(hit.ownedLocations == [OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "43"), OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "44")])
        #expect(try c.search.search("blaserheft").books.first?.isOwnedBook == true)
        #expect(try c.myBooks.offlineStatus() == OfflineStatus(owned: 1, available: 1))
    }

    @Test func fundstellenCacheSpartRequests() async throws {
        let c = try await container()
        #expect(try await c.fundstellen.refresh(.byEgMelody(859)) == true)
        #expect(try await c.fundstellen.refresh(.byEgMelody(859)) == false)
        #expect(try await c.fundstellen.refresh(.byEgMelody(859), force: true) == true)
        #expect(api.fundstellenCalls == ["eg:859", "eg:859"])
        #expect(try c.fundstellen.fundstellen(.byEgMelody(859)).count == 1)

        // Neue Titel machen den Cache ungültig
        api.titles.append(TitleDto(ix: 5, title: "Neuer Titel", deleted: false, changeCounter: 70))
        _ = try await MasterDataSync(api: api, db: c.db).sync(force: true)
        #expect(try await c.fundstellen.refresh(.byEgMelody(859)) == true)
    }

    /// War die Uhr beim Abruf vorgestellt, gilt der Eintrag nicht bis zu diesem Zeitpunkt als frisch.
    @Test func abrufzeitInDerZukunftGiltAlsVeraltet() async throws {
        let c = try await container()
        let clock = TestNow()
        let fundstellen = FundstellenRepository(api: api, db: c.db, now: { clock.now })
        #expect(try await fundstellen.refresh(.byEgMelody(859)) == true)
        clock.now = clock.now.addingTimeInterval(-24 * 3600)
        #expect(try await fundstellen.refresh(.byEgMelody(859)) == true)
        #expect(try await fundstellen.refresh(.byEgMelody(859)) == false)
    }

    /// Einige Tausend Wörter sprengten den FTS-Ausdrucksbaum, die Suche warf.
    @Test func sehrLangeAnfrage() async throws {
        let c = try await container()
        #expect(try c.search.search((0..<20_000).map { "w\($0)" }.joined(separator: " ")).isEmpty)
        #expect(try c.search.search(String(repeating: "lob ", count: 5000)).egSongs.map(\.label) == ["Lobe den Herren, den mächtigen König der Ehren"])
    }

    @Test func titelUeberIxUntertitelAusDenStammdaten() async throws {
        let c = try await container()
        try await c.fundstellen.refresh(.byTitle(4))
        #expect(api.fundstellenCalls == ["title:4"])
        #expect(try c.fundstellen.fundstellen(.byTitle(4)).map(\.bookSubtitle) == ["Alte und neue Bläsermusik"])
    }

    @Test func abgleichUeberspringtInnerhalb24Stunden() async throws {
        let c = try await container()
        #expect(try await MasterDataSync(api: api, db: c.db).sync() == .skipped)
        #expect(try await MasterDataSync(api: api, db: c.db).sync(force: true) == .checked(updated: []))
        #expect(try c.settings.hasData())
    }

    @Test func buchauswahlUndLandeskirchen() async throws {
        let c = try await container()
        c.preferences.setEgAppendix("BT")
        let sections = try c.myBooks.sections(filter: "")
        #expect(sections.suggested.map(\.id) == ["2271"])
        #expect(sections.choralBooks.map(\.id) == ["17"])
        #expect(sections.all.map(\.id) == ["2271", "17"])
        #expect(try c.myBooks.sections(filter: "riegl").filtered?.map(\.id) == ["17"])
        for filter in ["bläser", "blaser", "blaeser"] {
            #expect(try c.myBooks.sections(filter: filter).filtered?.map(\.id) == ["2271"], "\(filter)")
        }
        #expect(try c.myBooks.book(id: "17")?.editor == "Thomas Riegler")
        #expect(try c.settings.egAppendices().map(\.name) == ["Österreich", "Württemberg"])
    }

    @Test func vorDemErstenAbgleichDieEingebauteListeDerLandeskirchen() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        let appendices = try c.settings.egAppendices()
        #expect(appendices.count == 13)
        #expect(appendices.first?.name == "Baden/Elsaß/Lothringen")
        #expect(appendices.last?.name == "Württemberg")
        c.settings.selectEgAppendix("N")
        #expect(try c.settings.selectedEgAppendix()?.name == "Nordelbien")
    }

    @Test func einfuehrungNurBeimErstenStart() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        #expect(c.settings.needsOnboarding())
        // Landeskirche während der Einführung gewählt, App vor „Fertig“ beendet: beim nächsten Start nicht noch einmal
        c.settings.selectEgAppendix("W")
        #expect(!c.settings.needsOnboarding())

        let fresh = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let d = try AppContainer(api: api, databaseURL: nil, defaults: fresh)
        d.settings.finishOnboarding()
        #expect(!d.settings.needsOnboarding())
    }

    @Test func werSchonBuecherHatSiehtDieEinfuehrungNicht() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        c.myBooks.setOwned("17", owned: true)
        #expect(!c.settings.needsOnboarding())
        #expect(c.preferences.onboardingDone)
    }

    @Test func inventarCodeHinUndZurueck() async throws {
        let c = try await container()
        c.myBooks.setOwned("2271", owned: true)
        let code = try #require(try c.myBooks.inventoryCode())
        c.myBooks.setOwned("2271", owned: false)
        guard case let .ready(books, unknown) = try c.myBooks.inventoryImport("Hier: \(code)") else { Issue.record(); return }
        #expect(books.map(\.id) == ["2271"])
        #expect(unknown == 0)
    }
}

/// Uhr für Tests, die die Zeit verstellen.
private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Stammdaten-Abgleich über die Änderungszähler.
struct MasterDataSyncTests {

    let api = StubAPI()
    let db = try! AppDatabase(url: nil)

    private var sync: MasterDataSync { MasterDataSync(api: api, db: db) }

    /// Je Tabelle ein Request mit dem gespeicherten Zähler, wie nach dem ersten Abgleich.
    private let changeChecks = ["getTitles(69)", "getBooks(122)", "getComposers(78)"]

    @Test func ersterAbgleichLaedtAlleTabellenGanzUndMerktSichDieZaehler() async throws {
        #expect(try await sync.sync() == .checked(updated: [.titles, .books, .composers]))

        #expect(api.calls == ["getTitles(0)", "getBooks(0)", "getComposers(0)", "getEgSongs", "getEgAppendices"])
        let state = try #require(try db.syncState())
        #expect([state.titleChangeCounter, state.bookChangeCounter, state.composerChangeCounter] == [69, 122, 78])
    }

    @Test func ohneAenderungenJeTabelleEinRequest() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()

        #expect(try await sync.sync(force: true) == .checked(updated: []))
        #expect(api.calls == changeChecks)
    }

    @Test func titelWerdenEinzelnErgaenztUndGeloescht() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()
        api.titles.append(TitleDto(ix: 5, title: "Neuer Titel", deleted: false, changeCounter: 70))
        api.titles[1].deleted = true
        api.titles[1].changeCounter = 70

        #expect(try await sync.sync(force: true) == .checked(updated: [.titles]))
        #expect(api.calls == changeChecks)
        #expect(try db.titles().map(\.ix).sorted() == [1, 3, 4, 5])
        #expect(try db.search(match: "neuer*", type: .title, norm: "neuer", limit: 5).map(\.refKey) == ["5"])
        #expect(try db.search(match: "seele*", type: .title, norm: "seele", limit: 5).isEmpty)
        #expect(try db.syncState()?.titleChangeCounter == 70)
    }

    @Test func geaenderteUndGeloeschteBuecherWerdenEinzelnUebernommen() async throws {
        _ = try await sync.sync()
        api.books[0].title = "Bläserheft 2022 Bayern (Neuauflage)"
        api.books[0].changeCounter = 123
        api.books[1].deleted = true
        api.books[1].changeCounter = 123

        #expect(try await sync.sync(force: true) == .checked(updated: [.books]))
        #expect(try db.books().map(\.title) == ["Bläserheft 2022 Bayern (Neuauflage)"])
        #expect(try db.search(match: "neuauflage*", type: .book, norm: "neuauflage", limit: 5).map(\.refKey) == ["2271"])
        #expect(try db.search(match: "posaunenchoralbuch*", type: .book, norm: "posaunenchoralbuch", limit: 5).isEmpty)
        #expect(try db.syncState()?.bookChangeCounter == 123)
    }

    @Test func geaenderterKomponistLaedtDieKomponistenGanzNeu() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()
        api.composers.append(ComposerDto(id: "2", name: "Händel, Georg Friedrich", born: "1685", died: "1759", isAlias: false, deleted: false, changeCounter: 79))
        api.composers.append(ComposerDto(id: "2", name: "Haendel, G. F.", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 79))

        #expect(try await sync.sync(force: true) == .checked(updated: [.composers]))
        #expect(api.calls == changeChecks + ["getComposers(0)"])
        #expect(try db.composers(names: ["Händel, Georg Friedrich", "Haendel, G. F."]).map(\.id) == ["2"])
        #expect(try db.syncState()?.composerChangeCounter == 79)
    }

    @Test func nach30TagenLaedtDerWlanJobAllesNeu() async throws {
        let clock = Clock()
        let sync = MasterDataSync(api: api, db: db, now: { clock.now })
        _ = try await sync.sync()
        api.calls.removeAll()
        clock.now += 31 * 24 * 3600

        #expect(try await sync.sync() == .checked(updated: []))
        #expect(api.calls == changeChecks)
        api.calls.removeAll()
        #expect(try await sync.sync(force: true, fullRefreshIfDue: true) == .checked(updated: [.titles, .books, .composers]))
        #expect(api.calls == ["getTitles(0)", "getBooks(0)", "getComposers(0)", "getEgSongs", "getEgAppendices"])
    }

    @Test func fehlerBeimAbfragenDerAenderungenLaesstDenAltenStandStehen() async throws {
        _ = try await sync.sync()
        api.titles.append(TitleDto(ix: 5, title: "Neuer Titel", deleted: false, changeCounter: 70))
        api.failOn = "getComposers"

        await #expect(throws: BlechWikiError.self) { try await sync.sync(force: true) }
        #expect(try db.syncState()?.titleChangeCounter == 69)
        #expect(try db.titles().map(\.ix).sorted() == [1, 2, 3, 4])
    }

    /// Eine leere ganze Tabelle übernommen hieße: Suche leer bis zum nächsten Abgleich.
    @Test func leereGanzeTabelleIstEinFehler() async throws {
        api.books = []

        await #expect(throws: BlechWikiError.self) { try await sync.sync() }
        #expect(try db.syncState() == nil)
    }

    /// Ein zweiter Aufruf während eines laufenden Abgleichs wartet und sieht danach den frischen Stand.
    @Test func gleichzeitigeAbgleicheLaufenNacheinander() async throws {
        let sync = self.sync
        async let first = sync.sync()
        async let second = sync.sync()
        _ = try await (first, second)

        #expect(api.calls == ["getTitles(0)", "getBooks(0)", "getComposers(0)", "getEgSongs", "getEgAppendices"])
    }

    @Test func fehlerImErstenAbgleichSchreibtNichts() async throws {
        api.failOn = "getBooks"

        await #expect(throws: BlechWikiError.self) { try await sync.sync() }
        #expect(try db.syncState() == nil)
    }

    /// Veränderbare Uhr für den Abgleich.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }
}

@MainActor
struct HymnalRepositoryTests {

    @Test func ohneLandeskircheNurDerStammteilMitLandeskircheAuchIhrAnhang() async throws {
        let api = StubAPI()
        api.egSongs = [
            EgSongDto(ix: 859, ixUr: 859, title: "Lobe den Herren, den mächtigen König der Ehren", part: "Stamm", number: 316, occasion: "Loben und Danken"),
            EgSongDto(ix: 860, ixUr: 859, title: "Lobe den Herren, o meine Seele", part: "Stamm", number: 317, occasion: "Loben und Danken"),
            EgSongDto(ix: 400, ixUr: 400, title: "Großer Gott, wir loben dich", part: "Stamm", number: 331, occasion: "Loben und Danken"),
            EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "BEL", number: 673, occasion: "Abend"),
            EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "P", number: 673, occasion: "Abend"),
        ]
        api.appendices.append(EgAppendixDto(code: "P", name: "Pfalz"))
        let c = try AppContainer(api: api, databaseURL: nil, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        _ = try await MasterDataSync(api: api, db: c.db).sync()

        #expect(try c.hymnal.hymnal().sections.flatMap(\.songs).map(\.number) == [316, 317, 331])

        c.settings.selectEgAppendix("p")
        let withAppendix = try c.hymnal.hymnal()
        #expect(withAppendix.appendix?.name == "Pfalz")
        #expect(withAppendix.sections.map(\.occasion) == ["Loben und Danken", "Abend"])
        #expect(withAppendix.sections[1].songs.map(\.number) == [673])
    }
}

struct SchemaTests {

    /// Version 3 hat neue Schlüssel. Ältere Datenbanken werden verworfen und neu geladen.
    @Test func datenbankVonVersion2WirdNeuAufgebaut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let db = try AppDatabase(url: url)
            try db.write { try AppDatabase.upsertSyncState($0, SyncState(titleChangeCounter: 69, bookChangeCounter: 122, composerChangeCounter: 78, checkedAtMillis: 1_000)) }
            try db.write { try $0.setUserVersion(2) }
        }

        let db = try AppDatabase(url: url)

        #expect(try db.read { try $0.userVersion() } == 4)
        #expect(try db.syncState() == nil)
    }

    /// Version 4 normalisiert anders (ø, æ, Ligaturen). Eine Datenbank von Version 3 behält Stammdaten
    /// und Fundstellen-Cache, nur Suchindex und `titleNorm` werden aus den lokalen Daten neu gebaut.
    @Test func datenbankVonVersion3BautNurDenSuchindexNeu() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let api = StubAPI()
        do {
            let db = try AppDatabase(url: url)
            _ = try await MasterDataSync(api: api, db: db).sync()
            try await FundstellenRepository(api: api, db: db).refresh(.byBook("2271"))
            // Stand wie mit der alten Normalisierung: "Søren" zerfiel in "s ren"
            try db.write {
                try AppDatabase.replaceComposers($0, [ComposerEntity(id: "9", name: "Kierkegaard, Søren", born: nil, died: nil)])
                try $0.execute("DELETE FROM search_index")
                try $0.execute("UPDATE fundstellen SET titleNorm = 'alt'")
                try $0.setUserVersion(3)
            }
        }

        let db = try AppDatabase(url: url)
        let search = SearchRepository(db: db, preferences: UserPreferences(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!, changes: DataChanges()))

        #expect(try db.read { try $0.userVersion() } == 4)
        #expect(try db.syncState()?.titleChangeCounter == 69)
        #expect(try search.search("soren").composers.map(\.label) == ["Kierkegaard, Søren"])
        #expect(try search.search("herr lob mächt").egSongs.count == 1)
        #expect(try search.search("blaserheft").books.map(\.label) == ["Bläserheft 2022 Bayern"])
        #expect(try db.read { db in try db.rows("SELECT DISTINCT titleNorm FROM fundstellen") { $0.text(0) } }
            == ["lobe den herren den machtigen konig der ehren"])
        #expect(api.calls.count == 5)
    }

    /// Eine beschädigte Datei hinterlässt eine Markierung. Beim nächsten Öffnen scheitert die
    /// Datenbank daran, und die App legt sie neu an, statt jeden Abgleich scheitern zu lassen.
    @Test func beschaedigteDateiWirdBeimNaechstenStartVerworfen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", ".corrupt"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let db = try AppDatabase(url: url)
            #expect(throws: (any Error).self) {
                try db.read { _ in throw SQLiteConnection.Error(description: "test", code: SQLITE_CORRUPT) }
            }
        }

        #expect(FileManager.default.fileExists(atPath: AppDatabase.corruptionMarker(url).path))
        #expect(throws: (any Error).self) { try AppDatabase(url: url) }
    }
}
