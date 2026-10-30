import BlechWikiCore
import SwiftUI

struct SearchView: View {

    @State private var model: SearchModel

    init(container: AppContainer) {
        _model = State(initialValue: SearchModel(container: container))
    }

    var body: some View {
        content
            .navigationTitle("BlechWiki")
            // Kurz halten: Auf schmalen Geräten passen ~25 Zeichen
            .appSearchable(text: $model.query, prompt: "Lied, EG-Nr. oder Buch")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task { await model.observe() }
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.initialLoad != .ready {
            InitialLoadView(state: model.initialLoad, onRetry: model.retrySync)
        } else if trimmed.isEmpty {
            StartView(state: model.start)
        } else if model.results.isEmpty {
            ContentUnavailableView {
                Label("Keine Treffer für „\(trimmed)“", systemImage: "magnifyingglass")
            } description: {
                Text("Weniger Wörter oder nur Wortanfänge eingeben, z. B. „lob herr“.")
            }
        } else {
            ResultList(results: model.results)
        }
    }
}

private struct ResultList: View {
    let results: SearchResults

    var body: some View {
        List {
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
                Image(systemName: "bookmark.fill").foregroundStyle(Color.brand)
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
        .foregroundStyle(Color.brand)
        .labelStyle(.titleAndIcon)
    }
}

private struct StartView: View {
    let state: StartState

    var body: some View {
        List {
            // Intro im Inhalt statt in einem eigenen Großtitel (Toolbar-Platz `.largeTitle`).
            // Der nahm nicht an der Navigations-Animation teil: Er blieb über der nächsten Seite
            // stehen, bis sie ganz offen war, und der Intro-Text sprang beim Zurückkommen um.
            Section {
                Text(Self.intro).font(.subheadline).foregroundStyle(.secondary)
            }

            Section {
                NavigationLink(value: Route.myBooks) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: state.offlineStatus.owned > 0 ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(Color.brand)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inventar")
                            Text(inventoryText).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Kein Symbol wie beim Inventar: Dort zeigt es den Stand (gefüllt = Bücher eingetragen),
            // hier wäre es nur Schmuck. Gleich wie in der Android-App.
            Section {
                NavigationLink(value: Route.hymnal) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gesangbuch")
                        Text(state.selectedAppendix.map { "Alle EG-Lieder nach Anlass, mit dem Anhang \($0.name)" }
                            ?? "Alle EG-Lieder des Stammteils nach Anlass, z. B. Advent oder Abend")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                NavigationLink(value: Route.egAppendix) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Landeskirche")
                        Text(state.selectedAppendix?.name ?? "Nicht gewählt · für die Nummern der EG-Anhänge")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Beantwortet die naheliegende Frage, ob "Offline" heißt, dass nichts mehr nachkommt.
            // Als Text ohne Karte: Hier gibt es nichts anzutippen.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aktualisierung").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                    Text("Die Daten kommen von blechwiki.de. Beim Öffnen fragt die App höchstens einmal am Tag nach neuen und korrigierten Büchern, Liedern und Komponisten. Geladen wird nur, was sich geändert hat, einmal im Monat im WLAN zur Sicherheit alles. Ohne Internet bleibt der letzte Stand nutzbar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Zuletzt geprüft: \(state.lastCheckedAt?.formatted(standFormat) ?? "noch nie")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
        }
        // Eine Karte je Eintrag wie in der Android-App. Mit dem Standardabstand zwischen den
        // Abschnitten wirkte die Seite zu luftig.
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.immediately)
    }

    static let intro: LocalizedStringKey = "Suche nach Liedtitel, EG-Nummer, Buch oder Komponist. Die Suche läuft auf dem iPhone und funktioniert auch ohne Internet."

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

private struct InitialLoadView: View {
    let state: InitialLoad
    let onRetry: () -> Void

    var body: some View {
        if state == .failed {
            ContentUnavailableView {
                Label("Keine Verbindung", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Das Liederverzeichnis konnte nicht geladen werden. Bitte Internetverbindung prüfen.")
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

