import BlechWikiCore
import SwiftUI

struct SearchView: View {

    static let intro: LocalizedStringKey = "Suche nach Liedtitel, EG-Nummer, Buch oder Komponist. Die Suche läuft auf dem \(deviceName) und funktioniert auch ohne Internet."

    let container: AppContainer
    /// Gewählte Zeile. Bleibt markiert, solange ihre Seite rechts daneben steht.
    @Binding var selection: Route?
    /// Einführung erneut zeigen.
    let onShowHelp: () -> Void
    @State private var box = ModelBox<SearchModel>()
    /// Suchtext über das Beenden der App hinweg, wie `rememberSaveable` auf Android.
    @SceneStorage("search.query") private var savedQuery = ""

    init(container: AppContainer, selection: Binding<Route?>, onShowHelp: @escaping () -> Void) {
        self.container = container
        _selection = selection
        self.onShowHelp = onShowHelp
    }

    var body: some View {
        let model = box { SearchModel(container: container, query: savedQuery) }
        content(model)
            // Auf dem Mac stünde der App-Name sonst als Fenstertitel da, solange rechts nichts gewählt ist
            .navigationTitle(UIDevice.current.userInterfaceIdiom == .mac ? "" : "BlechWiki")
            // Kurz halten: Auf schmalen Geräten passen ~25 Zeichen
            .appSearchable(text: Bindable(model).query, prompt: "Lied, EG-Nr. oder Buch")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: model.query) { _, query in savedQuery = query }
            .task { await model.observe() }
    }

    @ViewBuilder
    private func content(_ model: SearchModel) -> some View {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.initialLoad != .ready {
            InitialLoadView(state: model.initialLoad, onRetry: model.retrySync)
        } else if trimmed.isEmpty {
            StartView(state: model.start, selection: $selection, onShowHelp: onShowHelp)
        } else if model.results.isEmpty && model.resultsAreCurrent {
            ContentUnavailableView {
                Label("Keine Treffer für „\(trimmed)“", systemImage: "magnifyingglass")
            } description: {
                Text("Weniger Wörter oder nur Wortanfänge eingeben, z.\u{00A0}B. „lob herr“.")
            }
        } else if model.results.isEmpty {
            // Suche zur neuen Eingabe läuft noch. Leer statt „Keine Treffer“, das sonst beim ersten
            // Buchstaben kurz aufblitzte.
            Color.clear
        } else {
            // Bis neue Treffer da sind, bleiben die vorigen stehen
            ResultList(results: model.results, selection: $selection)
        }
    }
}

private struct ResultList: View {
    let results: SearchResults
    @Binding var selection: Route?

    var body: some View {
        List(selection: $selection) {
            section("EG-Lieder", results.egSongs, detailAsOverline: true)
            section("Titel", results.titles)
            section("Bücher", results.books)
            section("Komponisten", results.composers)
        }
        .modifier(ResultListStyle())
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SearchResult], detailAsOverline: Bool = false) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { result in
                    let route = SuchergebnisseRoute(result)
                    NavigationLink(value: Route.suchergebnisse(route)) {
                        // Abstand wie auf der Startseite, sonst klebt die Markierung am Text
                        ResultRow(result: result, listRef: route.listRef, detailAsOverline: detailAsOverline).macRowPadding(5)
                    }
                    .listEntryMenu(route.listRef)
                }
            } header: {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
            }
        }
    }
}

/// Auf dem Mac derselbe Stil wie die Startseite in dieser Spalte: Die gewählte Zeile ist eingerückt
/// und abgerundet markiert wie in Finder und Mail. Mit `.plain` reichte die Markierung bis an den Rand,
/// und Treffer und Startseite sahen gewählt verschieden aus.
private struct ResultListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.plain)
        #endif
    }
}

private struct ResultRow: View {
    let result: SearchResult
    /// EG-Lieder und Titel, für den Stern bei Favoriten.
    let listRef: ListEntryRef?
    let detailAsOverline: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if detailAsOverline, let detail = result.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(result.label).lineLimit(2)
                if !result.ownedLocations.isEmpty {
                    OwnedLine(locations: result.ownedLocations)
                } else if !detailAsOverline, let detail = result.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if result.isOwnedBook {
                Image(systemName: "bookmark.fill").brandForeground()
                    .accessibilityLabel("Im Inventar")
            }
            if let listRef { FavoriteMark(ref: listRef) }
        }
    }
}

private struct StartView: View {
    let state: StartState
    @Binding var selection: Route?
    let onShowHelp: () -> Void

    /// Auf dem Mac zeichnet die Liste keine Karten. Getrennte Abschnitte ergäben dort nur Lücken,
    /// die je nach Textlänge unterschiedlich groß wirken. Deshalb dort ein gemeinsamer Abschnitt.
    private static let cards = UIDevice.current.userInterfaceIdiom != .mac

    var body: some View {
        List(selection: $selection) {
            if Self.cards {
                Section { intro }
                Section { myBooksLink }
                Section { listsLink }
                Section { hymnalLink }
                Section { appInfoLink }
                Section { helpButton }
            } else {
                // Mit eigenem Abstand oben und unten, sonst sitzt der Auswahlhintergrund dicht am Text,
                // auffällig beim vierzeiligen Hinweis unter „Inventar“. Die Einführung steht auf dem
                // Mac rechts in der leeren Seite, in der schmalen Spalte brach sie mitten im Wort um.
                Section {
                    myBooksLink.macRowPadding(5)
                    listsLink.macRowPadding(5)
                    hymnalLink.macRowPadding(5)
                    appInfoLink.macRowPadding(5)
                    helpButton.macRowPadding(5)
                }
                .listRowSeparator(.hidden)
            }
        }
        // Als Spalte neben der Seite wäre sonst der Seitenleisten-Stil aktiv, ohne Karten
        .listStyle(.insetGrouped)
        // Eine Karte je Eintrag wie in der Android-App. Mit dem Standardabstand zwischen den
        // Abschnitten wirkte die Seite zu luftig.
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.immediately)
    }

    // Intro im Inhalt statt in einem eigenen Großtitel (Toolbar-Platz `.largeTitle`).
    // Der nahm nicht an der Navigations-Animation teil: Er blieb über der nächsten Seite
    // stehen, bis sie ganz offen war, und der Intro-Text sprang beim Zurückkommen um.
    private var intro: some View {
        Text(SearchView.intro).font(.subheadline).foregroundStyle(.secondary)
    }

    private var myBooksLink: some View {
        NavigationLink(value: Route.myBooks) {
            HStack(alignment: .top, spacing: 12) {
                CardIcon(systemImage: state.offlineStatus.owned > 0 ? "bookmark.fill" : "bookmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inventar")
                    Text(inventoryText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var listsLink: some View {
        NavigationLink(value: Route.lists) {
            HStack(alignment: .top, spacing: 12) {
                CardIcon(systemImage: state.favoriteCount > 0 ? "star.fill" : "star")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen")
                    Text(listsText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hymnalLink: some View {
        NavigationLink(value: Route.hymnal) {
            HStack(alignment: .top, spacing: 12) {
                CardIcon(systemImage: "book.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gesangbuch")
                    Text(state.selectedAppendix.map { "Alle EG-Lieder nach Anlass, mit dem Anhang \($0.name)" }
                        ?? "Alle EG-Lieder des Stammteils nach Anlass, z.\u{00A0}B. Advent oder Abend")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appInfoLink: some View {
        NavigationLink(value: Route.appInfo) {
            HStack(alignment: .top, spacing: 12) {
                CardIcon(systemImage: "gearshape.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Einstellungen")
                    Text("Landeskirche, Aktualisierung, Impressum und Datenschutz")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Button statt Link: Öffnet die Einführung über der ganzen App, keine Seite. Als Link mit
    /// eigener Route schob die Liste auf dem iPhone trotzdem die leere rechte Spalte nach vorn, nach
    /// der Einführung stand man dort statt auf der Startseite. Der Pfeil ist dem der Links
    /// nachgebaut, Farbe, Stärke und Abstand nach Screenshot abgeglichen.
    private var helpButton: some View {
        Button(action: onShowHelp) {
            HStack(alignment: .top, spacing: 12) {
                CardIcon(systemImage: "questionmark.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hilfe")
                    Text("Einführung in Suche, Inventar und Gesangbuch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 5.0 / 3)
                    .frame(maxHeight: .infinity)
            }
            .contentShape(Rectangle())
        }
        // Grau wie die Unterzeilen der anderen Karten, sonst färbt der Button Text und Pfeil in der Akzentfarbe
        .tint(Color.primary)
    }

    private var listsText: String {
        if state.favoriteCount == 0 && state.otherListCount == 0 {
            return "Favoriten und eigene Listen, z.\u{00A0}B. für ein Konzert"
        }
        let others = switch state.otherListCount {
        case 0: "keine weiteren Listen"
        case 1: "1 weitere Liste"
        case let n: "\(n) weitere Listen"
        }
        return "Favoriten: \(state.favoriteCount) · \(others)"
    }

    private var inventoryText: String {
        let offline = state.offlineStatus
        if offline.owned == 0 {
            return "Trag die Bücher aus dem Notenschrank ein oder übernimm den Inventar-Code aus dem Chor. Dann zeigt die Suche sofort, ob ein Stück im Inventar ist, auch ohne Internet."
        }
        if offline.available < offline.owned {
            return "\(booksLabel(offline.owned)) · \(offline.available) offline verfügbar, Rest wird geladen"
        }
        return "\(booksLabel(offline.owned)) · alle offline verfügbar"
    }
}

/// Symbol vor jeder Karte der Startseite. Lesezeichen gefüllt, sobald Bücher eingetragen sind, Stern
/// gefüllt, sobald es Favoriten gibt. Die übrigen Symbole zeigen keinen Stand.
private struct CardIcon: View {
    let systemImage: String
    /// Wächst mit der Schriftgröße, sonst ragte das Symbol bei großer Schrift in den Text
    @ScaledMetric private var width: CGFloat = 24

    var body: some View {
        Image(systemName: systemImage)
            .brandForeground()
            // Links bündig mit den Texten der anderen Karten, zentriert rückte das schmale Symbol ein
            .frame(width: width, alignment: .leading)
            // Der Text daneben nennt den Stand schon
            .accessibilityHidden(true)
    }
}

private struct InitialLoadView: View {
    let state: InitialLoad
    let onRetry: () -> Void

    var body: some View {
        if state == .failed {
            ContentUnavailableView {
                Label("Nicht geladen", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Das Liederverzeichnis konnte nicht geladen werden. Entweder fehlt die Internetverbindung, oder blechwiki.de ist gerade nicht erreichbar.")
            } actions: {
                Button("Erneut versuchen", action: onRetry).buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 16) {
                Text("Liederverzeichnis wird geladen …").font(.headline)
                ProgressView().controlSize(.large)
                Text("Einmalig ca. 1 MB. Danach funktioniert die Suche auch ohne Internet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

