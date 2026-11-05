import BlechWikiCore
import Foundation
import Observation

/// Zustand des ersten Ladens. Sobald einmal Daten da sind, ist er immer `ready`.
enum InitialLoad { case ready, loading, failed }

/// Was die Startseite (leeres Suchfeld) anzeigt.
struct StartState {
    var offlineStatus = OfflineStatus(owned: 0, available: 0)
    var selectedAppendix: EgAppendix?
    /// Einträge in den Favoriten und Zahl der eigenen Listen.
    var favoriteCount = 0
    var otherListCount = 0
}

@MainActor
@Observable
final class SearchModel {

    var query = "" {
        didSet { if query != oldValue { scheduleSearch(delay: .milliseconds(50)) } }
    }
    private(set) var results = SearchResults()
    /// Eingabe, zu der `results` gehören. Bis die Suche zur aktuellen Eingabe fertig ist, stehen
    /// noch die Treffer der vorigen da. „Keine Treffer“ gilt erst, wenn beide übereinstimmen.
    private(set) var resultsQuery = ""
    private(set) var start = StartState()
    private var hasData = true

    private let container: AppContainer
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var observation: ChangeObservation?

    /// `query`: Suchtext, der beim letzten Beenden im Feld stand.
    init(container: AppContainer, query: String = "") {
        self.container = container
        self.query = query
        #if DEBUG
        // Für Screenshots im Simulator: SIMCTL_CHILD_BBW_QUERY="lob herr" xcrun simctl launch …
        if let query = ProcessInfo.processInfo.environment["BBW_QUERY"] { self.query = query }
        #endif
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    /// Ob `results` zur aktuellen Eingabe gehören.
    var resultsAreCurrent: Bool { resultsQuery == query }

    var initialLoad: InitialLoad {
        if hasData { return .ready }
        switch container.sync.status {
        case .failed, .waiting(afterFailure: true): return .failed
        default: return .loading
        }
    }

    /// Liest Startseite und Treffer beim Erscheinen neu. Änderungen danach kommen über `observation`.
    func observe() async {
        reload()
    }

    func retrySync() {
        container.sync.retryNow()
    }

    private func reload() {
        hasData = (try? container.settings.hasData()) ?? false
        let lists = (try? container.lists.lists()) ?? []
        start = StartState(
            offlineStatus: (try? container.myBooks.offlineStatus()) ?? OfflineStatus(owned: 0, available: 0),
            selectedAppendix: try? container.settings.selectedEgAppendix(),
            favoriteCount: lists.first(where: \.isFavorites)?.entryCount ?? 0,
            otherListCount: lists.filter { !$0.isFavorites }.count
        )
        scheduleSearch(delay: .zero)
    }

    private func scheduleSearch(delay: Duration) {
        searchTask?.cancel()
        let query = self.query
        let repository = container.search
        searchTask = Task {
            // Lokale Suche dauert wenige Millisekunden, die Verzögerung spart nur Arbeit beim schnellen Tippen
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            let results = await Task.detached { (try? repository.search(query)) ?? SearchResults() }.value
            if !Task.isCancelled {
                self.results = results
                self.resultsQuery = query
            }
        }
    }
}
