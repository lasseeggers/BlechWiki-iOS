import Foundation
import SQLite3
import Testing
@testable import BlechWikiCore

/// API mit festen Daten, zählt Abrufe. Die Tabellen verhalten sich wie auf dem Server:
/// `after` = 0 liefert alle nicht gelöschten Einträge, sonst alle mit höherem Änderungszähler,
/// gelöschte eingeschlossen.
final class StubAPI: BlechWikiAPI, @unchecked Sendable {
    var egSongs = [
        EgSongDto(ix: 316, ixUr: 859, title: "Lobe den Herren, den mächtigen König der Ehren", part: "Stamm", number: 316, occasion: nil),
        EgSongDto(ix: 900, ixUr: 900, title: "Ein Lied aus Niedersachsen", part: "NB", number: 600, occasion: nil),
        EgSongDto(ix: 901, ixUr: 901, title: "Ein Lied aus Bayern", part: "BT", number: 600, occasion: nil),
        EgSongDto(ix: 1317, ixUr: 316, title: "Go, tell it on the mountain", part: "Add", number: 602, occasion: "Abendmahl"),
    ]
    var books = [
        BookDto(id: "2271", shortName: "BläshBay22", title: "Bläserheft 2022 Bayern", subtitle: "Alte und neue Bläsermusik", year: 2022, editor: nil,
                editorFirstName: nil, publisher: "VPBay", publisherNumber: nil, coverUrl: "https://x/BilderBuch/mini60/BläshBay22.jpg", deleted: false,
                changeCounter: 122),
        BookDto(id: "17", shortName: "Choral", title: "Posaunenchoralbuch", subtitle: nil, year: nil, editor: "Riegler", editorFirstName: "Thomas",
                publisher: nil, publisherNumber: nil, coverUrl: "https://x/BilderBuch/mini60/Choral.jpg", deleted: false, changeCounter: 120),
    ]
    var composers = [
        ComposerDto(id: "1", shortName: "Fünfgeld T", name: "Fünfgeld, Traugott", born: "1971", died: nil, isAlias: false, deleted: false, changeCounter: 78),
    ]
    var appendices = [
        EgAppendixDto(code: "Stamm", name: "Stammteil"), EgAppendixDto(code: "Add", name: "Ergänzungen"),
        EgAppendixDto(code: "W", name: "Württemberg"), EgAppendixDto(code: "Ö", name: "Österreich"),
    ]
    /// Fundstellen wie `Titel?titelzaehler=`. "EG W" steht in keinem Buch.
    var pieces = [
        piece(40000, "BläshBay22", "43", "Lobe den Herren, den mächtigen König der Ehren", egIx: 316, composer: "Fünfgeld T"),
        piece(40001, "bläshbay22", "44", "Lobe den Herren, den mächtigen König der Ehren", egIx: 316),
        piece(40002, "BläshBay22", "12", "Nun danket alle Gott"),
        piece(40003, "Choral", "5", "Großer Gott, wir loben dich"),
        piece(40004, "Choral", "6", "Lobe den Herrn, o Seele mein"),
        piece(5000, "EG W", "612", "Ein Lied aus Württemberg"),
    ]
    /// Zähler je Buch, wie `Buch/{id}` sie als titelZ liefert. Ohne Eintrag: alle Zähler des Buchs aus `pieces`.
    var bookCounters: [String: Set<Int>] = [:]
    var calls: [String] = []
    /// Aufruf, der fehlschlägt, z. B. "getBooks" (jedes `after`).
    var failOn: String?

    static func piece(_ counter: Int, _ book: String, _ number: String, _ title: String, egIx: Int? = nil, composer: String? = nil) -> PieceDto {
        PieceDto(counter: counter, bookShortName: book, number: number, title: title, addition: nil, keySignature: "1b", egIx: egIx,
                 scoring: "2+2", composerShortName: composer, composerShortName2: nil)
    }

    private func record(_ name: String) throws {
        calls.append(name)
        if let failOn, name == failOn || name.hasPrefix(failOn + "(") { throw BlechWikiError.network("Testfehler bei \(name)") }
    }

    private func since<T>(_ rows: [T], _ after: Int, deleted: KeyPath<T, Bool>, counter: KeyPath<T, Int>) -> TableRows<T> {
        let result = after == 0 ? rows.filter { !$0[keyPath: deleted] } : rows.filter { $0[keyPath: counter] > after }
        return TableRows(rows: result, maxCounter: result.map { $0[keyPath: counter] }.max() ?? 0)
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

    func getPieces(after: Int) async throws -> [PieceDto] {
        try record("getPieces(\(after))")
        return pieces.filter { $0.counter > after }
    }

    func getBookPieceCounters(_ bookId: String) async throws -> Set<Int> {
        try record("bookCounters(\(bookId))")
        if let counters = bookCounters[bookId] { return counters }
        let shortName = books.first { $0.id == bookId }?.shortName ?? ""
        return Set(pieces.filter { $0.bookShortName.caseInsensitiveCompare(shortName) == .orderedSame }.map(\.counter))
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
        #expect(try c.search.search("nun danket").titles.first?.query == .title("Nun danket alle Gott"))
    }

    @Test func innerhalbDerStufenMehrFundstellenZuerst() async throws {
        api.composers.append(ComposerDto(id: "3", shortName: "Fünfgeld A", name: "Fünfgeld, Annegret-Maria", born: nil, died: nil,
                                         isAlias: false, deleted: false, changeCounter: 79))
        api.pieces += (40010...40012).map { StubAPI.piece($0, "Choral", "\($0)", "Herr, wir bitten: Komm und segne uns", composer: "Fünfgeld A") }
        api.pieces += (40013...40014).map { StubAPI.piece($0, "Choral", "\($0)", "Herr, das Licht deiner Liebe") }
        api.pieces.append(StubAPI.piece(40015, "Choral", "20", "Ein Lied aus Niedersachsen", egIx: 900))
        let c = try await container()

        // Beide beginnen mit „herr“, der längere hat drei Fundstellen statt zwei
        #expect(try c.search.search("herr").titles.prefix(2).map(\.label) == ["Herr, wir bitten: Komm und segne uns", "Herr, das Licht deiner Liebe"])
        // Kein Treffer beginnt mit „lied“. Zu „Ein Lied aus Bayern“ gibt es keinen Satz.
        #expect(try c.search.search("lied").egSongs.map(\.label) == ["Ein Lied aus Niedersachsen", "Ein Lied aus Bayern"])
        #expect(try c.search.search("fünfgeld").composers.map(\.label) == ["Fünfgeld, Annegret-Maria", "Fünfgeld, Traugott"])

        // Neue Fundstellen ändern die Reihenfolge
        api.pieces += (40016...40017).map { StubAPI.piece($0, "Choral", "\($0)", "Herr, das Licht deiner Liebe") }
        _ = try await MasterDataSync(api: api, db: c.db).fetchNewPieces(force: true)
        #expect(try c.search.search("herr").titles.prefix(2).map(\.label) == ["Herr, das Licht deiner Liebe", "Herr, wir bitten: Komm und segne uns"])
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
        #expect(try c.search.search("lobe den herren den").egSongs.first?.ownedLocations == [])
        c.myBooks.setOwned("2271", owned: true)
        let hit = try #require(try c.search.search("lobe den herren den").egSongs.first)
        #expect(hit.ownedLocations == [OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "43"), OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "44")])
        #expect(try c.search.search("blaserheft").books.first?.isOwnedBook == true)
        #expect(try c.myBooks.offlineStatus() == OfflineStatus(owned: 1, available: 1))
    }

    /// Einige Tausend Wörter sprengten den FTS-Ausdrucksbaum, die Suche warf.
    @Test func sehrLangeAnfrage() async throws {
        let c = try await container()
        #expect(try c.search.search((0..<20_000).map { "w\($0)" }.joined(separator: " ")).isEmpty)
        #expect(try c.search.search(String(repeating: "lob ", count: 5000)).egSongs.map(\.label) == ["Lobe den Herren, den mächtigen König der Ehren"])
    }

    @Test func titelInEigenenBuechernAuchInAndererSchreibweise() async throws {
        let c = try await container()
        api.pieces.append(StubAPI.piece(40005, "BläshBay22", "13", "Nun danket alle gott"))
        _ = try await MasterDataSync(api: api, db: c.db).sync(force: true)
        c.myBooks.setOwned("2271", owned: true)
        let hit = try #require(try c.search.search("nun danket").titles.first)
        #expect(hit.ownedLocations == [OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "12"), OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "13")])
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
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Mitgelieferter Stand für Tests. `readCount` zählt, wie oft die Zeilen gelesen wurden.
final class FakeSnapshot: PieceSnapshot, @unchecked Sendable {
    private let lock = NSLock()
    private var _stand: String?
    private var _rows: [PieceDto]
    private var _readCount = 0

    init(stand: String?, rows: [PieceDto]) {
        _stand = stand
        _rows = rows
    }

    var standValue: String? { get { lock.withLock { _stand } } set { lock.withLock { _stand = newValue } } }
    var rows: [PieceDto] { get { lock.withLock { _rows } } set { lock.withLock { _rows = newValue } } }
    var readCount: Int { lock.withLock { _readCount } }

    func stand() -> String? { standValue }

    func pieces() throws -> [PieceDto] {
        lock.withLock {
            _readCount += 1
            return _rows
        }
    }
}

/// Stammdaten-Abgleich über die Änderungszähler.
struct MasterDataSyncTests {

    let api = StubAPI()
    let db = try! AppDatabase(url: nil)

    private var sync: MasterDataSync { MasterDataSync(api: api, db: db) }

    /// Je Tabelle ein Request mit dem gespeicherten Zähler, wie nach dem ersten Abgleich.
    private let changeChecks = ["getBooks(122)", "getComposers(78)", "getPieces(40004)"]
    private let fullLoad = ["getBooks(0)", "getComposers(0)", "getEgSongs", "getEgAppendices"]

    private func titleIndex() throws -> [String] {
        try db.read { try $0.rows("SELECT label FROM search_index WHERE type = 1 ORDER BY label") { $0.text(0) } }
    }

    @Test func ersterAbgleichOhneMitgeliefertenStandLaedtAllesUndMerktSichDieZaehler() async throws {
        #expect(try await sync.sync() == .checked(updated: [.pieces, .books, .composers]))

        #expect(api.calls == fullLoad + ["getPieces(0)"])
        let state = try #require(try db.syncState())
        #expect([state.bookChangeCounter, state.composerChangeCounter, state.pieceCounter] == [122, 78, 40004])
    }

    @Test func titelImSuchindexNurAusBuechernImVerzeichnisOhneEgLieder() async throws {
        _ = try await sync.sync()

        #expect(try titleIndex() == ["Großer Gott, wir loben dich", "Lobe den Herrn, o Seele mein", "Nun danket alle Gott"])
        #expect(try db.search(match: "danket*", type: .title, norm: "danket", limit: 5).map(\.refKey) == ["nun danket alle gott"])
    }

    @Test func ohneAenderungenJeTabelleEinRequest() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()

        #expect(try await sync.sync(force: true) == .checked(updated: []))
        #expect(api.calls == changeChecks)
    }

    @Test func neueFundstellenWerdenErgaenztOhneAlleNeuZuLaden() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()
        api.pieces.append(StubAPI.piece(40100, "Choral", "7", "Neues Stück"))

        #expect(try await sync.sync(force: true) == .checked(updated: [.pieces]))
        #expect(api.calls == changeChecks)
        #expect(try db.search(match: "neues*", type: .title, norm: "neues", limit: 5).map(\.refKey) == ["neues stuck"])
        #expect(try db.syncState()?.pieceCounter == 40100)
    }

    @Test func nurNeueFundstellenHoechstensAlle10Minuten() async throws {
        let clock = Clock()
        let sync = MasterDataSync(api: api, db: db, now: { clock.now })
        _ = try await sync.sync()
        api.calls.removeAll()
        api.pieces.append(StubAPI.piece(40100, "Choral", "7", "Neues Stück"))

        #expect(try await sync.fetchNewPieces() == false)
        clock.now += 11 * 60
        #expect(try await sync.fetchNewPieces() == true)
        #expect(api.calls == ["getPieces(40004)"])
        #expect(try db.countersOfBook("17").contains(40100))
    }

    @Test func geaenderteUndGeloeschteBuecherWerdenEinzelnUebernommenIhreTitelVerschwinden() async throws {
        _ = try await sync.sync()
        api.books[0].title = "Bläserheft 2022 Bayern (Neuauflage)"
        api.books[0].changeCounter = 123
        api.books[1].deleted = true
        api.books[1].changeCounter = 123

        #expect(try await sync.sync(force: true) == .checked(updated: [.books]))
        #expect(try db.books().map(\.title) == ["Bläserheft 2022 Bayern (Neuauflage)"])
        #expect(try db.search(match: "neuauflage*", type: .book, norm: "neuauflage", limit: 5).map(\.refKey) == ["2271"])
        #expect(try db.search(match: "posaunenchoralbuch*", type: .book, norm: "posaunenchoralbuch", limit: 5).isEmpty)
        #expect(try titleIndex() == ["Nun danket alle Gott"])
        #expect(try db.syncState()?.bookChangeCounter == 123)
    }

    @Test func geaenderterKomponistLaedtDieKomponistenGanzNeu() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()
        api.composers.append(ComposerDto(id: "2", shortName: "Händel G F", name: "Händel, Georg Friedrich", born: "1685", died: "1759", isAlias: false, deleted: false, changeCounter: 79))
        api.composers.append(ComposerDto(id: "2", shortName: "Händel G F", name: "Haendel, G. F.", born: nil, died: nil, isAlias: true, deleted: false, changeCounter: 79))

        #expect(try await sync.sync(force: true) == .checked(updated: [.composers]))
        #expect(api.calls == ["getBooks(122)", "getComposers(78)", "getComposers(0)", "getPieces(40004)"])
        #expect(try db.composers(names: ["Händel, Georg Friedrich", "Haendel, G. F."]).map(\.id) == ["2"])
        #expect(try db.syncState()?.composerChangeCounter == 79)
    }

    @Test func doppelteKurznamenVonKomponistenNurEinmal() async throws {
        api.composers.append(ComposerDto(id: "3", shortName: "fünfgeld t", name: "Fünfgeld, Anderer", born: nil, died: nil, isAlias: false, deleted: false, changeCounter: 78))
        _ = try await sync.sync()

        #expect(try db.composers(names: ["Fünfgeld, Traugott", "Fünfgeld, Anderer"]).sorted { $0.id < $1.id }.map(\.shortName) == ["Fünfgeld T", nil])
    }

    @Test func nach30TagenLaedtDerWlanJobDieStammdatenNeuFundstellenNurNeue() async throws {
        let clock = Clock()
        let sync = MasterDataSync(api: api, db: db, now: { clock.now })
        _ = try await sync.sync()
        api.calls.removeAll()
        clock.now += 31 * 24 * 3600

        #expect(try await sync.sync() == .checked(updated: []))
        #expect(api.calls == changeChecks)
        api.calls.removeAll()
        #expect(try await sync.sync(force: true, fullRefreshIfDue: true) == .checked(updated: [.books, .composers]))
        #expect(api.calls == fullLoad + ["getPieces(40004)"])
    }

    @Test func fehlerBeimAbfragenDerAenderungenLaesstDenAltenStandStehen() async throws {
        _ = try await sync.sync()
        api.pieces.append(StubAPI.piece(40100, "Choral", "7", "Neues Stück"))
        api.failOn = "getComposers"

        await #expect(throws: BlechWikiError.self) { try await sync.sync(force: true) }
        #expect(try db.syncState()?.pieceCounter == 40004)
        #expect(try !db.countersOfBook("17").contains(40100))
    }

    /// Eine leere ganze Tabelle übernommen hieße: Suche leer bis zum nächsten Abgleich.
    @Test func leereGanzeTabelleIstEinFehler() async throws {
        api.books = []

        await #expect(throws: BlechWikiError.self) { try await sync.sync() }
        #expect(try db.syncState() == nil)
    }

    /// Am 04.11.2026 lieferte ein Filterfehler auf dem Server kurz fast keine Fundstellen.
    @Test func leereFundstellenBeimErstenAbgleichSindEinFehler() async throws {
        api.pieces = []

        await #expect(throws: BlechWikiError.self) { try await sync.sync() }
        #expect(try db.syncState() == nil)
    }

    /// Ein zweiter Aufruf während eines laufenden Abgleichs wartet und sieht danach den frischen Stand.
    @Test func gleichzeitigeAbgleicheLaufenNacheinander() async throws {
        let sync = self.sync
        async let first = sync.sync()
        async let second = sync.sync()
        _ = try await (first, second)

        #expect(api.calls == fullLoad + ["getPieces(0)"])
    }

    @Test func fehlerImErstenAbgleichSchreibtNichts() async throws {
        api.failOn = "getBooks"

        await #expect(throws: BlechWikiError.self) { try await sync.sync() }
        #expect(try db.syncState() == nil)
    }

    // MARK: Mitgelieferter Stand

    private let stand = "2026-11-05T17:45:07Z"

    /// Stand ohne die neueste Fundstelle, wie bei einer App, die älter ist als das letzte neue Buch.
    private func snapshot() -> FakeSnapshot {
        FakeSnapshot(stand: stand, rows: api.pieces.filter { $0.counter != 40004 })
    }

    @Test func mitgelieferterStandErsetztDenGrossenDownloadDanachNurNeues() async throws {
        let snapshot = snapshot()

        _ = try await MasterDataSync(api: api, db: db, snapshot: snapshot).sync()

        #expect(api.calls == fullLoad + ["getPieces(40003)"])
        #expect(snapshot.readCount == 1)
        #expect(try db.countersOfBook("17").sorted() == [40003, 40004])
        #expect(try db.syncState()?.importedSnapshot == stand)
    }

    @Test func derselbeStandWirdNurEinmalGelesen() async throws {
        let snapshot = snapshot()
        let sync = MasterDataSync(api: api, db: db, snapshot: snapshot)
        _ = try await sync.sync()

        _ = try await sync.sync(force: true)

        #expect(snapshot.readCount == 1)
    }

    @Test func neuerStandNachEinemUpdateErsetztAlleFundstellenAuchOhneNetz() async throws {
        let snapshot = snapshot()
        let sync = MasterDataSync(api: api, db: db, snapshot: snapshot)
        _ = try await sync.sync()
        try db.write { try AppDatabase.upsertBookCheck($0, bookId: "2271", checkedAtMillis: 1) }
        api.failOn = "getBooks"

        snapshot.standValue = "2026-12-01T10:00:00Z"
        snapshot.rows = snapshot.rows.filter { $0.counter != 40001 }
        #expect(try await sync.sync() == .skipped)

        #expect(try db.countersOfBook("2271").sorted() == [40000, 40002])
        #expect(try db.syncState()?.piecesCheckedAtMillis == 1_796_119_200_000)
        // Ein Buch, das vor dem Stand abgeglichen wurde, wird neu abgeglichen
        #expect(try db.bookCheckedAtMillis("2271") == nil)
    }

    @Test func standWirdAuchOhneNetzUebernommen() async throws {
        api.failOn = "getBooks"

        await #expect(throws: BlechWikiError.self) { try await MasterDataSync(api: api, db: db, snapshot: snapshot()).sync() }
        #expect(try db.syncState()?.pieceCounter == 40003)
        #expect(try db.syncState()?.isComplete == false)
    }

    @Test func alleDatenNeuLadenHoltAllesVomServerAuchMitStand() async throws {
        let snapshot = snapshot()
        let sync = MasterDataSync(api: api, db: db, snapshot: snapshot)
        _ = try await sync.sync()
        try db.write { try AppDatabase.upsertBookCheck($0, bookId: "2271", checkedAtMillis: 1) }
        api.calls.removeAll()

        _ = try await sync.sync(reloadAll: true)

        #expect(api.calls == fullLoad + ["getPieces(0)"])
        #expect(snapshot.readCount == 1)
        #expect(try db.bookCheckedAtMillis("2271") == nil)
    }

    /// Veränderbare Uhr für den Abgleich.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }
}

/// Fundstellen aus der lokalen Tabelle und Abgleich einzelner Bücher.
struct FundstellenRepositoryTests {

    let api = StubAPI()
    let db = try! AppDatabase(url: nil)
    let clock = TestNow()

    private func repository() async throws -> FundstellenRepository {
        let clock = clock
        let sync = MasterDataSync(api: api, db: db, now: { clock.now })
        _ = try await sync.sync()
        api.calls.removeAll()
        return FundstellenRepository(api: api, db: db, sync: sync, now: { clock.now })
    }

    private func numbers(_ repository: FundstellenRepository, _ query: FundstellenQuery) throws -> [String] {
        try repository.fundstellen(query).map(\.number)
    }

    @Test func egLiedZeigtAlleSaetzeZurMelodieOhneNetz() async throws {
        let repository = try await repository()
        let pieces = try repository.fundstellen(.byEgMelody(859))

        #expect(pieces.map(\.number) == ["43", "44"])
        #expect(pieces.first?.bookSubtitle == "Alte und neue Bläsermusik")
        #expect(pieces.first?.composer == "Fünfgeld, Traugott")
        #expect(api.calls.isEmpty)
    }

    @Test func buchUeberDenKurznamenOhneGrossKleinschreibungNachNummer() async throws {
        #expect(try numbers(try await repository(), .byBook("2271")) == ["12", "43", "44"])
    }

    @Test func titelUndKomponist() async throws {
        let repository = try await repository()
        #expect(try numbers(repository, .title("Nun danket alle Gott")) == ["12"])
        #expect(try numbers(repository, .byComposer("1")) == ["43"])
    }

    @Test func standIstDerLetzteAbgleich() async throws {
        #expect(try await repository().fetchedAt(.byBook("2271")) == clock.now)
    }

    @Test func abgleichEinesBuchsLoeschtWasDerServerNichtMehrKennt() async throws {
        let repository = try await repository()
        api.bookCounters = ["2271": [40000]]

        #expect(try await repository.refresh(.byBook("2271")) == true)

        // Neue Fundstellen wurden eben erst geholt, deshalb nur der Abgleich
        #expect(api.calls == ["bookCounters(2271)"])
        #expect(try numbers(repository, .byBook("2271")) == ["43"])
    }

    @Test func abgleichHoechstensAlle30Tage() async throws {
        let repository = try await repository()
        #expect(try await repository.refresh(.byBook("2271")) == true)
        api.calls.removeAll()

        #expect(try await repository.refresh(.byBook("2271")) == false)
        #expect(api.calls.isEmpty)

        clock.now = clock.now.addingTimeInterval(31 * 24 * 3600)
        #expect(try await repository.refresh(.byBook("2271")) == true)
        #expect(api.calls == ["getPieces(40004)", "bookCounters(2271)"])
    }

    /// War die Uhr beim Abgleich vorgestellt, gilt er nicht bis zu diesem Zeitpunkt als frisch.
    @Test func abgleichInDerZukunftGiltAlsVeraltet() async throws {
        let repository = try await repository()
        #expect(try await repository.refresh(.byBook("2271")) == true)
        clock.now = clock.now.addingTimeInterval(-24 * 3600)

        #expect(try await repository.refresh(.byBook("2271")) == true)
        #expect(try await repository.refresh(.byBook("2271")) == false)
    }

    @Test func leereAntwortLoeschtNichts() async throws {
        let repository = try await repository()
        api.bookCounters = ["2271": []]

        try await repository.refresh(.byBook("2271"))

        #expect(try numbers(repository, .byBook("2271")).count == 3)
    }

    /// Die Korrektur hat einen neuen Zähler. Sie muss da sein, bevor die alte Fassung verschwindet.
    @Test func korrekturErsetztDieAlteZeile() async throws {
        let repository = try await repository()
        api.pieces = api.pieces.filter { $0.counter != 40002 } + [StubAPI.piece(40010, "BläshBay22", "12", "Nun danket all Gott")]
        api.bookCounters = ["2271": [40000, 40001, 40010]]

        try await repository.refresh(.byBook("2271"), force: true)

        #expect(api.calls == ["getPieces(40004)", "bookCounters(2271)"])
        #expect(try repository.fundstellen(.byBook("2271")).map(\.title).first == "Nun danket all Gott")
        #expect(try numbers(repository, .byBook("2271")) == ["12", "43", "44"])
    }

    @Test func fehlerLaesstDieDatenStehenUndWirdBeimNaechstenMalWiederholt() async throws {
        let repository = try await repository()
        api.failOn = "bookCounters(2271)"

        await #expect(throws: BlechWikiError.self) { try await repository.refresh(.byBook("2271")) }
        #expect(try numbers(repository, .byBook("2271")).count == 3)

        api.failOn = nil
        #expect(try await repository.refresh(.byBook("2271")) == true)
    }

    @Test func andereSeitenHolenNurAufWunschNeueFundstellen() async throws {
        let repository = try await repository()

        #expect(try await repository.refresh(.byEgMelody(859)) == false)
        #expect(api.calls.isEmpty)

        #expect(try await repository.refresh(.byEgMelody(859), force: true) == true)
        #expect(api.calls == ["getPieces(40004)"])
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

    /// Ältere Datenbanken werden verworfen und neu geladen. Version 4 hatte noch einen
    /// Fundstellen-Cache pro Abfrage und die Titel-Tabelle, Version 5 noch keine `search_weights`.
    @Test(arguments: [2, 4, 5])
    func datenbankEinerAlterenVersionWirdNeuAufgebaut(version: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let db = try AppDatabase(url: url)
            var state = SyncState.empty
            state.bookChangeCounter = 122
            try db.write { try AppDatabase.upsertSyncState($0, state) }
            try db.write { try $0.setUserVersion(version) }
        }

        let db = try AppDatabase(url: url)

        #expect(try db.read { try $0.userVersion() } == 6)
        #expect(try db.syncState() == nil)
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
