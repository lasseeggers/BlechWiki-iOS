import Foundation
import Testing
@testable import BlechWikiCore

/// Dieselben Beispiele wie `ListEntryKeyTest` in der Android-App.
struct ListEntryKeyTests {

    @Test func gleicheSchluesselWieAndroid() {
        #expect(ListEntryKey.title("Lobe den Herren, den mächtigen") == "t:lobe den herren den machtigen")
        #expect(ListEntryKey.piece(bookId: "5084", number: " 12 ", title: "Großer Gott, wir loben dich", addition: "Satz: Bach")
            == "p:5084|12|grosser gott wir loben dich|satz bach")
        #expect(ListEntryKey.piece(bookId: "5084", number: "12a", title: "Großer Gott, wir loben dich", addition: nil)
            == "p:5084|12a|grosser gott wir loben dich|")
        #expect(ListEntryKey.eg(ix: 331) == "eg:331")
        #expect(ListEntryRef.eg(ix: 331, ixUr: 12, title: "Großer Gott", label: "EG 331").key == "eg:331")
    }

    @Test func verschiebenWieSwiftUI() {
        let items = ["a", "b", "c", "d"]
        #expect(ListsRepository.reordered(items, from: [0], to: 3) == ["b", "c", "a", "d"])
        #expect(ListsRepository.reordered(items, from: [3], to: 0) == ["d", "a", "b", "c"])
        #expect(ListsRepository.reordered(items, from: [1, 2], to: 4) == ["a", "d", "b", "c"])
        #expect(ListsRepository.reordered(items, from: [2], to: 1) == ["a", "c", "b", "d"])
        #expect(ListsRepository.reordered(items, from: [7], to: 0) == items)
    }
}

@MainActor
struct ListsRepositoryTests {

    let api = StubAPI()
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

    private func container() async throws -> AppContainer {
        let container = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        _ = try await MasterDataSync(api: api, db: container.db).sync()
        return container
    }

    private func keys(_ c: AppContainer, _ listId: String) throws -> [String] {
        try #require(try c.lists.list(id: listId)).entries.map(\.ref.key)
    }

    /// Positionen direkt aus der Datei, um Lücken zu sehen.
    private func positions(_ c: AppContainer, _ listId: String) throws -> [Int] {
        try c.lists.database.get().entries(listId: listId).map(\.position)
    }

    @Test func favoritenGibtEsImmerUndSieBleiben() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        #expect(c.lists.isAvailable)
        #expect(try c.lists.lists() == [ListSummary(id: "favoriten", name: "Favoriten", entryCount: 0)])
        try c.lists.deleteList(id: ListsRepository.favoritesId)
        try c.lists.renameList(id: ListsRepository.favoritesId, name: "Lieblingslieder")
        #expect(try c.lists.lists().map(\.name) == ["Favoriten"])
    }

    @Test func uebersichtFavoritenObenRestDeutschSortiert() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        for name in ["Zugabe", "  abend ", "Ökumene", "Advent"] { try c.lists.createList(name: name) }
        #expect(try c.lists.createList(name: "   ") == nil)
        #expect(try c.lists.lists().map(\.name) == ["Favoriten", "abend", "Advent", "Ökumene", "Zugabe"])
    }

    @Test func sternSchaltetUmOhneDoppel() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        let song = ListEntryRef.title("Nun danket alle Gott")
        #expect(try c.lists.toggleFavorite(song))
        try c.lists.add(.title("Nun danket alle gott!"), to: ListsRepository.favoritesId)
        #expect(try c.lists.favoriteKeys() == ["t:nun danket alle gott"])
        #expect(try c.lists.lists().first?.entryCount == 1)
        #expect(try !c.lists.toggleFavorite(song))
        #expect(try c.lists.favoriteKeys().isEmpty)
    }

    @Test func normaleListeNimmtDoppelUndHaengtUntenAn() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        let id = try #require(try c.lists.createList(name: "Konzert 3. Advent"))
        try c.lists.add(.title("Macht hoch die Tür"), to: id)
        try c.lists.add(.eg(ix: 316, ixUr: 859, title: "Lobe den Herren", label: "EG 316"), to: id)
        try c.lists.add(.title("Macht hoch die Tür"), to: id)
        #expect(try keys(c, id) == ["t:macht hoch die tur", "eg:316", "t:macht hoch die tur"])
        #expect(try positions(c, id) == [0, 1, 2])
        #expect(try c.lists.listIds(containing: "eg:316") == [id])
        #expect(throws: ListsError.self) { try c.lists.add(.title("X"), to: "gibt-es-nicht") }
    }

    @Test func verschiebenHaeltPositionenLueckenlos() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        let id = try #require(try c.lists.createList(name: "Gottesdienst"))
        for title in ["A", "B", "C", "D"] { try c.lists.add(.title(title), to: id) }
        try c.lists.move(in: id, from: [0], to: 3)
        #expect(try keys(c, id) == ["t:b", "t:c", "t:a", "t:d"])
        #expect(try positions(c, id) == [0, 1, 2, 3])

        let second = try #require(try c.lists.list(id: id)?.entries[1].id)
        try c.lists.remove(entryId: second)
        #expect(try keys(c, id) == ["t:b", "t:a", "t:d"])
        #expect(try positions(c, id) == [0, 1, 2])

        try c.lists.toggleFavorite(.title("A"))
        try c.lists.toggleFavorite(.title("B"))
        try c.lists.toggleFavorite(.title("A"))
        #expect(try positions(c, ListsRepository.favoritesId) == [0])
    }

    @Test func listeLoeschenEntferntIhreEintraege() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        let id = try #require(try c.lists.createList(name: "Weg damit"))
        try c.lists.add(.title("Nun danket alle Gott"), to: id)
        try c.lists.renameList(id: id, name: "  Weg  ")
        #expect(try c.lists.list(id: id)?.name == "Weg")
        try c.lists.deleteList(id: id)
        #expect(try c.lists.list(id: id) == nil)
        #expect(try c.lists.listIds(containing: "t:nun danket alle gott").isEmpty)
        #expect(try c.lists.lists().count == 1)
    }

    @Test func kommentarLeerWirdNilUndLangerWirdGekuerzt() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        try c.lists.toggleFavorite(.title("Nun danket alle Gott"))
        let entry = try #require(try c.lists.list(id: ListsRepository.favoritesId)?.entries.first)
        try c.lists.setComment(entryId: entry.id, comment: "  nur Strophe 1 und 3 ")
        #expect(try c.lists.favoriteComment(key: entry.ref.key) == "nur Strophe 1 und 3")
        try c.lists.setComment(entryId: entry.id, comment: " \n ")
        #expect(try c.lists.list(id: ListsRepository.favoritesId)?.entries.first?.comment == nil)
        #expect(try c.lists.favoriteComment(key: entry.ref.key) == nil)
        try c.lists.setComment(entryId: entry.id, comment: String(repeating: "x", count: 400))
        #expect(try c.lists.list(id: ListsRepository.favoritesId)?.entries.first?.comment?.count == 300)
    }

    @Test func anreicherungAusVerzeichnisUndInventar() async throws {
        let c = try await container()
        c.myBooks.setOwned("2271", owned: true)
        let id = try #require(try c.lists.createList(name: "Konzert"))
        try c.lists.add(.title("Nun danket alle Gott"), to: id)
        try c.lists.add(.title("Gibt es nirgends"), to: id)
        try c.lists.add(.piece(bookId: "17", bookTitle: "Posaunenchoralbuch", number: "5", title: "Großer Gott, wir loben dich", addition: nil), to: id)
        try c.lists.add(.piece(bookId: "17", bookTitle: "Posaunenchoralbuch", number: "99", title: "Gestrichen", addition: "Vorspiel"), to: id)
        try c.lists.add(.eg(ix: 316, ixUr: 859, title: "Lobe den Herren", label: "EG 316"), to: id)
        try c.lists.add(.eg(ix: 900, ixUr: 900, title: "Ein Lied aus Niedersachsen", label: "EG 600 (NB)"), to: id)

        var entries = try #require(try c.lists.list(id: id)).entries
        #expect(entries[0].bookCount == 1)
        #expect(entries[0].ownedLocations == [OwnedLocation(bookTitle: "Bläserheft 2022 Bayern", number: "12")])
        #expect(entries[1].bookCount == 0)
        #expect(entries[1].ownedLocations.isEmpty)

        #expect(!entries[2].isMissing)
        #expect(entries[2].bookTitle == "Posaunenchoralbuch")
        #expect(entries[2].coverUrl == "https://x/BilderBuch/mini60/Choral.jpg")
        #expect(!entries[2].isOwnedBook)
        #expect(entries[3].isMissing)
        #expect(entries[3].title == "Gestrichen")
        #expect(entries[3].addition == "Vorspiel")
        #expect(entries[3].bookTitle == "Posaunenchoralbuch")

        // Alle Sätze zur Melodie, Titel aus dem Verzeichnis
        #expect(entries[4].title == "Lobe den Herren, den mächtigen König der Ehren")
        #expect(entries[4].egNumber == "EG 316")
        #expect(entries[4].ownedLocations.map(\.number) == ["43", "44"])
        #expect(entries[5].egNumber == "EG 600 (NB)")

        // Nummer passend zur Landeskirche
        c.preferences.setEgAppendix("NB")
        entries = try #require(try c.lists.list(id: id)).entries
        #expect(entries[5].egNumber == "EG 600")
    }

    @Test func ohneVerzeichnisDieGespeichertenFelder() throws {
        let c = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        try c.lists.add(.eg(ix: 316, ixUr: 859, title: "Lobe den Herren", label: "EG 316"), to: ListsRepository.favoritesId)
        try c.lists.add(.piece(bookId: "17", bookTitle: "Posaunenchoralbuch", number: "5", title: "Großer Gott", addition: nil), to: ListsRepository.favoritesId)
        let entries = try #require(try c.lists.list(id: ListsRepository.favoritesId)).entries
        #expect(entries[0].title == "Lobe den Herren")
        #expect(entries[0].egNumber == "EG 316")
        #expect(entries[1].bookTitle == "Posaunenchoralbuch")
        #expect(entries[1].isMissing)
    }

    @Test func ohneDateiLaeuftDieAppWeiter() throws {
        struct Kaputt: Error {}
        let c = try AppContainer(api: api, databaseURL: nil, listsDatabaseURL: { throw Kaputt() }, defaults: defaults)
        #expect(!c.lists.isAvailable)
        #expect(c.lists.openError is Kaputt)
        #expect(throws: Kaputt.self) { try c.lists.lists() }
        #expect(try c.settings.hasData() == false)
    }
}

struct ListsDatabaseTests {

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
    }

    private func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal", ".corrupt"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func repository(_ lists: ListsDatabase) throws -> ListsRepository {
        let changes = DataChanges()
        return ListsRepository(
            lists: .success(lists),
            db: try AppDatabase(url: nil, changes: changes),
            preferences: UserPreferences(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!, changes: changes)
        )
    }

    @Test func datenBleibenNachSchliessenUndOeffnen() throws {
        let url = temporaryURL("listen")
        defer { remove(url) }
        let id: String
        do {
            let repo = try repository(try ListsDatabase(url: url))
            id = try #require(try repo.createList(name: "Konzert"))
            try repo.add(.title("Macht hoch die Tür"), to: id)
            try repo.toggleFavorite(.eg(ix: 316, ixUr: 859, title: "Lobe den Herren", label: "EG 316"))
        }

        let repo = try repository(try ListsDatabase(url: url))
        #expect(try repo.lists().map(\.name) == ["Favoriten", "Konzert"])
        #expect(try repo.list(id: id)?.entries.map(\.title) == ["Macht hoch die Tür"])
        #expect(try repo.favoriteKeys() == ["eg:316"])
    }

    @Test func neuaufbauDerAppDatenbankLaesstDieListenUnberuehrt() throws {
        let appURL = temporaryURL("blechwiki")
        let listsURL = temporaryURL("listen")
        defer {
            remove(appURL)
            remove(listsURL)
        }
        do {
            let db = try AppDatabase(url: appURL)
            try db.write { try $0.setUserVersion(4) }
            let repo = try repository(try ListsDatabase(url: listsURL))
            try repo.toggleFavorite(.title("Nun danket alle Gott"))
        }

        let db = try AppDatabase(url: appURL)
        #expect(try db.read { try $0.userVersion() } == 6)
        let repo = try repository(try ListsDatabase(url: listsURL))
        #expect(try repo.favoriteKeys() == ["t:nun danket alle gott"])
    }

    @Test func neuereVersionBleibtUnveraendert() throws {
        let url = temporaryURL("listen")
        defer { remove(url) }
        do {
            let lists = try ListsDatabase(url: url)
            try repository(lists).toggleFavorite(.title("Nun danket alle Gott"))
            try lists.write { try $0.setUserVersion(2) }
        }

        let lists = try ListsDatabase(url: url)
        #expect(lists.isReadOnly)
        let repo = try repository(lists)
        #expect(try repo.favoriteKeys() == ["t:nun danket alle gott"])
        #expect(throws: (any Error).self) { try repo.createList(name: "Neu") }
        #expect(try lists.read { try $0.userVersion() } == 2)
    }

    @Test func aenderungenWerdenGemeldet() async throws {
        let changes = DataChanges()
        let lists = try ListsDatabase(url: nil, changes: changes)
        let stream = changes.stream()
        try repository(lists).toggleFavorite(.title("Nun danket alle Gott"))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }
}
