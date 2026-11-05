import Foundation
import SQLite3
import Testing
@testable import BlechWikiCore

/// Server mit festen JSON-Antworten je Tabelle und Zähler, für Abgleiche über die echte
/// `JsonBlechWikiAPI`. Merkt sich die Requests als "Tabelle@Zähler", die Fundstellen als "Fundstellen@Zähler".
private final class RoutingTransport: @unchecked Sendable {
    var bodies: [String: String]
    private(set) var requests: [String] = []
    private let lock = NSLock()

    init(_ bodies: [String: String]) {
        self.bodies = bodies
    }

    var api: JsonBlechWikiAPI {
        JsonBlechWikiAPI(baseURL: URL(string: "https://example.org/api/")!, transport: { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let key = query["Tabelle"].map { "\($0)@\(query["counter"] ?? "")" }
                ?? query["titelzaehler"].map { "Fundstellen@\($0)" }
                ?? request.url!.lastPathComponent
            let body = self.lock.withLock {
                self.requests.append(key)
                return self.bodies[key] ?? "[]"
            }
            return (Data(body.utf8), 200)
        })
    }
}

/// API, die an `StubAPI` weitergibt. `beforeBooks` läuft vor jedem Bücher-Abruf, dem ersten
/// Request eines Abgleichs, z. B. um ihn aufzuhalten.
private final class HookedAPI: BlechWikiAPI, @unchecked Sendable {
    let stub: StubAPI
    var beforeBooks: (@Sendable () async throws -> Void)?

    init(_ stub: StubAPI) {
        self.stub = stub
    }

    func getBooks(after: Int) async throws -> TableRows<BookDto> {
        try await beforeBooks?()
        return try await stub.getBooks(after: after)
    }
    func getComposers(after: Int) async throws -> TableRows<ComposerDto> { try await stub.getComposers(after: after) }
    func getEgSongs() async throws -> [EgSongDto] { try await stub.getEgSongs() }
    func getEgAppendices() async throws -> [EgAppendixDto] { try await stub.getEgAppendices() }
    func getPieces(after: Int) async throws -> [PieceDto] { try await stub.getPieces(after: after) }
    func getBookPieceCounters(_ bookId: String) async throws -> Set<Int> { try await stub.getBookPieceCounters(bookId) }
}

/// Stand mit Zählern wie nach einem ersten Abgleich, für Tests, die nur irgendeinen Stand schreiben.
private let someState: SyncState = {
    var state = SyncState.empty
    state.bookChangeCounter = 122
    state.checkedAtMillis = 1_000
    return state
}()

private func temporaryDatabaseURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
}

private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", ".corrupt"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}

/// Abgleich, wenn der Server unvollständige Einträge liefert.
struct MasterDataSyncRobustnessTests {

    /// Ein neues Buch ohne Kurznamen allein im Änderungsprotokoll hielt jeden Abgleich auf, bis
    /// zum nächsten Vollabgleich im WLAN. Jetzt wird es übersprungen, und der Zähler rückt vor.
    @Test func unlesbarerEintragAlleinImDeltaBlockiertNichts() async throws {
        let server = RoutingTransport([
            "Fundstellen@0": #"[{"Zähler":10,"Quelle_kurz":"Heft","Seite_Nr":1,"Titel":"Lobe den Herren","EGIx":316}]"#,
            "Buch@0": #"[{"buchId":"1","buchkurz":"Heft","buch":"Heft","changecounter":122,"change":"new"}]"#,
            "Komponist@0": #"[{"id":"1","komponist":"Bach, Johann Sebastian (1685-1750)","friendlyKomponistName":"Bach, Johann Sebastian","changecounter":78,"change":"new"}]"#,
            "EG": #"[{"nr":316,"lied":"Lobe den Herren","anlass":"Loben","ix":316,"ixUr":859,"egTeil":"Stamm"}]"#,
            "Buch@122": #"[{"buchId":"3","buchkurz":null,"buch":"Neu","changecounter":124,"change":"new"}]"#,
        ])
        let db = try AppDatabase(url: nil)
        let sync = MasterDataSync(api: server.api, db: db)
        _ = try await sync.sync()

        #expect(try await sync.sync(force: true) == .checked(updated: [.books]))
        #expect(try db.syncState()?.bookChangeCounter == 124)
        #expect(try db.bookIds() == ["1"])

        #expect(try await sync.sync(force: true) == .checked(updated: []))
        #expect(server.requests.suffix(3) == ["Buch@124", "Komponist@78", "Fundstellen@10"])
    }

    /// Die ganze Tabelle enthält keine gelöschten Einträge. Ihr Zähler liegt nach einer Löschung
    /// unter dem bekannten. Sänke der gespeicherte Zähler, käme die Löschung beim nächsten Abgleich noch einmal.
    @Test func vollabgleichSenktDenZaehlerNicht() async throws {
        let api = StubAPI()
        let db = try AppDatabase(url: nil)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = { @Sendable [now] in now }
        _ = try await MasterDataSync(api: api, db: db, now: clock).sync()
        api.books.append(BookDto(id: "9", shortName: "Weg", title: "Gelöscht", subtitle: nil, year: nil, editor: nil, editorFirstName: nil,
                                 publisher: nil, publisherNumber: nil, coverUrl: "", deleted: true, changeCounter: 123))
        _ = try await MasterDataSync(api: api, db: db, now: clock).sync(force: true)
        #expect(try db.syncState()?.bookChangeCounter == 123)

        now += MasterDataSync.fullRefreshInterval + 1
        let later = { @Sendable [now] in now }
        api.calls.removeAll()
        _ = try await MasterDataSync(api: api, db: db, now: later).sync(fullRefreshIfDue: true)

        #expect(api.calls.first == "getBooks(0)")
        #expect(try db.syncState()?.bookChangeCounter == 123)
    }
}

/// Zusammenspiel von Abgleich und Inventar im `SyncCoordinator`.
@MainActor
struct SyncCoordinatorTests {

    let stub = StubAPI()
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

    /// Wartet höchstens 5 s darauf, dass `condition` erfüllt ist.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Die Prüfung aus dem Import-Dialog bricht einen hängenden Abgleich ab, statt auf ihn zu warten.
    @Test func checkCatalogNowWartetNichtAufDenAltenAbgleich() async throws {
        let api = HookedAPI(stub)
        let calls = CallCounter()
        api.beforeBooks = {
            // Nur der erste Abruf hängt, bis er abgebrochen wird
            if calls.increment() == 1 { try await Task.sleep(for: .seconds(60)) }
        }
        let container = try AppContainer(api: api, databaseURL: nil, defaults: defaults)
        container.sync.onAppActive(unmetered: false)
        try await eventually { calls.value == 1 }

        let start = ContinuousClock.now
        #expect(await container.sync.checkCatalogNow())

        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(container.sync.status == .idle)
        #expect(try container.db.syncState() != nil)
    }

    /// Für Buch-IDs, die nicht im Verzeichnis stehen, antwortet der Server mit HTTP 500. Ein vom
    /// Server gelöschtes Buch im Inventar kostete sonst bei jedem Aktivieren vier Requests.
    @Test func inventarLaedtNurBuecherAusDemVerzeichnis() async throws {
        let container = try AppContainer(api: stub, databaseURL: nil, defaults: defaults)
        // "1000" käme sortiert vor "2271" dran
        container.myBooks.setOwned("1000", owned: true)
        container.myBooks.setOwned("2271", owned: true)

        #expect(await container.sync.checkCatalogNow())
        try await eventually { stub.calls.contains("bookCounters(2271)") }

        #expect(stub.calls.filter { $0.hasPrefix("bookCounters") } == ["bookCounters(2271)"])
    }
}

/// Zähler, den mehrere Tasks gleichzeitig hochzählen.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Zwei Verbindungen, Abbruch und Neuaufbau der Datei-Datenbank.
struct DatabaseConcurrencyTests {

    /// Der Abgleich hält die Schreibsperre mehrere Sekunden. Lesen auf dem Main Thread darf
    /// darauf nicht warten und sieht bis zum Commit den alten Stand.
    @Test func lesenWartetNichtAufEineLaufendeSchreibtransaktion() throws {
        let url = temporaryDatabaseURL("reader")
        defer { removeDatabase(url) }
        let db = try AppDatabase(url: url)
        let writing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? db.write { conn in
                try AppDatabase.upsertSyncState(conn, someState)
                writing.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            written.signal()
        }
        writing.wait()

        let read = DispatchSemaphore(value: 0)
        let stateDuringWrite = Locked<SyncState?>(.empty)
        DispatchQueue.global().async {
            stateDuringWrite.value = try? db.syncState()
            read.signal()
        }
        let readFinished = read.wait(timeout: .now() + 2) == .success
        release.signal()
        written.wait()

        #expect(readFinished)
        #expect(stateDuringWrite.value == nil)
        #expect(try db.syncState()?.bookChangeCounter == 122)
    }

    /// Läuft die Zeit im Hintergrund ab, bricht `interrupt` die Schreibtransaktion ab. Nichts
    /// davon bleibt stehen, und der nächste Abgleich lädt neu.
    @Test func abbruchRolltDieSchreibtransaktionZurueck() async throws {
        let url = temporaryDatabaseURL("interrupt")
        defer { removeDatabase(url) }
        let db = try AppDatabase(url: url)

        #expect((Self.interruptedWrite(db) as? SQLiteConnection.Error)?.code == SQLITE_INTERRUPT)
        #expect(try db.syncState() == nil)
        #expect(try db.bookIds().isEmpty)

        // Ohne laufende Transaktion wirkungslos, die nächste läuft normal
        db.interrupt()
        let api = StubAPI()
        _ = try await MasterDataSync(api: api, db: db).sync()
        #expect(api.calls.first == "getBooks(0)")
        #expect(try db.syncState()?.isComplete == true)
    }

    /// Schreibt in einer Transaktion, die `interrupt` nach der ersten Anweisung abbricht, wie der
    /// Expiration-Handler aus dem Main Thread. Liefert den Fehler von `write`.
    private static func interruptedWrite(_ db: AppDatabase) -> Error? {
        let writing = DispatchSemaphore(value: 0)
        let interrupted = DispatchSemaphore(value: 0)
        let result = Locked<Error?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try db.write { conn in
                    try AppDatabase.upsertSyncState(conn, someState)
                    writing.signal()
                    interrupted.wait()
                    try AppDatabase.upsertBooks(conn, [BookEntity(id: "1", shortName: "Heft", title: "Heft", subtitle: nil, year: nil, editor: nil,
                                                                  publisher: nil, publisherNumber: nil, coverUrl: nil)])
                }
            } catch {
                result.value = error
            }
            done.signal()
        }
        writing.wait()
        db.interrupt()
        interrupted.signal()
        done.wait()
        return result.value
    }

    /// App und Share Extension öffnen nach einem Update womöglich gleichzeitig. Hat die eine das
    /// Schema schon neu aufgebaut, während die andere auf die Sperre wartete, baut die zweite
    /// nicht noch einmal auf.
    @Test func neuaufbauPrueftDieVersionInDerTransaktionErneut() throws {
        let url = temporaryDatabaseURL("schema")
        defer { removeDatabase(url) }
        let current: Int
        do {
            let db = try AppDatabase(url: url)
            current = try db.read { try $0.userVersion() }
            try db.write {
                try AppDatabase.upsertSyncState($0, someState)
                try $0.setUserVersion(2)
            }
        }
        // Die "andere" App hält die Schreibsperre und ist mitten im Neuaufbau
        let other = try SQLiteConnection(path: url.path)
        try other.execute("BEGIN IMMEDIATE")

        let opened = Locked<AppDatabase?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            opened.value = try? AppDatabase(url: url)
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        try other.setUserVersion(current)
        try other.execute("COMMIT")
        done.wait()

        let db = try #require(opened.value)
        #expect(try db.read { try $0.userVersion() } == current)
        #expect(try db.syncState()?.bookChangeCounter == 122)
    }
}

/// Wert, den ein anderer Thread setzt.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
