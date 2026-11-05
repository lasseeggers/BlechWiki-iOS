import BlechWikiCore
import Foundation
import Observation

@MainActor
@Observable
final class AppInfoModel {

    /// Letzter Abgleich mit blechwiki.de, `nil` wenn noch nie.
    private(set) var lastCheckedAt: Date?
    private(set) var selectedAppendix: EgAppendix?

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    /// Zustand des Abgleichs, für „Alle Daten neu laden“.
    var syncStatus: SyncStatus { container.sync.status }

    func reloadAll() {
        container.sync.reloadAll()
    }

    private func reload() {
        lastCheckedAt = try? container.settings.lastCheckedAt()
        selectedAppendix = try? container.settings.selectedEgAppendix()
    }
}
