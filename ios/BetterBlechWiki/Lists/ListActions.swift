import BlechWikiCore
import Observation
import SwiftUI

/// Stern und „Zu Liste hinzufügen …“ für Suchtreffer, Fundstellen, Gesangbuch und Suchergebnisse.
/// Einmal pro Fenster in `RootView` angelegt und über die Umgebung verteilt. Blatt und Rückfrage
/// hängen dort (`listActionsPresentation`), damit jede Zeile sie öffnen kann.
@MainActor
@Observable
final class ListActions {

    private(set) var favoriteKeys: Set<String> = []
    /// Lied für das Blatt „Zu Liste hinzufügen“. `nil`: geschlossen.
    var addTarget: ListEntryRef?
    /// Favorit mit Kommentar, dessen Stern abgeschaltet werden soll. Wartet auf die Rückfrage.
    var pendingUnfavorite: ListEntryRef?

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer) {
        self.container = container
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    /// Ohne Datei der Listen gibt es die Menüeinträge nicht.
    var isAvailable: Bool { container.lists.isAvailable }

    func isFavorite(_ ref: ListEntryRef) -> Bool {
        favoriteKeys.contains(ref.key)
    }

    /// Stern umschalten. Ein Favorit mit Kommentar wird erst nach Rückfrage entfernt.
    func toggleFavorite(_ ref: ListEntryRef) {
        if isFavorite(ref), (try? container.lists.favoriteComment(key: ref.key)) != nil {
            pendingUnfavorite = ref
            return
        }
        _ = try? container.lists.toggleFavorite(ref)
    }

    func confirmUnfavorite() {
        guard let ref = pendingUnfavorite else { return }
        pendingUnfavorite = nil
        if isFavorite(ref) { _ = try? container.lists.toggleFavorite(ref) }
    }

    func addToList(_ ref: ListEntryRef) {
        addTarget = ref
    }

    private func reload() {
        favoriteKeys = (try? container.lists.favoriteKeys()) ?? []
    }
}

extension View {
    /// Blatt „Zu Liste hinzufügen“ und Rückfrage beim Stern. Einmal pro Fenster, in `RootView`.
    func listActionsPresentation(_ actions: ListActions, container: AppContainer) -> some View {
        modifier(ListActionsPresentation(actions: actions, container: container))
    }

    /// Kontextmenü mit Stern und „Zu Liste hinzufügen …“. Ohne `ref` (Bücher, Komponisten) unverändert.
    @ViewBuilder
    func listEntryMenu(_ ref: ListEntryRef?) -> some View {
        if let ref {
            contextMenu { ListMenuItems(ref: ref) }
        } else {
            self
        }
    }

    /// Wischen nach rechts schaltet den Stern um, wie „Als ungelesen markieren“ in Mail.
    func favoriteSwipeAction(_ ref: ListEntryRef) -> some View {
        swipeActions(edge: .leading) { FavoriteSwipeButton(ref: ref) }
    }

    /// Dialog mit dem Feld „Name“ zum Anlegen oder Umbenennen einer Liste. `name` = nil: geschlossen.
    func listNameAlert(_ title: String, confirm: String, name: Binding<String?>, prompt: String? = nil,
                       onConfirm: @escaping (String) -> Void) -> some View {
        alert(title, isPresented: Binding(get: { name.wrappedValue != nil }, set: { if !$0 { name.wrappedValue = nil } })) {
            // Auf dem Mac schreibt das Feld beim Schließen seinen Text noch einmal zurück, wie im
            // Import-Dialog des Inventars. Ohne die Prüfung ginge der Dialog sofort wieder auf.
            TextField("Name", text: Binding(get: { name.wrappedValue ?? "" }, set: { if name.wrappedValue != nil { name.wrappedValue = $0 } }),
                      prompt: prompt.map { Text($0) })
            Button(confirm) {
                if let value = name.wrappedValue { onConfirm(value) }
                name.wrappedValue = nil
            }
            .disabled((name.wrappedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Abbrechen", role: .cancel) { name.wrappedValue = nil }
        }
    }

    /// Rückfrage, bevor ein Eintrag mit Kommentar verschwindet.
    func removeCommentedEntryAlert(isPresented: Binding<Bool>, onRemove: @escaping () -> Void) -> some View {
        alert("Eintrag mit Kommentar entfernen?", isPresented: isPresented) {
            Button("Entfernen", role: .destructive, action: onRemove)
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

private struct ListActionsPresentation: ViewModifier {
    @Bindable var actions: ListActions
    let container: AppContainer

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { actions.addTarget != nil }, set: { if !$0 { actions.addTarget = nil } })) {
                if let ref = actions.addTarget {
                    AddToListSheet(container: container, ref: ref)
                }
            }
            .removeCommentedEntryAlert(
                isPresented: Binding(get: { actions.pendingUnfavorite != nil }, set: { if !$0 { actions.pendingUnfavorite = nil } }),
                onRemove: actions.confirmUnfavorite
            )
    }
}

/// „Zu Favoriten hinzufügen“ bzw. „Aus Favoriten entfernen“ und „Zu Liste hinzufügen …“.
struct ListMenuItems: View {
    let ref: ListEntryRef
    @Environment(ListActions.self) private var actions: ListActions?

    var body: some View {
        if let actions, actions.isAvailable {
            let favorite = actions.isFavorite(ref)
            Button(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", systemImage: favorite ? "star.slash" : "star") {
                actions.toggleFavorite(ref)
            }
            Button("Zu Liste hinzufügen …", systemImage: "text.badge.plus") { actions.addToList(ref) }
        }
    }
}

private struct FavoriteSwipeButton: View {
    let ref: ListEntryRef
    @Environment(ListActions.self) private var actions: ListActions?

    var body: some View {
        if let actions, actions.isAvailable {
            let favorite = actions.isFavorite(ref)
            Button(favorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", systemImage: favorite ? "star.slash" : "star") {
                actions.toggleFavorite(ref)
            }
            .tint(.brand)
        }
    }
}

/// Kleiner gefüllter Stern in einer Zeile, nur bei Favoriten.
struct FavoriteMark: View {
    let ref: ListEntryRef
    @Environment(ListActions.self) private var actions: ListActions?

    var body: some View {
        if actions?.isFavorite(ref) == true {
            Image(systemName: "star.fill")
                .imageScale(.small)
                .brandForeground()
                .accessibilityLabel("Favorit")
        }
    }
}

/// Stern in der Toolbar der Suchergebnisse, wie `BookmarkToggle` für Bücher.
struct FavoriteToggle: View {
    let isFavorite: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.brand : Color.secondary)
                .frame(minWidth: iconButtonSize, minHeight: iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
    }
}

/// "1 Eintrag", "12 Einträge", "Keine Einträge"
func entriesLabel(_ count: Int) -> String {
    switch count {
    case 0: "Keine Einträge"
    case 1: "1 Eintrag"
    default: "\(count) Einträge"
    }
}
