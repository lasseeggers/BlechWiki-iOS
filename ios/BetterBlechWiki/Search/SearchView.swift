import BlechWikiCore
import SwiftUI

struct SearchView: View {

    let container: AppContainer
    /// Gewählte Zeile. Bleibt markiert, solange ihre Seite rechts daneben steht.
    @Binding var selection: Route?
    @State private var box = ModelBox<SearchModel>()
    /// Suchtext über das Beenden der App hinweg, wie `rememberSaveable` auf Android.
    @SceneStorage("search.query") private var savedQuery = ""

    init(container: AppContainer, selection: Binding<Route?>) {
        self.container = container
        _selection = selection
    }

    var body: some View {
        let model = box { SearchModel(container: container, query: savedQuery) }
        content(model)
            .navigationTitle("BlechWiki")
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
            StartView(state: model.start, selection: $selection)
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
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SearchResult], detailAsOverline: Bool = false) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { result in
                    NavigationLink(value: Route.fundstellen(FundstellenRoute(result))) {
                        ResultRow(result: result, detailAsOverline: detailAsOverline)
                    }
                }
            } header: {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
            }
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
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
            if result.isOwnedBook {
                Spacer()
                Image(systemName: "bookmark.fill").brandForeground()
                    .accessibilityLabel("Im Inventar")
            }
        }
    }
}

/// "Im Inventar: Bläserheft 2022 Bayern Nr. 43, 44 und 2 weitere Bücher"
private struct OwnedLine: View {
    let locations: [OwnedLocation]

    var body: some View {
        // Mehrere Sätze im selben Heft (Vorspiel, Satz, Zwischenspiel) sind ein Buch, nicht mehrere Treffer
        let byBook = groupedInOrder(locations, by: \.bookTitle)
        let first = byBook[0]
        var seen = Set<String>()
        let numbers = first.map(\.number).filter { seen.insert($0).inserted }.joined(separator: ", ")
        let more = switch byBook.count - 1 {
        case 0: ""
        case 1: " und 1 weiteres Buch"
        case let n: " und \(n) weitere Bücher"
        }
        return Label {
            Text("Im Inventar: \(first[0].bookTitle) Nr. \(numbers)\(more)").lineLimit(2)
        } icon: {
            Image(systemName: "bookmark.fill").imageScale(.small)
        }
        .font(.subheadline)
        .brandForeground()
        .labelStyle(.titleAndIcon)
    }
}

private struct StartView: View {
    let state: StartState
    @Binding var selection: Route?

    /// Auf dem Mac zeichnet die Liste keine Karten. Getrennte Abschnitte ergäben dort nur Lücken,
    /// die je nach Textlänge unterschiedlich groß wirken. Deshalb dort ein gemeinsamer Abschnitt.
    private static let cards = UIDevice.current.userInterfaceIdiom != .mac

    var body: some View {
        List(selection: $selection) {
            if Self.cards {
                Section { intro }
                Section { myBooksLink }
                Section { hymnalLink }
                Section { appendixLink }
                Section { appInfoLink }
            } else {
                // Mit eigenem Abstand oben und unten, sonst sitzt der Auswahlhintergrund dicht am Text,
                // auffällig beim vierzeiligen Hinweis unter „Inventar“
                Section {
                    intro.macRowPadding(5)
                    myBooksLink.macRowPadding(5)
                    hymnalLink.macRowPadding(5)
                    appendixLink.macRowPadding(5)
                    appInfoLink.macRowPadding(5)
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

    static let intro: LocalizedStringKey = "Suche nach Liedtitel, EG-Nummer, Buch oder Komponist. Die Suche läuft auf dem \(deviceName) und funktioniert auch ohne Internet."

    // Intro im Inhalt statt in einem eigenen Großtitel (Toolbar-Platz `.largeTitle`).
    // Der nahm nicht an der Navigations-Animation teil: Er blieb über der nächsten Seite
    // stehen, bis sie ganz offen war, und der Intro-Text sprang beim Zurückkommen um.
    private var intro: some View {
        Text(Self.intro).font(.subheadline).foregroundStyle(.secondary)
    }

    private var myBooksLink: some View {
        NavigationLink(value: Route.myBooks) {
            HStack(alignment: .top, spacing: 12) {
                InventoryIcon(filled: state.offlineStatus.owned > 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inventar")
                    Text(inventoryText).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Kein Symbol wie beim Inventar: Dort zeigt es den Stand (gefüllt = Bücher eingetragen),
    // hier wäre es nur Schmuck. Gleich wie in der Android-App.
    private var hymnalLink: some View {
        NavigationLink(value: Route.hymnal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gesangbuch")
                Text(state.selectedAppendix.map { "Alle EG-Lieder nach Anlass, mit dem Anhang \($0.name)" }
                    ?? "Alle EG-Lieder des Stammteils nach Anlass, z.\u{00A0}B. Advent oder Abend")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appendixLink: some View {
        NavigationLink(value: Route.egAppendix) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Landeskirche")
                Text(state.selectedAppendix?.name ?? "Nicht gewählt · für die Nummern der EG-Anhänge")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appInfoLink: some View {
        NavigationLink(value: Route.appInfo) {
            VStack(alignment: .leading, spacing: 2) {
                Text("App-Informationen")
                Text("Aktualisierung, Version, Impressum und Datenschutz")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
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

/// Lesezeichen vor „Inventar“, gefüllt sobald Bücher eingetragen sind.
private struct InventoryIcon: View {
    let filled: Bool
    /// Wächst mit der Schriftgröße, sonst ragte das Symbol bei großer Schrift in den Text
    @ScaledMetric private var width: CGFloat = 24

    var body: some View {
        Image(systemName: filled ? "bookmark.fill" : "bookmark")
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
                Text("Einmalig ca. 2 MB. Danach funktioniert die Suche auch ohne Internet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

