import BlechWikiCore
import SwiftUI

struct FundstellenView: View {

    let container: AppContainer
    let route: FundstellenRoute
    @State private var box = ModelBox<FundstellenModel>()
    // Der volle Titel steht als Überschrift in der Liste. In der Leiste erscheint er, sobald
    // die Überschrift weggescrollt ist oder es noch keine Liste gibt.
    @State private var headerVisible = true
    @State private var showCover = false
    /// Mac: Aktualisieren über Knopf oder ⌘R läuft, statt des Knopfs dreht sich ein Kreis.
    @State private var isManualRefresh = false
    @Environment(\.openRoute) private var openRoute

    init(container: AppContainer, route: FundstellenRoute) {
        self.container = container
        self.route = route
    }

    private var model: FundstellenModel {
        box { FundstellenModel(container: container, route: route) }
    }

    var body: some View {
        let model = self.model
        let content = model.content
        Group {
            if !model.hasLoaded && model.refreshFailed {
                ContentUnavailableView {
                    Label("Nicht geladen", systemImage: model.refreshFailedOnServer ? "exclamationmark.triangle" : "wifi.exclamationmark")
                } description: {
                    // Ein Fehler vom Server ist kein Verbindungsproblem, etwa bei einem gelöschten Buch
                    Text(model.refreshFailedOnServer
                        ? "Suchergebnisse konnten nicht geladen werden. blechwiki.de hat mit einem Fehler geantwortet, vielleicht gibt es den Eintrag dort nicht mehr."
                        : "Suchergebnisse konnten nicht geladen werden. Entweder fehlt die Internetverbindung, oder blechwiki.de ist gerade nicht erreichbar.")
                } actions: {
                    Button("Erneut versuchen") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                }
            } else if !model.hasLoaded {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(content)
            }
        }
        .navigationTitle(route.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(route.label).font(.headline).lineLimit(1)
                    let subtitle = subtitle(content)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(!model.hasLoaded || !headerVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: headerVisible)
            }
            if let bookId = route.bookId {
                ToolbarItem(placement: .topBarTrailing) {
                    BookmarkToggle(isOwned: model.routeBookOwned) { model.setOwned(bookId, owned: !model.routeBookOwned) }
                }
            }
            #if targetEnvironment(macCatalyst)
            // Ziehen zum Aktualisieren gibt es auf dem Mac nicht
            ToolbarItem(placement: .topBarTrailing) {
                if isManualRefresh {
                    ProgressView().controlSize(.small).accessibilityLabel("Wird aktualisiert")
                } else {
                    Button("Aktualisieren", systemImage: "arrow.clockwise") {
                        Task {
                            isManualRefresh = true
                            await model.refresh()
                            isManualRefresh = false
                        }
                    }
                    .keyboardShortcut("r")
                }
            }
            #endif
        }
        .modifier(BookSearch(enabled: route.isBook, text: Bindable(model).bookFilter))
        .fullScreenCover(isPresented: $showCover) {
            CoverViewer(url: model.book?.coverUrl ?? content.books.first?.coverUrl, title: model.book?.title ?? route.label)
        }
        .task { await model.observe() }
    }

    private func list(_ content: FundstellenContent) -> some View {
        @Bindable var model = model
        return List {
            Section {
                Group {
                    if route.isBook {
                        BookHeader(route: route, book: model.book, editorLink: model.editorLink,
                                   coverUrl: model.book?.coverUrl ?? content.books.first?.coverUrl,
                                   countLabel: countLabel(content)) { showCover = true }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.label).font(.title2.weight(.semibold))
                            Text(subtitle(content)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                .onAppear { headerVisible = true }
                .onDisappear { headerVisible = false }

                if route.isEgMelody {
                    Text("Enthält alle Sätze zu dieser Melodie, auch wenn sie im Heft unter einem anderen Liedtext stehen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                }
                if model.refreshFailed {
                    Label("Aktualisierung fehlgeschlagen, angezeigt wird der gespeicherte Stand.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                let showOwnedChip = content.ownedBookCount > 0 && !route.isBook
                let showSortChip = route.isBook && content.unfilteredCount > 1
                if content.scoringOptions.count > 1 || showOwnedChip || showSortChip {
                    FilterChips(
                        showSort: showSortChip,
                        sortByTitle: $model.sortByTitle,
                        showOwned: showOwnedChip,
                        ownedCount: content.ownedBookCount,
                        onlyOwned: $model.onlyOwned,
                        scoringOptions: content.scoringOptions,
                        selectedScoring: model.selectedScoring,
                        onSelectScoring: model.selectScoring
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
            .listRowSeparator(.hidden)

            if content.books.isEmpty {
                Text(model.isBookFiltered ? "Kein Stück passt zu deiner Suche." : "Keine Suchergebnisse.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
            }

            ForEach(content.books) { book in
                Section {
                    if !route.isBook {
                        NavigationLink(value: Route.fundstellen(FundstellenRoute(
                            query: .byBook(book.bookId), label: book.bookTitle, detail: book.bookSubtitle
                        ))) {
                            BookRow(book: book) { model.setOwned(book.bookId, owned: !book.isOwned) }
                                .macRowPadding()
                        }
                    }
                    ForEach(Array(book.entries.enumerated()), id: \.offset) { _, entry in
                        FundstelleRow(fundstelle: entry, routeLabel: route.label, composerLinks: model.composerLinks)
                            .macRowPadding()
                    }
                }
            }

            if let fetchedAt = model.fetchedAt {
                Section {
                } footer: {
                    Text("Stand: \(fetchedAt.formatted(standFormat)) · Quelle: blechwiki.de")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .readableWidth()
        // Komponisten-Links öffnen die Suchergebnisse des Komponisten wie ein Treffer in der Suche
        .environment(\.openURL, OpenURLAction { url in
            guard let link = model.composerLink(for: url) else { return .systemAction }
            openRoute(.fundstellen(FundstellenRoute(query: .byComposer(link.id), label: link.name, detail: link.lifeDates)))
            return .handled
        })
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.refresh() }
    }

    private func subtitle(_ content: FundstellenContent) -> String {
        [route.detail, countLabel(content)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Buchansicht: Einträge im Buch ("60 Stücke", gefiltert "3 von 60 Stücken").
    /// Sonst: Fundstellen des Lieds über alle Bücher.
    private func countLabel(_ content: FundstellenContent) -> String? {
        guard model.hasLoaded else { return nil }
        if route.isBook {
            if content.totalCount != content.unfilteredCount {
                return "\(content.totalCount) von \(content.unfilteredCount) Stücken"
            }
            return "\(content.unfilteredCount) \(content.unfilteredCount == 1 ? "Stück" : "Stücke")"
        }
        let books = content.books.count
        return "\(content.totalCount) \(content.totalCount == 1 ? "Suchergebnis" : "Suchergebnisse") in \(books) \(books == 1 ? "Buch" : "Büchern")"
    }
}

/// Suche im Buch, nur in der Buchansicht. Unten eingeklappt zur Lupe, weil man hier selten sucht.
private struct BookSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .appSearchable(text: $text, prompt: "In diesem Buch suchen", minimized: true)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } else {
            content
        }
    }
}

private struct FilterChips: View {
    let showSort: Bool
    @Binding var sortByTitle: Bool
    let showOwned: Bool
    let ownedCount: Int
    @Binding var onlyOwned: Bool
    let scoringOptions: [String]
    let selectedScoring: String?
    let onSelectScoring: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if showSort {
                    Chip(label: "Titel A–Z", systemImage: nil, selected: sortByTitle) { sortByTitle.toggle() }
                }
                if showOwned {
                    Chip(label: "Inventar (\(ownedCount))", systemImage: "bookmark.fill", selected: onlyOwned) { onlyOwned.toggle() }
                }
                if scoringOptions.count > 1 {
                    ForEach(scoringOptions, id: \.self) { scoring in
                        Chip(label: scoring, systemImage: nil, selected: scoring == selectedScoring) { onSelectScoring(scoring) }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct BookRow: View {
    let book: BookGroup
    let onToggleOwned: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookCover(url: book.coverUrl)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.bookTitle).font(.headline)
                if let subtitle = book.bookSubtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            BookmarkToggle(isOwned: book.isOwned, onToggle: onToggleOwned)
        }
    }
}

private struct FundstelleRow: View {
    let fundstelle: Fundstelle
    let routeLabel: String
    let composerLinks: [String: ComposerLink]
    @Environment(\.openURL) private var openURL
    /// Wächst mit der Schriftgröße, sonst bräche „Nr. 123“ bei großer Schrift um.
    @ScaledMetric(relativeTo: .subheadline) private var numberWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Nr. \(fundstelle.number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brand)
                .frame(width: numberWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                // Titel nur zeigen, wenn er vom gesuchten abweicht (andere Strophe, anderer Text zur Melodie, Buchansicht)
                let title = fundstelle.title.caseInsensitiveCompare(routeLabel.trimmingCharacters(in: .whitespaces)) == .orderedSame
                    ? nil : fundstelle.title
                let headline = [title, fundstelle.addition].compactMap { $0 }.joined(separator: " · ")
                if !headline.isEmpty { Text(headline) }
                if let composer = fundstelle.composer {
                    let names = ComposerNames.split(composer).map { ($0, composerLinks[$0]) }
                    Text(linkedNames(names))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .tint(Color.brand)
                        .linkPointer(names.contains { $0.1 != nil })
                }
                let tags = [fundstelle.scoring, fundstelle.keySignature.map(keySignatureLabel)].compactMap { $0 }
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { Tag(text: $0) }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        // Zusammengefasst sind die Links im Text für VoiceOver nicht erreichbar, daher als Aktionen
        .accessibilityActions {
            ForEach(linkedComposers, id: \.id) { link in
                Button("Suchergebnisse von \(link.name)") { openURL(link.url) }
            }
        }
    }

    private var linkedComposers: [ComposerLink] {
        var seen = Set<String>()
        return (fundstelle.composer.map(ComposerNames.split) ?? []).compactMap { composerLinks[$0] }.filter { seen.insert($0.id).inserted }
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.tagForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.tagBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Namen mit " / " getrennt. Namen mit Link in Markenfarbe, ein Tipp öffnet die Suchergebnisse
/// des Komponisten (`openURL` in `FundstellenView`).
private func linkedNames(_ names: [(String, ComposerLink?)]) -> AttributedString {
    var text = AttributedString()
    for (index, (name, link)) in names.enumerated() {
        if index > 0 { text += AttributedString(" / ") }
        var part = AttributedString(name)
        part.link = link?.url
        text += part
    }
    return text
}

/// "1b" → "1 ♭", "2#" → "2 ♯", "0" → "ohne Vorzeichen"
private func keySignatureLabel(_ raw: String) -> String {
    if raw == "0" { return "ohne Vorzeichen" }
    if raw.hasSuffix("b") { return raw.dropLast() + " ♭" }
    if raw.hasSuffix("#") { return raw.dropLast() + " ♯" }
    return raw
}

private struct BookHeader: View {
    let route: FundstellenRoute
    let book: BookItem?
    let editorLink: ComposerLink?
    let coverUrl: String?
    let countLabel: String?
    let onCoverTap: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onCoverTap) {
                LargeBookCover(url: coverUrl, width: sizeClass == .regular ? 140 : 96)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cover vergrößern")
            VStack(alignment: .leading, spacing: 4) {
                Text(book?.title ?? route.label).font(.title3.weight(.semibold))
                // Die Zusatzzeile aus der Suche enthält Verlag und Jahr, die unten schon stehen. Nur als
                // Ersatz, solange das Buch nicht im Verzeichnis ist
                if let subtitle = book.map(\.subtitle) ?? route.detail {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if let editor = book?.editor {
                    Text(AttributedString("Hrsg. ") + linkedNames([(editor, editorLink)]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tint(Color.brand)
                        .linkPointer(editorLink != nil)
                }
                let publishing = [book?.publisher, book?.publisherNumber.map { "Best.-Nr. \($0)" }, book?.year.map(String.init)]
                    .compactMap { $0 }.joined(separator: " · ")
                if !publishing.isEmpty {
                    Text(publishing).font(.caption).foregroundStyle(.secondary)
                }
                if let countLabel {
                    Text(countLabel).font(.subheadline.weight(.medium)).foregroundStyle(Color.brand)
                }
            }
        }
    }
}
