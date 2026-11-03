import BlechWikiCore
import SwiftUI

struct MyBooksView: View {

    let container: AppContainer
    @State private var box = ModelBox<MyBooksModel>()
    @Environment(\.openRoute) private var openRoute

    /// Mac: Umschalter „Alle Bücher | Inventar“ in der Toolbar statt über der Liste, wie dort üblich.
    private static let pickerInToolbar = UIDevice.current.userInterfaceIdiom == .mac

    init(container: AppContainer) {
        self.container = container
    }

    private var model: MyBooksModel {
        box { MyBooksModel(container: container) }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if let sections = model.sections {
                bookList(sections)
            } else if model.sectionsFailed {
                ContentUnavailableView {
                    Label("Nicht geladen", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Die Bücherliste konnte nicht gelesen werden. Bitte BlechWiki schließen und neu öffnen.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Inventar")
        .appSearchable(text: $model.filter, prompt: "Buch suchen")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            // `.principal` zeigt Catalyst nicht an, daher rechts vor den Knöpfen. Ohne eigene Glasfläche:
            // Der Umschalter bringt seine Spur selbst mit, in der Glaskapsel der Toolbar war er doppelt gerahmt.
            if Self.pickerInToolbar && model.sections != nil {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarTrailing) { displayPicker.fixedSize() }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) { displayPicker.fixedSize() }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let message = model.shareMessage {
                    ShareLink(item: message) {
                        Image(systemName: "square.and.arrow.up").toolbarIconFrame()
                    }
                    // Ohne eigenen Stil färbte die Mac-Toolbar den Knopf als Hauptaktion in der Markenfarbe
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Inventar teilen")
                }
                #if targetEnvironment(macCatalyst)
                // Ein Menü mit nur einem Eintrag wäre ein Klick zu viel. Der Befehl steht auch im Menü „Inventar“.
                ToolbarIconButton("Inventar-Code einfügen", systemImage: "doc.on.clipboard") { model.openImport() }
                #else
                // Selten gebraucht, daher im Menü
                Menu {
                    Button("Inventar-Code einfügen", systemImage: "doc.on.clipboard") { model.openImport() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Weitere Optionen")
                #endif
            }
        }
        .focusedSceneValue(\.pageCommands, PageCommands(shareMessage: model.shareMessage, importCode: model.openImport))
        .sheet(isPresented: Binding(get: { model.importText != nil }, set: { if !$0 { model.closeImport() } })) {
            ImportSheet(model: model)
        }
        .task { await model.observe() }
    }

    private func bookList(_ sections: BookSections) -> some View {
        @Bindable var model = model
        return List {
            if Self.pickerInToolbar {
                // Steht der Umschalter in der Toolbar, wäre der Abschnitt leer. Seine Fußzeile verblasste
                // dann nach dem Scrollen unter dem mitlaufenden Kopf „Vorschläge für …“. Als Zeile nicht.
                Text(offlineLabel)
            } else {
                Section {
                    displayPicker.listRowSeparator(.hidden)
                } footer: {
                    Text(offlineLabel)
                }
            }

            if let filtered = sections.filtered {
                let shown = model.onlySelected ? filtered.filter(\.isOwned) : filtered
                if shown.isEmpty { emptyHint("Kein passendes Buch gefunden.") }
                books(shown)
            } else if model.onlySelected {
                let selected = sections.all.filter(\.isOwned)
                if selected.isEmpty { emptyHint("Noch keine Bücher im Inventar.") }
                books(selected)
            } else {
                // Bleibt auch nach der ersten Auswahl stehen. Verschwände er, rutschte die Liste
                // nach oben und schnelle Folgetipps träfen das falsche Buch.
                Text("Hake die Bücher an, die im Notenschrank stehen. Ihr Inhalt wird geladen und steht danach auch ohne Internet zur Verfügung. Ein Tipp auf ein Buch zeigt, was drinsteht.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let appendix = model.selectedAppendix {
                    if !sections.suggested.isEmpty {
                        bookSection("Vorschläge für \(appendix.name)", sections.suggested)
                    }
                } else {
                    NavigationLink(value: Route.egAppendix) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Landeskirche wählen")
                            Text("Dann stehen hier die Hefte deiner Landeskirche.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if !sections.choralBooks.isEmpty {
                    bookSection("Choralbücher", sections.choralBooks)
                }
                bookSection("Alle Bücher, neueste zuerst", sections.all)
            }
        }
        .listStyle(.plain)
        .readableWidth()
        .scrollDismissesKeyboard(.immediately)
    }

    private var displayPicker: some View {
        @Bindable var model = model
        return Picker("Anzeige", selection: $model.onlySelected) {
            Text("Alle Bücher").tag(false)
            Text("Inventar (\(model.offline.owned))").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private var offlineLabel: String {
        let offline = model.offline
        if offline.owned == 0 { return "Noch leer" }
        if offline.available < offline.owned {
            return "\(booksLabel(offline.owned)) · \(offline.available) offline verfügbar"
        }
        return "\(booksLabel(offline.owned)) · alle offline verfügbar"
    }

    private func details(_ book: BookItem) -> String {
        // Bei Jahresheften ist der Untertitel oft nur das Jahr
        var seen = Set<String>()
        return [book.subtitle, book.year.map(String.init), book.publisher]
            .compactMap { $0 }.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// Mac: Überschrift als normale Zeile statt als Abschnittskopf. Abschnittsköpfe bleiben beim Scrollen
    /// oben stehen, und unter Catalyst blieb ihr heller Hintergrund nach dem Zurückscrollen über dem
    /// Listenanfang liegen.
    @ViewBuilder
    private func bookSection(_ title: String, _ items: [BookItem]) -> some View {
        if UIDevice.current.userInterfaceIdiom == .mac {
            sectionHeader(title).padding(.top, 8).listRowSeparator(.hidden)
            books(items)
        } else {
            Section(header: sectionHeader(title)) { books(items) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity).padding(.vertical, 32).listRowSeparator(.hidden)
    }

    /// Tipp auf das Buch öffnet seinen Inhalt, Tipp auf den Kreis nimmt es ins Inventar auf oder entfernt es.
    private func books(_ books: [BookItem]) -> some View {
        ForEach(books) { book in
            let route = Route.fundstellen(FundstellenRoute(query: .byBook(book.id), label: book.title, detail: book.subtitle))
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    Button { model.toggle(book) } label: {
                        Image(systemName: book.isOwned ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(book.isOwned ? Color.brand : Color.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(book.isOwned ? "Aus dem Inventar entfernen" : "Zum Inventar hinzufügen")
                    BookCover(url: book.coverUrl, width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).lineLimit(2)
                        let details = details(book)
                        if !details.isEmpty {
                            Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
            .accessibilityAddTraits(book.isOwned ? .isSelected : [])
            .bookContextMenu(isOwned: book.isOwned, open: { openRoute(route) }, toggleOwned: { model.toggle(book) })
        }
    }
}

private struct ImportSheet: View {
    @Bindable var model: MyBooksModel

    private static let previewTitles = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Auf dem Mac schreibt das Feld beim Schließen seinen Text noch einmal zurück. Ohne die
                    // Prüfung wäre importText danach wieder gesetzt und der Dialog ginge sofort neu auf
                    TextField("BBW-…", text: Binding(get: { model.importText ?? "" }, set: { if model.importText != nil { model.importText = $0 } }), axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .font(.body.monospaced())
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first { model.paste(text) }
                    }
                    .labelStyle(.titleAndIcon)
                } header: {
                    Text("Inventar-Code")
                } footer: {
                    fieldHint
                }

                if case let .ready(books, unknown) = model.importPreview {
                    if !books.isEmpty {
                        Section(recognizedTitle(books)) {
                            ForEach(books.prefix(Self.previewTitles)) { Text($0.title) }
                            if books.count > Self.previewTitles {
                                Text("und \(books.count - Self.previewTitles) weitere").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if unknown > 0 {
                        Section { UnknownBooksHint(count: unknown, check: model.catalogCheck) }
                    }
                    if !books.isEmpty && model.offline.owned > 0 {
                        Section {
                            Toggle("Bisheriges Inventar (\(booksLabel(model.offline.owned))) ersetzen", isOn: $model.replaceInventory)
                        }
                    }
                }
            }
            .navigationTitle("Inventar übernehmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { model.closeImport() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.replaceInventory ? "Ersetzen" : "Übernehmen") { model.confirmImport() }
                        .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canConfirm: Bool {
        if case let .ready(books, _) = model.importPreview { return !books.isEmpty }
        return false
    }

    @ViewBuilder
    private var fieldHint: some View {
        let text = model.importText ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Code oder ganze Nachricht einfügen")
        } else if model.importPreview == .noCode {
            WarningLabel("Kein Code gefunden. Er beginnt mit BBW-.")
        } else if model.importPreview == .invalid {
            WarningLabel("Code unvollständig oder verändert. Bitte neu kopieren.")
        }
    }

    private func recognizedTitle(_ books: [BookItem]) -> String {
        let alreadyOwned = books.filter(\.isOwned).count
        let suffix = switch alreadyOwned {
        case 0: ""
        case books.count: ", alle schon im Inventar"
        default: ", \(alreadyOwned) davon schon im Inventar"
        }
        return "\(booksLabel(books.count)) erkannt\(suffix)"
    }
}

/// Bücher, die das Verzeichnis nicht kennt. Neue Bücher kommen nach dem Abgleich von selbst in die Liste.
private struct UnknownBooksHint: View {
    let count: Int
    let check: CatalogCheck

    var body: some View {
        let subject = count == 1 ? "1 Buch ist" : "\(count) Bücher sind"
        switch check {
        case .notStarted, .running:
            HStack(spacing: 12) {
                ProgressView()
                Text("\(subject) noch nicht im Verzeichnis. Suche bei BlechWiki nach neuen Büchern …").font(.subheadline)
            }
        case .done:
            WarningLabel("\(subject) auch im aktuellen Verzeichnis nicht zu finden. Vermutlich wurde der Code verändert.")
                .font(.subheadline)
        case .failed:
            WarningLabel("\(subject) nicht im Verzeichnis. BlechWiki ist gerade nicht erreichbar. Code später noch einmal einfügen.")
                .font(.subheadline)
        }
    }
}
