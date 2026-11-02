import BlechWikiCore
import Network
import notify
import os
import SwiftUI
import UIKit

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
        let container = Self.makeContainer(defaults: defaults)
        let db = container.db
        container.sync.beginBackgroundWork = { name in
            // Läuft die Zeit ab, während der Abgleich schreibt, hielte die App beim Anhalten die
            // Sperre auf die Datei in der App Group. Abbrechen, der Abgleich rollt zurück.
            let task = BackgroundTask(name: name) { db.interrupt() }
            return { task.end() }
        }
        _container = State(initialValue: container)
    }

    /// Datenbank beschädigt: Cache verwerfen und neu anlegen, wie Room bei Schemafehlern. Andere
    /// Fehler (z. B. Datei gerade gesperrt) sind kein Grund, den Cache zu löschen, dann nur ein
    /// zweiter Versuch. Scheitert auch der (z. B. Speicher voll), läuft die App mit einer Datenbank
    /// im Speicher und lädt das Verzeichnis bei jedem Start neu, statt beim Start abzustürzen.
    private static func makeContainer(defaults: UserDefaults) -> AppContainer {
        let log = Logger(subsystem: "blechwiki.eggers.media", category: "Start")
        do {
            return try AppContainer(databaseURL: SharedStorage.databaseURL(), defaults: defaults)
        } catch where AppDatabase.isCorruption(error) {
            log.error("Datenbank beschädigt, wird neu angelegt: \(String(describing: error))")
            SharedStorage.removeDatabase()
        } catch {
            log.error("Datenbank lässt sich nicht öffnen, neuer Versuch: \(String(describing: error))")
        }
        do {
            return try AppContainer(databaseURL: SharedStorage.databaseURL(), defaults: defaults)
        } catch {
            log.error("Datenbank lässt sich nicht öffnen, nur im Speicher: \(String(describing: error))")
        }
        // Im Speicher scheitert das Öffnen nur ohne Arbeitsspeicher, dann ist ohnehin nichts zu retten
        return try! AppContainer(databaseURL: nil, defaults: defaults)
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .tint(.brand)
                // Übernahme aus der Share Extension, während die App aktiv bleibt (iPad in Split View
                // neben Nachrichten). Das Aktivieren unten bekommt sie dann nicht mit.
                .task {
                    for await _ in InventoryImportSignal.notifications() {
                        container.changes.notify()
                        container.sync.downloadOwnedBooks()
                    }
                }
        }
        .commands { AppCommands() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            // Die Share Extension kann inzwischen ein Inventar übernommen haben
            container.changes.notify()
            // Der Abgleich entscheidet selbst, ob ein Request nötig ist (höchstens alle 24 h).
            // Danach lädt er neue Inventar-Bücher.
            container.sync.onAppActive(unmetered: network.isUnmetered)
        }
        // Beim Start kommt das Ergebnis des NWPathMonitor oft erst nach dem Aktivieren. Ohne das hier
        // liefe der monatliche Vollabgleich erst beim nächsten Öffnen.
        .onChange(of: network.isUnmetered) { _, unmetered in
            if unmetered && scenePhase == .active { container.sync.onAppActive(unmetered: true) }
        }
    }
}

/// Zeit im Hintergrund für einen Abgleich, der beim Wechsel aus der App noch schreibt.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    /// `expired` läuft, wenn die Zeit abläuft, vor dem Ende.
    init(name: String, expired: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Zeit abgelaufen: iOS verlangt das Ende, sonst wird die App beendet
            MainActor.assumeIsolated {
                expired()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Ob die aktuelle Verbindung WLAN o. Ä. ist. Der monatliche Vollabgleich (2,1 MB) läuft nur dann.
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

enum Route: Hashable, Codable {
    case myBooks
    case egAppendix
    case fundstellen(FundstellenRoute)
    /// Gesangbuch nach Anlass.
    case hymnal
    /// Aktualisierung, Impressum, Datenschutz, Version.
    case appInfo
}

struct FundstellenRoute: Hashable, Codable {
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

    // Codable für `@SceneStorage`. Die Abfrage steht als `cacheKey` drin ("book:5084"), so muss
    // `FundstellenQuery` in BlechWikiCore nichts davon wissen.
    private enum CodingKeys: String, CodingKey { case query, label, detail, initialFilter }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .query)
        guard let query = Self.query(cacheKey: key) else {
            throw DecodingError.dataCorruptedError(forKey: .query, in: container, debugDescription: "Unbekannte Abfrage \(key)")
        }
        self.init(
            query: query,
            label: try container.decode(String.self, forKey: .label),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            initialFilter: try container.decodeIfPresent(String.self, forKey: .initialFilter)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query.cacheKey, forKey: .query)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(initialFilter, forKey: .initialFilter)
    }

    /// Umkehrung von `FundstellenQuery.cacheKey`.
    private static func query(cacheKey: String) -> FundstellenQuery? {
        let parts = cacheKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "title": return Int(parts[1]).map { .byTitle($0) }
        case "eg": return Int(parts[1]).map { .byEgMelody($0) }
        case "book": return .byBook(parts[1])
        case "composer": return .byComposer(parts[1])
        default: return nil
        }
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

/// Suche links, gewählte Seite rechts. Auf schmalen Bildschirmen (iPhone, zugeklapptes iPhone Duo,
/// iPad im schmalen Fenster) klappt `NavigationSplitView` zu einem Stapel zusammen, dann liegt die
/// gewählte Seite über der Suche wie bisher.
struct RootView: View {
    let container: AppContainer
    /// Was links gewählt ist: Treffer, Inventar, Gesangbuch usw. Ist die erste Seite rechts.
    @State private var selection: Route?
    /// Seiten, die rechts von dort aus geöffnet wurden (Buch aus dem Inventar, Komponist usw.)
    @State private var path = NavigationPath()
    @State private var columns = NavigationSplitViewVisibility.all
    /// Auswahl und Seiten über das Beenden der App hinweg, wie die Navigation auf Android.
    @SceneStorage("root.selection") private var savedSelection: Data?
    @SceneStorage("root.path") private var savedPath: Data?
    @State private var restored = false

    /// Neue Auswahl leert die Seiten rechts im selben Schritt und ohne Animation. Erst in
    /// `onChange` geleert, lag auf dem iPad kurz das alte Buch über der neuen Seite und rutschte
    /// dann animiert weg.
    private var selectionBinding: Binding<Route?> {
        Binding {
            selection
        } set: { route in
            if route != selection, !path.isEmpty {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { path = NavigationPath() }
            }
            selection = route
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SearchView(container: container, selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if let selection {
                        destination(selection)
                    } else {
                        ContentUnavailableView {
                            Label("BlechWiki", systemImage: "music.note.list")
                        } description: {
                            Text("Wähle links ein Suchergebnis, das Inventar oder das Gesangbuch.")
                        }
                    }
                }
                // Neue Seite statt der alten mit neuem Inhalt: Die Seiten legen ihr Model beim Erzeugen an
                .id(selection)
                .navigationDestination(for: Route.self, destination: destination)
            }
        }
        // Suche und Seite nebeneinander, auch im Hochformat. Sonst schöbe sich die Suche über die Seite
        // und verschwände nach jeder Auswahl.
        .navigationSplitViewStyle(.balanced)
        .environment(\.openRoute, OpenRouteAction { path.append($0) })
        .onAppear(perform: restore)
        .onChange(of: selection) { _, selection in
            savedSelection = selection.flatMap { try? JSONEncoder().encode($0) }
        }
        .onChange(of: path) { _, path in
            savedPath = path.codable.flatMap { try? JSONEncoder().encode($0) }
        }
        #if DEBUG
        // Für Screenshots im Simulator: BBW_OPEN = "mybooks", "hymnal", "appinfo", "eg:<ixUr>", "book:<BuchId>" oder "title:<Titel>".
        // BBW_LABEL und BBW_DETAIL setzen Überschrift und Unterzeile wie beim Öffnen aus der Suche.
        // Für die Mac-Bilder, deren Einstellungen kein Skript erreicht: BBW_OWNED = Buch-IDs mit Komma
        // (ersetzt das Inventar), BBW_APPENDIX = Code der Landeskirche, BBW_WINDOW = "1440x900"
        .task {
            let env = ProcessInfo.processInfo.environment
            if let owned = env["BBW_OWNED"] {
                container.myBooks.importInventory(owned.split(separator: ",").map(String.init), replace: true)
                container.sync.downloadOwnedBooks()
            }
            if let appendix = env["BBW_APPENDIX"] { container.settings.selectEgAppendix(appendix) }
            #if targetEnvironment(macCatalyst)
            let size = env["BBW_WINDOW"]?.split(separator: "x").compactMap { Double($0) } ?? []
            if size.count == 2, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.sizeRestrictions?.minimumSize = CGSize(width: size[0], height: size[1])
                scene.sizeRestrictions?.maximumSize = CGSize(width: size[0], height: size[1])
            }
            #endif
            guard let open = env["BBW_OPEN"] else { return }
            let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
            let detail = env["BBW_DETAIL"]
            switch (parts.first, parts.count > 1 ? parts[1] : "") {
            case ("mybooks", _): selection = .myBooks
            case ("hymnal", _): selection = .hymnal
            case ("appinfo", _): selection = .appInfo
            case ("eg", let key):
                selection = .fundstellen(FundstellenRoute(query: .byEgMelody(Int(key) ?? 0), label: env["BBW_LABEL"] ?? "EG-Melodie \(key)", detail: detail))
            case ("book", let key): selection = .fundstellen(FundstellenRoute(query: .byBook(key), label: env["BBW_LABEL"] ?? key, detail: detail))
            case ("title", let key): selection = .fundstellen(FundstellenRoute(query: .byTitle(Int(key) ?? 0), label: env["BBW_LABEL"] ?? key, detail: detail))
            default: break
            }
        }
        #endif
    }

    /// Stellt Auswahl und Seiten wieder her, einmal pro Fenster.
    private func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
        // Screenshots im Simulator geben die Seite per Umgebung vor, ein alter Stand störte dabei
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("BBW_") }) { return }
        #endif
        selection = savedSelection.flatMap { try? JSONDecoder().decode(Route.self, from: $0) }
        if selection != nil, let data = savedPath,
           let representation = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data) {
            path = NavigationPath(representation)
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .myBooks:
            MyBooksView(container: container)
        case .egAppendix:
            EgAppendixSelectionView(settings: container.settings)
        case .fundstellen(let route):
            FundstellenView(container: container, route: route)
        case .hymnal:
            HymnalView(container: container)
        case .appInfo:
            AppInfoView(container: container)
        }
    }
}

/// Meldung der Share Extension, dass sie ein Inventar übernommen hat (`ShareImportModel.confirm`).
/// Läuft über das systemweite Darwin Notify Center, das App und Extension gemeinsam erreichen.
enum InventoryImportSignal {
    static let name = SharedStorage.inventoryImportedNotification

    static func notifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { _ in continuation.yield() }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}

/// Menübefehle auf dem Mac. Ein eigenes ⌘F für das Suchfeld gibt es bewusst nicht: UIKit legt
/// „Suchen“ (find:) mit ⌘F selbst ins Menü „Bearbeiten“, SwiftUI kann es nicht ersetzen, und zwei
/// Befehle auf ⌘F wären laut UIKit undefiniert.
struct AppCommands: Commands {
    static let issuesURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/issues")!

    var body: some Commands {
        // Statt „Hilfe ist nicht verfügbar“
        CommandGroup(replacing: .help) {
            Button("Fehler melden") { UIApplication.shared.open(Self.issuesURL) }
        }
    }
}
