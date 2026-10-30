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
    private(set) var importPreview: InventoryImport?
    private(set) var catalogCheck = CatalogCheck.notStarted

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        reload()
    }

    func observe() async {
        reload()
        for await _ in container.changes.stream() { reload() }
    }

    func toggle(_ book: BookItem) {
        container.myBooks.setOwned(book.id, owned: !book.isOwned)
        if !book.isOwned { container.sync.downloadOwnedBooks() }
    }

    func openImport() {
        importText = ""
        replaceInventory = false
        catalogCheck = .notStarted
    }

    /// Aus einer ganzen Nachricht nur den Code ins Feld übernehmen.
    func paste(_ text: String) {
        importText = InventoryCode.find(text) ?? text
    }

    func closeImport() {
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
            "Inventar für BlechWiki Offline, \(booksLabel(offline.owned)).\n" +
                "Übernehmen: Nachricht an BlechWiki Offline teilen oder in der App unter Inventar › Inventar-Code einfügen.\n\n\(code)"
        }
        reloadSections()
        reloadImport()
    }

    private func reloadSections() {
        sections = try? container.myBooks.sections(filter: filter)
    }

    private func reloadImport() {
        guard let text = importText else {
            importPreview = nil
            return
        }
        importPreview = try? container.myBooks.inventoryImport(text)
        // Höchstens ein Abgleich pro geöffnetem Dialog
        if case let .ready(_, unknown) = importPreview, unknown > 0, catalogCheck == .notStarted {
            catalogCheck = .running
            Task {
                let ok = await container.sync.checkCatalogNow()
                if catalogCheck == .running { catalogCheck = ok ? .done : .failed }
            }
        }
    }
}
