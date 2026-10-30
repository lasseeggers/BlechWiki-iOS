import Foundation
import Testing
@testable import BlechWikiCore

/// API mit festen Daten, zählt Fundstellen-Abrufe.
final class StubAPI: BlechWikiAPI, @unchecked Sendable {
    var version = DataVersionDto(lastBookNumber: 1, lastComposerNumber: 1, lastTitleNumber: 1)
    var titles = ["Lobe den Herren, den mächtigen König der Ehren", "Lobe den Herrn, o Seele mein", "Großer Gott, wir loben dich", "Nun danket alle Gott"]
    var egSongs = [
        EgSongDto(ix: 316, ixUr: 859, title: "Lobe den Herren, den mächtigen König der Ehren", part: "Stamm", number: 316, occasion: nil),
        EgSongDto(ix: 900, ixUr: 900, title: "Ein Lied aus Niedersachsen", part: "NB", number: 600, occasion: nil),
        EgSongDto(ix: 901, ixUr: 901, title: "Ein Lied aus Bayern", part: "BT", number: 600, occasion: nil),
    ]
    var books = [
        BookDto(id: "BläshBay22", title: "Bläserheft 2022 Bayern", subtitle: nil, year: 2022, editor: nil, editorFirstName: nil, publisher: "VPBay", publisherNumber: nil, coverUrl: "https://x/BilderBuch/mini60/BläshBay22.jpg"),
        BookDto(id: "Choral", title: "Posaunenchoralbuch", subtitle: nil, year: nil, editor: "Riegler", editorFirstName: "Thomas", publisher: nil, publisherNumber: nil, coverUrl: nil),
    ]
    var appendices = [EgAppendixDto(code: "Stamm", name: "Stammteil"), EgAppendixDto(code: "W", name: "Württemberg"), EgAppendixDto(code: "Ö", name: "Österreich")]
    var fundstellenCalls: [String] = []
    /// Abrufe der Stammdaten, ohne Fundstellen.
    var calls: [String] = []

    func getDataVersion() async throws -> DataVersionDto { calls.append("getDataVersion"); return version }
    func getTitles(_ query: String) async throws -> [String] { calls.append("getTitles"); return titles }
    func getTitleCount(_ query: String) async throws -> Int { titles.count }
    func getBooks() async throws -> [BookDto] { calls.append("getBooks"); return books }
    func getComposers() async throws -> [ComposerDto] {
        calls.append("getComposers")
        return [ComposerDto(name: "Fünfgeld, Traugott", shortName: "Fünfgeld T", born: "1971", died: nil)]
    }
    func getEgAppendices() async throws -> [EgAppendixDto] { calls.append("getEgAppendices"); return appendices }
    func getEgSongs() async throws -> [EgSongDto] { calls.append("getEgSongs"); return egSongs }
    func getFundstellenByTitle(_ title: String) async throws -> [FundstelleDto] { fundstellenCalls.append("title:\(title)"); return [] }
    func getFundstellenByEgSong(_ ixUr: Int) async throws -> [FundstelleDto] {
        fundstellenCalls.append("eg:\(ixUr)")
        return [fundstelle("BläshBay22", "Bläserheft 2022 Bayern", "43", "Lobe den Herren, den mächtigen König der Ehren")]
    }
    func getFundstellenByBook(_ bookId: String) async throws -> [FundstelleDto] {
        fundstellenCalls.append("book:\(bookId)")
        return [
            fundstelle(bookId, "Bläserheft 2022 Bayern", "43", "Lobe den Herren, den mächtigen König der Ehren"),
            fundstelle(bookId, "Bläserheft 2022 Bayern", "44", "Lobe den Herren, den mächtigen König der Ehren"),
        ]
    }
    func getFundstellenByComposer(_ shortName: String) async throws -> [FundstelleDto] { [] }

    private func fundstelle(_ bookId: String, _ book: String, _ nr: String, _ title: String) -> FundstelleDto {
        FundstelleDto(bookId: bookId, bookTitle: book, bookSubtitle: nil, number: nr, title: title, addition: nil, composer: nil, scoring: "2+2", keySignature: "1b", coverUrl: nil)
    }
}

/// Attrappe der REST-API. Protokolliert jeden Aufruf in `calls`.
final class StubRestAPI: BlechWikiRestAPI, @unchecked Sendable {
    var calls: [String] = []
    var failing = false

    /// Höchster Änderungszähler je Tabelle, wie im Protokoll des Servers (Stand Oktober 2026).
    var latest: [ChangeTable: Int] = [.titles: 69, .books: 122, .composers: 78]

    private func record(_ name: String) throws {
        calls.append(name)
        if failing { throw BlechWikiError.network("Testfehler bei \(name)") }
    }

    func getLatestChange(_ table: ChangeTable, after: Int) async throws -> Int? {
        try record("changes(\(table.rawValue),\(after))")
        return latest[table].flatMap { $0 > after ? $0 : nil }
    }
}

@MainActor
struct RepositoryTests {

    let api = StubAPI()
    let rest = StubRestAPI()
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

    private func container() async throws -> AppContainer {
        let container = try AppContainer(api: api, restAPI: rest, databaseURL: nil, defaults: defaults)
        _ = try await MasterDataSync(api: api, db: container.db, changeLog: rest).sync()
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
    }

    @Test func komponistenLinksNurFuerBekannteNamen() async throws {
        let c = try await container()
        let names = ComposerNames.split("Fünfgeld, Traugott // NN")
        #expect(names == ["Fünfgeld, Traugott", "NN"])
        #expect(try c.search.composerLinks(names: names) ==
            ["Fünfgeld, Traugott": ComposerLink(name: "Fünfgeld, Traugott", shortName: "Fünfgeld T", lifeDates: "geb. 1971")])
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

    @Test func inventarTrefferInDerSuche() async throws {
        let c = try await container()
        c.myBooks.setOwned("BläshBay22", owned: true)
        try await c.fundstellen.refresh(.byBook("BläshBay22"))
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

        // Neue Datenversion macht den Cache ungültig
        api.version.lastTitleNumber = 2
        _ = try await MasterDataSync(api: api, db: c.db, changeLog: rest).sync(force: true)
        #expect(try await c.fundstellen.refresh(.byEgMelody(859)) == true)
    }

    @Test func abgleichUeberspringtInnerhalb24Stunden() async throws {
        let c = try await container()
        #expect(try await MasterDataSync(api: api, db: c.db, changeLog: rest).sync() == .skipped)
        #expect(try await MasterDataSync(api: api, db: c.db, changeLog: rest).sync(force: true) == .checked(updated: []))
        #expect(try c.settings.hasData())
    }

    @Test func buchauswahlUndLandeskirchen() async throws {
        let c = try await container()
        c.preferences.setEgAppendix("BT")
        let sections = try c.myBooks.sections(filter: "")
        #expect(sections.suggested.map(\.id) == ["BläshBay22"])
        #expect(sections.choralBooks.map(\.id) == ["Choral"])
        #expect(sections.all.map(\.id) == ["BläshBay22", "Choral"])
        #expect(try c.myBooks.sections(filter: "riegl").filtered?.map(\.id) == ["Choral"])
        #expect(try c.myBooks.book(id: "Choral")?.editor == "Thomas Riegler")
        #expect(try c.settings.egAppendices().map(\.name) == ["Österreich", "Württemberg"])
    }

    @Test func inventarCodeHinUndZurueck() async throws {
        let c = try await container()
        c.myBooks.setOwned("BläshBay22", owned: true)
        let code = try #require(try c.myBooks.inventoryCode())
        c.myBooks.setOwned("BläshBay22", owned: false)
        guard case let .ready(books, unknown) = try c.myBooks.inventoryImport("Hier: \(code)") else { Issue.record(); return }
        #expect(books.map(\.id) == ["BläshBay22"])
        #expect(unknown == 0)
    }
}

/// Änderungsprotokoll der REST-API im Stammdaten-Abgleich.
struct ChangeLogSyncTests {

    let api = StubAPI()
    let rest = StubRestAPI()
    let db = try! AppDatabase(url: nil)

    private var sync: MasterDataSync { MasterDataSync(api: api, db: db, changeLog: rest) }

    @Test func ersterAbgleichMerktSichDenStandOhneDasProtokollGanzZuLaden() async throws {
        _ = try await sync.sync()

        let state = try #require(try db.syncState())
        #expect([state.titleChangeCounter, state.bookChangeCounter, state.composerChangeCounter] == [69, 122, 78])
        // Von 256 abwärts halbieren, bis eine Antwort nicht leer ist
        #expect(rest.calls.filter { $0.contains("Buch") } == ["changes(Buch,256)", "changes(Buch,128)", "changes(Buch,64)"])
    }

    @Test func ohneNeueEintraegeImProtokollNurJeEinKleinerRequest() async throws {
        _ = try await sync.sync()
        rest.calls.removeAll()
        api.calls.removeAll()

        #expect(try await sync.sync(force: true) == .checked(updated: []))
        #expect(rest.calls == ["changes(Titel,69)", "changes(Buch,122)", "changes(Komponist,78)"])
        #expect(api.calls == ["getDataVersion"])
    }

    @Test func korrekturAnEinemBuchLaedtBuecherNeuObwohlDieAutoNrGleichBleibt() async throws {
        _ = try await sync.sync()
        api.calls.removeAll()
        rest.latest[.books] = 123

        #expect(try await sync.sync(force: true) == .checked(updated: [.books]))
        #expect(api.calls == ["getDataVersion", "getBooks"])
        #expect(try db.syncState()?.bookChangeCounter == 123)
    }

    @Test func ohneRestServerLaeuftDerAbgleichUeberDieAutoNrWeiter() async throws {
        _ = try await sync.sync()
        rest.failing = true
        api.version.lastComposerNumber = 2

        #expect(try await sync.sync(force: true) == .checked(updated: [.composers]))
        #expect(try db.syncState()?.composerChangeCounter == 78)
    }

    @Test func fehltDerStandNachEinemAusfallWirdErBeimNaechstenAbgleichNachgeholt() async throws {
        rest.failing = true
        _ = try await sync.sync()
        #expect(try db.syncState()?.titleChangeCounter == nil)

        rest.failing = false
        #expect(try await sync.sync(force: true) == .checked(updated: []))
        #expect(try db.syncState()?.titleChangeCounter == 69)
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
            EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "alleAnhänge", number: 9999, occasion: "Abend"),
            EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "BEL", number: 673, occasion: "Abend"),
            EgSongDto(ix: 1, ixUr: 1, title: "Abend ist es Herr; die Stunde", part: "P", number: 673, occasion: "Abend"),
        ]
        api.appendices.append(EgAppendixDto(code: "P", name: "Pfalz"))
        let c = try AppContainer(api: api, restAPI: StubRestAPI(), databaseURL: nil, defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        _ = try await MasterDataSync(api: api, db: c.db, changeLog: StubRestAPI()).sync()

        #expect(try c.hymnal.hymnal().sections.flatMap(\.songs).map(\.number) == [316, 317, 331])

        c.settings.selectEgAppendix("p")
        let withAppendix = try c.hymnal.hymnal()
        #expect(withAppendix.appendix?.name == "Pfalz")
        #expect(withAppendix.sections.map(\.occasion) == ["Loben und Danken", "Abend"])
        #expect(withAppendix.sections[1].songs.map(\.number) == [673])
    }
}

struct MigrationTests {

    /// Version 2 ergänzt nur Spalten. Der Fundstellen-Cache der Inventar-Bücher muss erhalten bleiben.
    @Test func version1WirdMigriertStattNeuAufgebaut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let state = SyncState(lastBookNumber: 5088, lastComposerNumber: 5451, lastTitleNumber: 65738, checkedAtMillis: 1_000, fullSyncAtMillis: 500)
        do {
            // Schema von Version 1: das heutige ohne die Spalten der Änderungszähler
            let db = try AppDatabase(url: url)
            try db.write { conn in
                try AppDatabase.upsertSyncState(conn, state)
                try AppDatabase.replaceFundstellen(
                    conn, queryKey: "book:WBH2025",
                    [FundstelleEntity(queryKey: "book:WBH2025", position: 0, bookId: "WBH2025", bookTitle: "Bläsermusik 2025", bookSubtitle: nil,
                                      number: "113", title: "Lobe den Herren", titleNorm: "lobe den herren", addition: nil, composer: nil,
                                      scoring: nil, keySignature: nil, coverUrl: nil)],
                    state: FetchState(queryKey: "book:WBH2025", fetchedAtMillis: 1_000, titleVersion: 65738)
                )
                for column in ["bookChangeCounter", "composerChangeCounter", "titleChangeCounter"] {
                    try conn.execute("ALTER TABLE sync_state DROP COLUMN \(column)")
                }
            }
            try db.read { $0.userVersion = 1 }
        }

        let db = try AppDatabase(url: url)

        #expect(try db.read { $0.userVersion } == 2)
        #expect(try db.syncState() == state)
        #expect(try db.fundstellen(queryKey: "book:WBH2025").map(\.number) == ["113"])
        var updated = state
        updated.titleChangeCounter = 69
        try db.write { try AppDatabase.upsertSyncState($0, updated) }
        #expect(try db.syncState()?.titleChangeCounter == 69)
    }
}
