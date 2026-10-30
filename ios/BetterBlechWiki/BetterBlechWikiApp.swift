import BlechWikiCore
import Network
import SwiftUI

@main
struct BetterBlechWikiApp: App {

    @State private var container: AppContainer
    @State private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Cover sind unveränderlich. AsyncImage nutzt den gemeinsamen URLCache.
        URLCache.shared = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        SharedStorage.migrateIfNeeded()
        let defaults = SharedStorage.defaults()
        do {
            _container = State(initialValue: try AppContainer(databaseURL: SharedStorage.databaseURL(), defaults: defaults))
        } catch {
            // Datenbank defekt oder Speicher voll: Cache verwerfen und neu anlegen, wie Room bei Schemafehlern
            try? FileManager.default.removeItem(at: try! SharedStorage.databaseURL())
            _container = State(initialValue: try! AppContainer(databaseURL: SharedStorage.databaseURL(), defaults: defaults))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .tint(.brand)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            // Die Share Extension kann inzwischen ein Inventar übernommen haben
            container.changes.notify()
            // Der Abgleich entscheidet selbst, ob ein Request nötig ist (höchstens alle 24 h).
            // Danach lädt er neue Inventar-Bücher.
            container.sync.onAppActive(unmetered: network.isUnmetered)
        }
    }
}

/// Ob die aktuelle Verbindung WLAN o. Ä. ist. Der monatliche Vollabgleich (2,3 MB) läuft nur dann.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isUnmetered = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.isUnmetered = unmetered }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}

enum Route: Hashable {
    case myBooks
    case egAppendix
    case fundstellen(FundstellenRoute)
    /// Gesangbuch nach Anlass.
    case hymnal
}

struct FundstellenRoute: Hashable {
    var query: FundstellenQuery
    var label: String
    var detail: String?
    /// Buchansicht: Suche im Buch vorbelegen.
    var initialFilter: String?

    init(query: FundstellenQuery, label: String, detail: String? = nil, initialFilter: String? = nil) {
        self.query = query
        self.label = label
        self.detail = detail
        self.initialFilter = initialFilter
    }

    init(_ result: SearchResult) {
        self.init(query: result.query, label: result.label, detail: result.detail)
    }

    var isBook: Bool {
        if case .byBook = query { true } else { false }
    }

    var isEgMelody: Bool {
        if case .byEgMelody = query { true } else { false }
    }

    var bookId: String? {
        if case .byBook(let id) = query { id } else { nil }
    }
}

struct RootView: View {
    let container: AppContainer
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(container: container)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .myBooks:
                        MyBooksView(container: container)
                    case .egAppendix:
                        EgAppendixSelectionView(settings: container.settings)
                    case .fundstellen(let route):
                        FundstellenView(container: container, route: route)
                    case .hymnal:
                        HymnalView(container: container)
                    }
                }
        }
        .environment(\.openRoute, OpenRouteAction { path.append($0) })
        #if DEBUG
        // Für Screenshots im Simulator: BBW_OPEN = "mybooks", "hymnal", "eg:<ixUr>", "book:<BuchId>" oder "title:<Titel>".
        // BBW_LABEL und BBW_DETAIL setzen Überschrift und Unterzeile wie beim Öffnen aus der Suche
        .task {
            let env = ProcessInfo.processInfo.environment
            guard let open = env["BBW_OPEN"] else { return }
            let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
            let detail = env["BBW_DETAIL"]
            switch (parts.first, parts.count > 1 ? parts[1] : "") {
            case ("mybooks", _): path.append(Route.myBooks)
            case ("hymnal", _): path.append(Route.hymnal)
            case ("eg", let key):
                path.append(Route.fundstellen(FundstellenRoute(query: .byEgMelody(Int(key) ?? 0), label: env["BBW_LABEL"] ?? "EG-Melodie \(key)", detail: detail)))
            case ("book", let key): path.append(Route.fundstellen(FundstellenRoute(query: .byBook(key), label: env["BBW_LABEL"] ?? key, detail: detail)))
            case ("title", let key): path.append(Route.fundstellen(FundstellenRoute(query: .byTitle(key), label: env["BBW_LABEL"] ?? key, detail: detail)))
            default: break
            }
        }
        #endif
    }
}
