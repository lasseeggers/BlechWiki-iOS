import BlechWikiCore
import Foundation
import Observation

@MainActor
@Observable
final class HymnalModel {

    /// `nil`, solange die Datenbank noch nicht gelesen ist.
    private(set) var hymnal: Hymnal?
    /// Anlass oben in der Liste, für den Haken im Anlass-Menü.
    private(set) var currentOccasion: String?

    private let container: AppContainer
    // Sichtbare Lieder je Anlass. Nicht beobachtet, sonst zeichnete jede Zeile beim Scrollen alles neu.
    @ObservationIgnored private var visibleSongs: [String: Int] = [:]

    init(container: AppContainer) {
        self.container = container
    }

    /// Liest neu, sobald sich Verzeichnis oder Landeskirche ändern.
    func observe() async {
        reload()
        for await _ in container.changes.stream() { reload() }
    }

    func songAppeared(in occasion: String) {
        visibleSongs[occasion, default: 0] += 1
        updateCurrent()
    }

    func songDisappeared(in occasion: String) {
        visibleSongs[occasion] = max((visibleSongs[occasion] ?? 0) - 1, 0)
        updateCurrent()
    }

    private func updateCurrent() {
        let current = hymnal?.sections.first { (visibleSongs[$0.occasion] ?? 0) > 0 }?.occasion
        if current != nil, current != currentOccasion { currentOccasion = current }
    }

    private func reload() {
        guard let hymnal = try? container.hymnal.hymnal() else { return }
        self.hymnal = hymnal
        if currentOccasion == nil || !hymnal.sections.contains(where: { $0.occasion == currentOccasion }) {
            currentOccasion = hymnal.sections.first?.occasion
        }
    }
}
