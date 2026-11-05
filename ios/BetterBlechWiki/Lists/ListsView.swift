import BlechWikiCore
import SwiftUI

/// Übersicht: Favoriten fest oben, darunter die eigenen Listen. Anlegen über die Toolbar,
/// Umbenennen und Löschen über Kontextmenü oder Wischen. Die Favoriten haben diese Aktionen nicht.
struct ListsView: View {

    let container: AppContainer
    @State private var box = ModelBox<ListsModel>()
    /// Name im Dialog „Neue Liste“ bzw. „Liste umbenennen“. `nil`: geschlossen.
    @State private var newListName: String?
    @State private var renameName: String?
    @State private var renaming: ListSummary?
    @State private var deleting: ListSummary?

    init(container: AppContainer) {
        self.container = container
    }

    private var model: ListsModel {
        box { ListsModel(container: container) }
    }

    var body: some View {
        let model = self.model
        Group {
            if model.failed {
                ContentUnavailableView("Listen konnten nicht geöffnet werden.", systemImage: "exclamationmark.triangle")
            } else {
                list(model)
            }
        }
        .navigationTitle("Listen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.failed {
                ToolbarItem(placement: .topBarTrailing) {
                    ToolbarIconButton("Neue Liste", systemImage: "plus") { newListName = "" }
                }
            }
        }
        .focusedSceneValue(\.pageCommands, PageCommands(newList: model.failed ? nil : { newListName = "" }))
        .listNameAlert("Neue Liste", confirm: "Anlegen", name: $newListName, prompt: "z.\u{00A0}B. Konzert 3. Advent") {
            model.create(name: $0)
        }
        .listNameAlert("Liste umbenennen", confirm: "Speichern", name: $renameName) { name in
            if let renaming { model.rename(renaming, to: name) }
            renaming = nil
        }
        .alert(
            "Liste „\(deleting?.name ?? "")“ löschen?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { list in
            Button("Löschen", role: .destructive) { model.delete(list) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Die Liste und ihre Einträge werden gelöscht.")
        }
        .task { await model.observe() }
    }

    private func list(_ model: ListsModel) -> some View {
        List {
            ForEach(model.lists) { summary in
                NavigationLink(value: Route.list(id: summary.id)) {
                    ListSummaryRow(summary: summary).macRowPadding()
                }
                .contextMenu {
                    if !summary.isFavorites {
                        Button("Umbenennen", systemImage: "pencil") { rename(summary) }
                        Button("Löschen", systemImage: "trash", role: .destructive) { deleting = summary }
                    }
                }
                .swipeActions {
                    if !summary.isFavorites {
                        // Ohne `.destructive`: SwiftUI nähme die Zeile sonst gleich heraus, obwohl
                        // erst die Rückfrage kommt
                        Button("Löschen", systemImage: "trash") { deleting = summary }.tint(.red)
                        Button("Umbenennen", systemImage: "pencil") { rename(summary) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .readableWidth()
    }

    private func rename(_ summary: ListSummary) {
        renaming = summary
        renameName = summary.name
    }
}

private struct ListSummaryRow: View {
    let summary: ListSummary
    /// Wächst mit der Schriftgröße wie das Symbol auf der Startseite.
    @ScaledMetric private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.isFavorites ? "star.fill" : "list.bullet")
                .brandForeground()
                .frame(width: iconWidth, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name).lineLimit(2)
                Text(entriesLabel(summary.entryCount)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
