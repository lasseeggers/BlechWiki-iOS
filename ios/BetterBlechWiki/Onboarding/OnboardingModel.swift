import BlechWikiCore
import Foundation
import Observation

/// Einführung beim ersten Start. Während der Nutzer die Seiten liest, lädt `SyncCoordinator` das
/// Verzeichnis im Hintergrund, angestoßen wie immer beim Aktivieren der App. Bis zur Bücherauswahl
/// am Ende ist es meist da.
@MainActor
@Observable
final class OnboardingModel {

    private(set) var appendices: [EgAppendix] = []
    private(set) var selectedAppendix: EgAppendix?
    /// Vorschläge und Choralbücher, `nil` solange das Verzeichnis fehlt.
    private(set) var sections: BookSections?
    private(set) var offline = OfflineStatus(owned: 0, available: 0)
    private var hasData = false

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    /// Stand des ersten Ladens, wie auf der Startseite.
    var dataState: InitialLoad {
        if hasData { return .ready }
        switch container.sync.status {
        case .failed, .waiting(afterFailure: true): return .failed
        default: return .loading
        }
    }

    /// Liest beim Erscheinen neu. Änderungen danach kommen über `observation`.
    func observe() async {
        reload()
    }

    func selectAppendix(_ code: String) {
        container.settings.selectEgAppendix(code)
    }

    func toggle(_ book: BookItem) {
        container.myBooks.setOwned(book.id, owned: !book.isOwned)
        if !book.isOwned { container.sync.downloadOwnedBooks() }
    }

    func retry() {
        container.sync.retryNow()
    }

    func finish() {
        container.settings.finishOnboarding()
    }

    private func reload() {
        hasData = (try? container.settings.hasData()) ?? false
        appendices = (try? container.settings.egAppendices()) ?? []
        selectedAppendix = try? container.settings.selectedEgAppendix()
        offline = (try? container.myBooks.offlineStatus()) ?? OfflineStatus(owned: 0, available: 0)
        sections = hasData ? try? container.myBooks.sections(filter: "") : nil
    }
}
