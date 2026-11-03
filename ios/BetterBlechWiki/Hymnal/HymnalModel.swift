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
    /// Nach einem Sprung über das Menü bleibt der gewählte Anlass kurz fest. Sonst gewänne der Anlass
    /// davor, dessen letzte Lieder nach dem Sprung noch unter der Toolbar liegen.
    @ObservationIgnored private var jumpedAt: Date?
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        // Liest neu, sobald sich Verzeichnis oder Landeskirche ändern
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
    }

    /// Liest beim Erscheinen. Änderungen danach kommen über `observation`.
    func observe() async {
        reload()
    }

    func songAppeared(in occasion: String) {
        visibleSongs[occasion, default: 0] += 1
        updateCurrent()
    }

    func songDisappeared(in occasion: String) {
        visibleSongs[occasion] = max((visibleSongs[occasion] ?? 0) - 1, 0)
        updateCurrent()
    }

    /// Sprung über das Anlass-Menü.
    func jumped(to occasion: String) {
        currentOccasion = occasion
        jumpedAt = .now
    }

    private func updateCurrent() {
        // Die Zeilen, die der Sprung ein- und ausblendet, melden sich kurz danach
        if let jumpedAt, Date.now.timeIntervalSince(jumpedAt) < 1 { return }
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
