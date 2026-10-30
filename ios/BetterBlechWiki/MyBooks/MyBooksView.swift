import BlechWikiCore
import SwiftUI

struct MyBooksView: View {

    @State private var model: MyBooksModel

    init(container: AppContainer) {
        _model = State(initialValue: MyBooksModel(container: container))
    }

    var body: some View {
        Group {
            if let sections = model.sections {
                bookList(sections)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Inventar")
        .appSearchable(text: $model.filter, prompt: "Buch suchen")
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let message = model.shareMessage {
                    ShareLink(item: message) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Inventar teilen")
                }
                // Selten gebraucht, daher im Menü
                Menu {
                    Button("Inventar-Code einfügen", systemImage: "doc.on.clipboard") { model.openImport() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Weitere Optionen")
            }
        }
        .sheet(isPresented: Binding(get: { model.importText != nil }, set: { if !$0 { model.closeImport() } })) {
            ImportSheet(model: model)
        }
        .task { await model.observe() }
    }

    private func bookList(_ sections: BookSections) -> some View {
        List {
            Section {
                Picker("Anzeige", selection: $model.onlySelected) {
                    Text("Alle Bücher").tag(false)
                    Text("Inventar (\(model.offline.owned))").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            } footer: {
                Text(offlineLabel)
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
                        Section(header: sectionHeader("Vorschläge für \(appendix.name)")) { books(sections.suggested) }
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
                    Section(header: sectionHeader("Choralbücher")) { books(sections.choralBooks) }
                }
                Section(header: sectionHeader("Alle Bücher, neueste zuerst")) { books(sections.all) }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity).padding(.vertical, 32).listRowSeparator(.hidden)
    }

    /// Tipp auf das Buch öffnet seinen Inhalt, Tipp auf den Kreis nimmt es ins Inventar auf oder entfernt es.
    private func books(_ books: [BookItem]) -> some View {
        ForEach(books) { book in
            NavigationLink(value: Route.fundstellen(FundstellenRoute(query: .byBook(book.id), label: book.title, detail: book.subtitle))) {
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
                    TextField("BBW-…", text: Binding(get: { model.importText ?? "" }, set: { model.importText = $0 }), axis: .vertical)
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
            Text("Kein Code gefunden. Er beginnt mit BBW-.").foregroundStyle(.red)
        } else if model.importPreview == .invalid {
            Text("Code unvollständig oder verändert. Bitte neu kopieren.").foregroundStyle(.red)
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
            Text("\(subject) auch im aktuellen Verzeichnis nicht zu finden. Vermutlich wurde der Code verändert.")
                .font(.subheadline).foregroundStyle(.red)
        case .failed:
            Text("\(subject) nicht im Verzeichnis. BlechWiki ist gerade nicht erreichbar. Code später noch einmal einfügen.")
                .font(.subheadline).foregroundStyle(.red)
        }
    }
}
