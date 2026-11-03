import BlechWikiCore

/// Ruft `onChange` nach jeder Änderung an Daten oder Einstellungen auf, solange das Model lebt.
///
/// Bewusst nicht in `.task` der Seite: SwiftUI brach das teils ab, während die Seite stehen blieb,
/// und startete es nicht neu. Danach kam keine Änderung mehr an. Das Häkchen im Inventar blieb beim
/// ersten Öffnen nach der Installation leer, und Treffer aus der Suche zeigten dauerhaft den Ladekreis.
@MainActor
final class ChangeObservation {
    private let task: Task<Void, Never>

    init(_ changes: DataChanges, onChange: @escaping @MainActor () -> Void) {
        // Sofort anmelden, damit keine Änderung zwischen Lesen und Anmelden verloren geht
        let stream = changes.stream()
        task = Task { for await _ in stream { onChange() } }
    }

    deinit { task.cancel() }
}
