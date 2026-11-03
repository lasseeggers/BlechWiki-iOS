import BlechWikiCore
import Foundation
import Observation

@MainActor
@Observable
final class AppInfoModel {

    /// Letzter Abgleich mit blechwiki.de, `nil` wenn noch nie.
    private(set) var lastCheckedAt: Date?

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    private func reload() {
        lastCheckedAt = try? container.settings.lastCheckedAt()
    }
}
