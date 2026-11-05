import BlechWikiCore
import Foundation
import Observation

/// Übersicht der Listen: Favoriten oben, dann die eigenen Listen alphabetisch.
@MainActor
@Observable
final class ListsModel {

    private(set) var lists: [ListSummary] = []
    /// Die Datei der Listen ließ sich nicht öffnen oder lesen.
    private(set) var failed = false

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

    /// - Returns: ID der neuen Liste, `nil` bei leerem Namen
    @discardableResult
    func create(name: String) -> String? {
        try? container.lists.createList(name: name)
    }

    func rename(_ list: ListSummary, to name: String) {
        try? container.lists.renameList(id: list.id, name: name)
    }

    func delete(_ list: ListSummary) {
        try? container.lists.deleteList(id: list.id)
    }

    private func reload() {
        do {
            lists = try container.lists.lists()
            failed = false
        } catch {
            failed = true
        }
    }
}

/// Eine Liste mit ihren Einträgen.
@MainActor
@Observable
final class ListDetailModel {

    let listId: String
    /// `nil`, solange nicht gelesen oder wenn es die Liste nicht mehr gibt (`isGone`).
    private(set) var detail: ListDetail?
    private(set) var isGone = false
    private(set) var failed = false

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer, listId: String) {
        self.container = container
        self.listId = listId
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    func observe() async {
        reload()
    }

    /// Ändert die Anzeige sofort. Käme die neue Reihenfolge erst mit der Meldung der Datenbank,
    /// spränge die gezogene Zeile kurz zurück.
    func move(from source: IndexSet, to destination: Int) {
        if let entries = detail?.entries { detail?.entries = ListsRepository.reordered(entries, from: source, to: destination) }
        try? container.lists.move(in: listId, from: source, to: destination)
    }

    func remove(_ entry: ListEntryItem) {
        detail?.entries.removeAll { $0.id == entry.id }
        try? container.lists.remove(entryId: entry.id)
    }

    func setComment(_ entry: ListEntryItem, _ comment: String) {
        try? container.lists.setComment(entryId: entry.id, comment: comment)
    }

    private func reload() {
        do {
            detail = try container.lists.list(id: listId)
            isGone = detail == nil
            failed = false
        } catch {
            failed = true
        }
    }
}
