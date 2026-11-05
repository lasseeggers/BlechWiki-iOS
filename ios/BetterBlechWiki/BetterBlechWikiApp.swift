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
    ///
    /// Die Listen liegen in einer eigenen Datei und werden in keinem dieser Fälle gelöscht. Lässt
    /// sie sich nicht öffnen, zeigt nur die Listenseite einen Fehler.
    private static func makeContainer(defaults: UserDefaults) -> AppContainer {
        let log = Logger(subsystem: "blechwiki.eggers.media", category: "Start")
        func make(_ databaseURL: () throws -> URL?) throws -> AppContainer {
            let container = try AppContainer(
                databaseURL: databaseURL(),
                listsDatabaseURL: { try SharedStorage.listsDatabaseURL() },
                defaults: defaults
            )
            if let error = container.lists.openError {
                log.error("Listen lassen sich nicht öffnen: \(String(describing: error))")
            }
            return container
        }
        do {
            return try make { try SharedStorage.databaseURL() }
        } catch where AppDatabase.isCorruption(error) {
            log.error("Datenbank beschädigt, wird neu angelegt: \(String(describing: error))")
            SharedStorage.removeDatabase()
        } catch {
            log.error("Datenbank lässt sich nicht öffnen, neuer Versuch: \(String(describing: error))")
        }
        do {
            return try make { try SharedStorage.databaseURL() }
        } catch {
            log.error("Datenbank lässt sich nicht öffnen, nur im Speicher: \(String(describing: error))")
        }
        // Im Speicher scheitert das Öffnen nur ohne Arbeitsspeicher, dann ist ohnehin nichts zu retten
        return try! make { nil }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(container: container)
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

        #if targetEnvironment(macCatalyst)
        WindowGroup("BlechWiki-Einstellungen", id: SettingsWindow.id, for: String.self) { _ in
            SettingsWindow(settings: container.settings)
                .tint(.brand)
        }
        #endif
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
    case suchergebnisse(SuchergebnisseRoute)
    /// Gesangbuch nach Anlass.
    case hymnal
    /// Übersicht der Listen und eine einzelne Liste.
    case lists
    case list(id: String)
    /// Einstellungen: Landeskirche, Aktualisierung, Impressum, Datenschutz, Version.
    case appInfo

    // `suchergebnisse` hieß früher `fundstellen`. Der alte Schlüssel bleibt, damit `@SceneStorage`
    // die zuletzt offene Ansicht nach einem Update wiederherstellt.
    private enum CodingKeys: String, CodingKey {
        case myBooks, egAppendix, hymnal, appInfo, lists, list
        case suchergebnisse = "fundstellen"
    }
}

struct SuchergebnisseRoute: Hashable, Codable {
    var query: FundstellenQuery
    var label: String
    var detail: String?
    /// Buchansicht: Suche im Buch vorbelegen.
    var initialFilter: String?
    /// EG-Lied: `ix` des Lieds, für Favoriten und Listen. `query` nennt nur die Melodie.
    var egIx: Int?

    init(query: FundstellenQuery, label: String, detail: String? = nil, initialFilter: String? = nil, egIx: Int? = nil) {
        self.query = query
        self.label = label
        self.detail = detail
        self.initialFilter = initialFilter
        self.egIx = egIx
    }

    init(_ result: SearchResult) {
        self.init(query: result.query, label: result.label, detail: result.detail, egIx: result.egIx)
    }

    // Codable für `@SceneStorage`. Die Abfrage steht als `cacheKey` drin ("book:5084"), so muss
    // `FundstellenQuery` in BlechWikiCore nichts davon wissen.
    private enum CodingKeys: String, CodingKey { case query, label, detail, initialFilter, egIx }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .query)
        let label = try container.decode(String.self, forKey: .label)
        guard let query = Self.query(cacheKey: key, label: label) else {
            throw DecodingError.dataCorruptedError(forKey: .query, in: container, debugDescription: "Unbekannte Abfrage \(key)")
        }
        self.init(
            query: query,
            label: label,
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            initialFilter: try container.decodeIfPresent(String.self, forKey: .initialFilter),
            egIx: try container.decodeIfPresent(Int.self, forKey: .egIx)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query.cacheKey, forKey: .query)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(initialFilter, forKey: .initialFilter)
        try container.encodeIfPresent(egIx, forKey: .egIx)
    }

    /// Umkehrung von `FundstellenQuery.cacheKey`. Titel über `label`: Bis 1.3 stand dort die
    /// Nummer des Titels, die es nicht mehr gibt.
    private static func query(cacheKey: String, label: String) -> FundstellenQuery? {
        let parts = cacheKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "title": return .title(label)
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

    /// Eintrag für Favoriten und Listen. Nur für Titel und EG-Lieder, nicht für Bücher und Komponisten.
    /// Fehlt `egIx` (Seite aus einer älteren Version wiederhergestellt), das Lied mit `ix` = Melodie.
    var listRef: ListEntryRef? {
        switch query {
        case .byTitle: .title(label)
        case .byEgMelody(let ixUr): .eg(ix: egIx ?? ixUr, ixUr: ixUr, title: label, label: detail)
        case .byBook, .byComposer: nil
        }
    }
}

/// Beim ersten Start die Einführung, danach die App.
struct AppRoot: View {
    let container: AppContainer
    /// Einmal beim Öffnen des Fensters entschieden. Während der Einführung wählt der Nutzer eine
    /// Landeskirche, sie verschwände sonst mitten im Durchlauf.
    @State private var onboarding: Bool

    init(container: AppContainer) {
        self.container = container
        _onboarding = State(initialValue: Self.showOnboarding(container))
    }

    var body: some View {
        if onboarding {
            OnboardingView(container: container, page: Self.firstPage) {
                withAnimation { onboarding = false }
            }
            .transition(.opacity)
        } else {
            RootView(container: container)
        }
    }

    private static func showOnboarding(_ container: AppContainer) -> Bool {
        #if DEBUG
        // Für Screenshots und Tests: BBW_ONBOARDING zeigt die Einführung immer, der Wert ist die erste
        // Seite (0 bis 5). Andere BBW_*-Parameter
        // öffnen eine Seite der App, die Einführung stünde davor.
        let env = ProcessInfo.processInfo.environment
        if env["BBW_ONBOARDING"] != nil { return true }
        if env.keys.contains(where: { $0.hasPrefix("BBW_") }) { return false }
        #endif
        return container.settings.needsOnboarding()
    }

    private static var firstPage: Int {
        #if DEBUG
        Int(ProcessInfo.processInfo.environment["BBW_ONBOARDING"] ?? "") ?? 0
        #else
        0
        #endif
    }
}

/// Suche links, gewählte Seite rechts. Auf schmalen Bildschirmen (iPhone, zugeklapptes iPhone Duo,
/// iPad im schmalen Fenster) klappt `NavigationSplitView` zu einem Stapel zusammen, dann liegt die
/// gewählte Seite über der Suche wie bisher.
struct RootView: View {
    let container: AppContainer
    /// Stern und „Zu Liste hinzufügen …“ für alle Seiten des Fensters.
    @State private var listActionsBox = ModelBox<ListActions>()
    /// Was links gewählt ist: Treffer, Inventar, Gesangbuch usw. Ist die erste Seite rechts.
    @State private var selection: Route?
    /// Seiten, die rechts von dort aus geöffnet wurden (Buch aus dem Inventar, Komponist usw.)
    @State private var path = NavigationPath()
    @State private var columns = NavigationSplitViewVisibility.all
    /// Einführung über „Hilfe“ auf der Startseite oder im Menü „Hilfe“.
    @State private var showHelp = false
    /// Auswahl und Seiten über das Beenden der App hinweg, wie die Navigation auf Android.
    @SceneStorage("root.selection") private var savedSelection: Data?
    @SceneStorage("root.path") private var savedPath: Data?
    @State private var restored = false
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif

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
        let listActions = listActionsBox { ListActions(container: container) }
        NavigationSplitView(columnVisibility: $columns) {
            SearchView(container: container, selection: selectionBinding) { showHelp = true }
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
                            #if targetEnvironment(macCatalyst)
                            // Auf dem Mac steht die Einführung hier statt oben in der Seitenleiste,
                            // wo sie in der schmalen Spalte umbrach
                            Text(SearchView.intro)
                            #endif
                            Text("Wähle links ein Suchergebnis, das Inventar, die Listen oder das Gesangbuch.")
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
        .environment(listActions)
        .listActionsPresentation(listActions, container: container)
        .fullScreenCover(isPresented: $showHelp) {
            OnboardingView(container: container, onClose: { showHelp = false }) { showHelp = false }
        }
        .focusedSceneValue(\.windowNavigation, WindowNavigation(
            select: { selectionBinding.wrappedValue = $0 },
            back: path.isEmpty ? nil : { path.removeLast() },
            sidebarVisible: columns != .detailOnly,
            toggleSidebar: { columns = columns == .detailOnly ? .all : .detailOnly },
            showHelp: { showHelp = true }
        ))
        .onAppear(perform: restore)
        .onChange(of: selection) { _, selection in
            savedSelection = selection.flatMap { try? JSONEncoder().encode($0) }
        }
        .onChange(of: path) { _, path in
            savedPath = path.codable.flatMap { try? JSONEncoder().encode($0) }
        }
        #if DEBUG
        // Für Screenshots im Simulator: BBW_OPEN = "mybooks", "hymnal", "appinfo", "lists", "list:<ListenId>" (Favoriten:
        // "list:favoriten"), "eg:<ixUr>", "book:<BuchId>" oder "title:<Titel>".
        // BBW_LABEL und BBW_DETAIL setzen Überschrift und Unterzeile wie beim Öffnen aus der Suche.
        // Für die Mac-Bilder, deren Einstellungen kein Skript erreicht: BBW_OWNED = Buch-IDs mit Komma
        // (ersetzt das Inventar), BBW_APPENDIX = Code der Landeskirche, BBW_WINDOW = "1440x900",
        // BBW_SETTINGS = 1 öffnet zusätzlich das Einstellungsfenster
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
            if env["BBW_SETTINGS"] != nil { openWindow(id: SettingsWindow.id, value: SettingsWindow.id) }
            #endif
            guard let open = env["BBW_OPEN"] else { return }
            let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
            let detail = env["BBW_DETAIL"]
            switch (parts.first, parts.count > 1 ? parts[1] : "") {
            case ("mybooks", _): selection = .myBooks
            case ("hymnal", _): selection = .hymnal
            case ("appinfo", _): selection = .appInfo
            case ("lists", _): selection = .lists
            case ("list", let key): selection = .list(id: key)
            case ("eg", let key):
                selection = .suchergebnisse(SuchergebnisseRoute(query: .byEgMelody(Int(key) ?? 0), label: env["BBW_LABEL"] ?? "EG-Melodie \(key)", detail: detail))
            case ("book", let key): selection = .suchergebnisse(SuchergebnisseRoute(query: .byBook(key), label: env["BBW_LABEL"] ?? key, detail: detail))
            case ("title", let key): selection = .suchergebnisse(SuchergebnisseRoute(query: .title(env["BBW_LABEL"] ?? key), label: env["BBW_LABEL"] ?? key, detail: detail))
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
        case .suchergebnisse(let route):
            SuchergebnisseView(container: container, route: route)
        case .hymnal:
            HymnalView(container: container)
        case .appInfo:
            AppInfoView(container: container)
        case .lists:
            ListsView(container: container)
        case .list(let id):
            ListDetailView(container: container, listId: id)
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

