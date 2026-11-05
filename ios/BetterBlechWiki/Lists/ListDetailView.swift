import BlechWikiCore
import SwiftUI

/// Eine Liste. Umsortieren per Ziehen (mit „Bearbeiten“ auch über die Griffe), gespeichert beim
/// Loslassen. Kommentar und Entfernen über Kontextmenü und Wischen. Ein Eintrag mit Kommentar
/// verschwindet erst nach Rückfrage.
struct ListDetailView: View {

    let container: AppContainer
    let listId: String
    @State private var box = ModelBox<ListDetailModel>()
    @State private var editingComment: ListEntryItem?
    /// Eintrag mit Kommentar, der auf die Rückfrage wartet.
    @State private var removing: ListEntryItem?

    init(container: AppContainer, listId: String) {
        self.container = container
        self.listId = listId
    }

    private var model: ListDetailModel {
        box { ListDetailModel(container: container, listId: listId) }
    }

    var body: some View {
        let model = self.model
        Group {
            if model.failed {
                ContentUnavailableView("Listen konnten nicht geöffnet werden.", systemImage: "exclamationmark.triangle")
            } else if model.isGone {
                ContentUnavailableView("Diese Liste gibt es nicht mehr.", systemImage: "list.bullet")
            } else if let detail = model.detail {
                if detail.entries.isEmpty {
                    ContentUnavailableView {
                        Label(detail.name, systemImage: detail.isFavorites ? "star" : "list.bullet")
                    } description: {
                        Text(detail.isFavorites
                            ? "Noch keine Favoriten. Tippe in den Suchergebnissen auf den Stern, um ein Lied hier zu sammeln."
                            : "Diese Liste ist leer. Lieder fügst du in den Suchergebnissen über „Zu Liste hinzufügen“ hinzu.")
                    }
                } else {
                    entries(detail)
                }
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.detail?.name ?? "Listen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.detail?.entries.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(item: $editingComment) { entry in
            CommentEditor(comment: entry.comment) { model.setComment(entry, $0) }
        }
        .removeCommentedEntryAlert(
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            onRemove: { if let removing { model.remove(removing) } }
        )
        .task { await model.observe() }
    }

    private func entries(_ detail: ListDetail) -> some View {
        let count = detail.entries.count
        return List {
            ForEach(Array(detail.entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink(value: entry.route) {
                    ListEntryRow(entry: entry).macRowPadding()
                }
                .contextMenu {
                    commentButton(entry)
                    Button("Entfernen", systemImage: "trash", role: .destructive) { requestRemove(entry) }
                }
                // Ohne `.destructive`: SwiftUI nähme die Zeile sonst gleich heraus, auch wenn erst die
                // Rückfrage kommt
                .swipeActions(edge: .trailing) {
                    Button("Entfernen", systemImage: "trash") { requestRemove(entry) }.tint(.red)
                }
                .swipeActions(edge: .leading) {
                    commentButton(entry).tint(.brand)
                }
                // Ziehen geht mit VoiceOver nur über die Griffe im Bearbeiten-Modus
                .accessibilityActions {
                    if index > 0 {
                        Button("Nach oben verschieben") { model.move(from: [index], to: index - 1) }
                    }
                    if index < count - 1 {
                        Button("Nach unten verschieben") { model.move(from: [index], to: index + 2) }
                    }
                }
            }
            .onMove { model.move(from: $0, to: $1) }
            .onDelete { offsets in
                for entry in offsets.map({ detail.entries[$0] }) { requestRemove(entry) }
            }
        }
        .listStyle(.insetGrouped)
        .readableWidth()
    }

    private func commentButton(_ entry: ListEntryItem) -> some View {
        Button(entry.comment == nil ? "Kommentar hinzufügen" : "Kommentar bearbeiten", systemImage: "text.bubble") {
            editingComment = entry
        }
    }

    private func requestRemove(_ entry: ListEntryItem) {
        if entry.comment != nil {
            removing = entry
        } else {
            model.remove(entry)
        }
    }
}

extension ListEntryItem {
    /// Wohin ein Tipp führt: Titel und EG-Lied in die Suchergebnisse, Fundstelle ins Buch mit dem
    /// Titel in der Suche im Buch.
    var route: Route {
        switch ref {
        case .title(let title):
            .suchergebnisse(SuchergebnisseRoute(query: .title(title), label: title))
        case let .piece(bookId, storedBookTitle, _, _, _):
            .suchergebnisse(SuchergebnisseRoute(query: .byBook(bookId), label: bookTitle ?? storedBookTitle, initialFilter: title))
        case let .eg(ix, ixUr, _, _):
            .suchergebnisse(SuchergebnisseRoute(query: .byEgMelody(ixUr), label: title, detail: egNumber, egIx: ix))
        }
    }
}

private struct ListEntryRow: View {
    let entry: ListEntryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if entry.ref.kind == .piece {
                BookCover(url: entry.coverUrl)
            }
            VStack(alignment: .leading, spacing: 2) {
                lines
                if let comment = entry.comment {
                    Text(comment)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if entry.isOwnedBook {
                Image(systemName: "bookmark.fill").brandForeground()
                    .accessibilityLabel("Im Inventar")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var lines: some View {
        switch entry.ref.kind {
        case .eg:
            if let number = entry.egNumber {
                Text(number).font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.title).lineLimit(2)
            if !entry.ownedLocations.isEmpty {
                OwnedLine(locations: entry.ownedLocations)
            }
        case .title:
            Text(entry.title).lineLimit(2)
            Text(bookCountLabel(entry.bookCount ?? 0)).font(.subheadline).foregroundStyle(.secondary)
            if !entry.ownedLocations.isEmpty {
                OwnedLine(locations: entry.ownedLocations)
            }
        case .piece:
            // Wie in den Fundstellen-Zeilen: Titel und Zusatz wie „Vorspiel“
            Text([entry.title, entry.addition].compactMap { $0 }.joined(separator: " · ")).lineLimit(2)
            Text("\(entry.bookTitle ?? "") · Nr. \(entry.number ?? "")").font(.subheadline).foregroundStyle(.secondary)
            if entry.isMissing {
                Text("Nicht mehr im Verzeichnis von blechwiki.de").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// "In 1 Buch", "In 7 Büchern", "In keinem Buch"
    private func bookCountLabel(_ count: Int) -> String {
        switch count {
        case 0: "In keinem Buch"
        case 1: "In 1 Buch"
        default: "In \(count) Büchern"
        }
    }
}

/// Kommentar zu einem Eintrag, höchstens `ListsRepository.maxCommentLength` Zeichen. Leer gespeichert
/// löscht ihn.
private struct CommentEditor: View {
    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(comment: String?, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Kommentar", text: $text, prompt: Text("z.\u{00A0}B. nur Strophe 1 und 3"), axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .onChange(of: text) { _, new in
                        if new.count > ListsRepository.maxCommentLength {
                            text = String(new.prefix(ListsRepository.maxCommentLength))
                        }
                    }
            }
            .navigationTitle("Kommentar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
