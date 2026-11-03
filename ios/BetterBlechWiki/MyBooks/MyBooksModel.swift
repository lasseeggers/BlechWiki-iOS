import BlechWikiCore
import Foundation
import Observation

/// Abgleich mit BlechWiki, wenn ein Inventar-Code Bücher enthält, die das Verzeichnis nicht kennt.
enum CatalogCheck { case notStarted, running, done, failed }

@MainActor
@Observable
final class MyBooksModel {

    var filter = "" {
        didSet { if filter != oldValue { reloadSections() } }
    }
    var onlySelected = false

    private(set) var sections: BookSections?
    /// Die Bücherliste ließ sich nicht aus der Datenbank lesen.
    private(set) var sectionsFailed = false
    private(set) var offline = OfflineStatus(owned: 0, available: 0)
    private(set) var selectedAppendix: EgAppendix?
    /// Nachrichtentext zum Teilen, `nil` bei leerem Inventar.
    private(set) var shareMessage: String?

    /// Text im Import-Dialog. `nil`: Dialog geschlossen.
    var importText: String? {
        didSet { if importText != oldValue { reloadImport() } }
    }
    /// Import ersetzt das bisherige Inventar, statt es zu ergänzen.
    var replaceInventory = false
    private var decodedImport: InventoryImport?
    private(set) var catalogCheck = CatalogCheck.notStarted
    /// Zählt geöffnete Dialoge. Ein Abgleich aus einem schon geschlossenen Dialog schreibt sein
    /// Ergebnis nicht in den neuen.
    @ObservationIgnored private var importGeneration = 0

    /// Auswertung des Codes für den Dialog. Ist nach dem Abgleich (oder ohne Netz) weiterhin kein
    /// einziges Buch des Codes bekannt, ist der Code beschädigt, meist ein Tippfehler im Kopf. Dann
    /// nicht „BlechWiki ist gerade nicht erreichbar“ melden, sondern wie bei einem ungültigen Code.
    var importPreview: InventoryImport? {
        if case let .ready(books, unknown) = decodedImport, books.isEmpty, unknown > 0,
           catalogCheck == .done || catalogCheck == .failed {
            return .invalid
        }
        return decodedImport
    }

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    /// Liest beim Erscheinen neu. Änderungen danach kommen über `observation`.
    func observe() async {
        reload()
    }

    func toggle(_ book: BookItem) {
        container.myBooks.setOwned(book.id, owned: !book.isOwned)
        if !book.isOwned { container.sync.downloadOwnedBooks() }
    }

    func openImport() {
        importGeneration += 1
        catalogCheck = .notStarted
        replaceInventory = false
        importText = ""
    }

    /// Aus einer ganzen Nachricht nur den Code ins Feld übernehmen.
    func paste(_ text: String) {
        importText = InventoryCode.find(text) ?? text
    }

    func closeImport() {
        importGeneration += 1
        importText = nil
        catalogCheck = .notStarted
    }

    func confirmImport() {
        guard case let .ready(books, _) = importPreview else { return }
        container.myBooks.importInventory(books.map(\.id), replace: replaceInventory)
        container.sync.downloadOwnedBooks()
        onlySelected = true
        closeImport()
    }

    private func reload() {
        offline = (try? container.myBooks.offlineStatus()) ?? OfflineStatus(owned: 0, available: 0)
        selectedAppendix = try? container.settings.selectedEgAppendix()
        shareMessage = (try? container.myBooks.inventoryCode()).flatMap { $0 }.map { code in
            // „Inventar übernehmen“ heißt das Teilen-Ziel auf beiden Plattformen
            "Inventar für BlechWiki, \(booksLabel(offline.owned)).\n" +
                "Übernehmen: Diese Nachricht teilen und als Ziel „Inventar übernehmen“ wählen, oder in BlechWiki im Inventar „Inventar-Code einfügen“ wählen.\n\n\(code)"
        }
        reloadSections()
        reloadImport()
    }

    private func reloadSections() {
        do {
            sections = try container.myBooks.sections(filter: filter)
            sectionsFailed = false
        } catch {
            sectionsFailed = true
        }
    }

    private func reloadImport() {
        guard let text = importText else {
            decodedImport = nil
            return
        }
        decodedImport = try? container.myBooks.inventoryImport(text)
        // Höchstens ein Abgleich pro geöffnetem Dialog
        if case let .ready(_, unknown) = decodedImport, unknown > 0, catalogCheck == .notStarted {
            catalogCheck = .running
            let generation = importGeneration
            Task {
                let ok = await container.sync.checkCatalogNow()
                guard generation == importGeneration, catalogCheck == .running else { return }
                catalogCheck = ok ? .done : .failed
            }
        }
    }
}
