import BlechWikiCore
import Observation
import SwiftUI

/// Blatt „Zu Liste hinzufügen“: neue Liste, Favoriten als Schalter, dann alle eigenen Listen.
/// Ein Tipp auf eine Liste hängt das Lied an, auch wenn es dort schon steht.
struct AddToListSheet: View {

    let container: AppContainer
    let ref: ListEntryRef
    @State private var box = ModelBox<AddToListModel>()
    /// Name im Dialog „Neue Liste“. `nil`: geschlossen.
    @State private var newListName: String?
    @Environment(\.dismiss) private var dismiss

    init(container: AppContainer, ref: ListEntryRef) {
        self.container = container
        self.ref = ref
    }

    var body: some View {
        @Bindable var model = box { AddToListModel(container: container, ref: ref) }
        NavigationStack {
            List {
                Section {
                    Button("Neue Liste …", systemImage: "plus") { newListName = "" }
                }
                Section {
                    ForEach(model.lists) { summary in
                        row(summary, model: model)
                    }
                }
            }
            .navigationTitle("Zu Liste hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .listNameAlert("Neue Liste", confirm: "Anlegen", name: $newListName, prompt: "z.\u{00A0}B. Konzert 3. Advent") {
                model.createList(named: $0)
            }
            .removeCommentedEntryAlert(isPresented: $model.confirmUnfavorite, onRemove: model.removeFavorite)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ summary: ListSummary, model: AddToListModel) -> some View {
        Button {
            if summary.isFavorites { model.toggleFavorite() } else { model.add(to: summary.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: summary.isFavorites ? "star.fill" : "list.bullet")
                    .brandForeground()
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(summary.name).foregroundStyle(Color.primary)
                Spacer()
                if summary.isFavorites {
                    if model.isFavorite {
                        // Vorgelesen wird der Stand über .isSelected
                        Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold).accessibilityHidden(true)
                    }
                } else if model.added.contains(summary.id) {
                    Text("Hinzugefügt").font(.subheadline).foregroundStyle(Color.brand)
                } else if model.containing.contains(summary.id) {
                    Text("Schon enthalten").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(summary.isFavorites && model.isFavorite ? .isSelected : [])
    }
}

@MainActor
@Observable
final class AddToListModel {

    let ref: ListEntryRef
    private(set) var lists: [ListSummary] = []
    /// Listen, in denen das Lied steht.
    private(set) var containing: Set<String> = []
    /// Listen, an die es in diesem Blatt angehängt wurde.
    private(set) var added: Set<String> = []
    /// Rückfrage, bevor ein Favorit mit Kommentar verschwindet.
    var confirmUnfavorite = false

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer, ref: ListEntryRef) {
        self.container = container
        self.ref = ref
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    var isFavorite: Bool { containing.contains(ListsRepository.favoritesId) }

    func add(to listId: String) {
        guard (try? container.lists.add(ref, to: listId)) != nil else { return }
        added.insert(listId)
        reload()
    }

    /// Legt die Liste an und hängt das Lied gleich an.
    func createList(named name: String) {
        guard let id = try? container.lists.createList(name: name) else { return }
        add(to: id)
    }

    func toggleFavorite() {
        if isFavorite, (try? container.lists.favoriteComment(key: ref.key)) != nil {
            confirmUnfavorite = true
            return
        }
        _ = try? container.lists.toggleFavorite(ref)
        reload()
    }

    func removeFavorite() {
        if isFavorite { _ = try? container.lists.toggleFavorite(ref) }
        reload()
    }

    private func reload() {
        lists = (try? container.lists.lists()) ?? []
        containing = (try? container.lists.listIds(containing: ref.key)) ?? []
    }
}
