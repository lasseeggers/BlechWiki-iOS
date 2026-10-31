import BlechWikiCore
import Foundation
import Observation

/// Zustand des ersten Ladens. Sobald einmal Daten da sind, ist er immer `ready`.
enum InitialLoad { case ready, loading, failed }

/// Was die Startseite (leeres Suchfeld) anzeigt.
struct StartState {
    var offlineStatus = OfflineStatus(owned: 0, available: 0)
    var selectedAppendix: EgAppendix?
}

@MainActor
@Observable
final class SearchModel {

    var query = "" {
        didSet { if query != oldValue { scheduleSearch(delay: .milliseconds(50)) } }
    }
    private(set) var results = SearchResults()
    private(set) var start = StartState()
    private var hasData = true

    private let container: AppContainer
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        #if DEBUG
        // Für Screenshots im Simulator: SIMCTL_CHILD_BBW_QUERY="lob herr" xcrun simctl launch …
        if let query = ProcessInfo.processInfo.environment["BBW_QUERY"] { self.query = query }
        #endif
        reload()
    }

    var initialLoad: InitialLoad {
        if hasData { return .ready }
        switch container.sync.status {
        case .failed, .waiting(afterFailure: true): return .failed
        default: return .loading
        }
    }

    /// Liest Startseite und Treffer neu, sobald sich Daten oder Einstellungen ändern.
    func observe() async {
        reload()
        for await _ in container.changes.stream() {
            reload()
        }
    }

    func retrySync() {
        container.sync.retryNow()
    }

    private func reload() {
        hasData = (try? container.settings.hasData()) ?? false
        start = StartState(
            offlineStatus: (try? container.myBooks.offlineStatus()) ?? OfflineStatus(owned: 0, available: 0),
            selectedAppendix: try? container.settings.selectedEgAppendix()
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
            if !Task.isCancelled { self.results = results }
        }
    }
}
