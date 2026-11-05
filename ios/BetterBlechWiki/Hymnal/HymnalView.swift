import BlechWikiCore
import SwiftUI

/// Gesangbuch zum Blättern: Stammteil und Anhang der gewählten Landeskirche, nach Anlass.
struct HymnalView: View {

    @State private var model: HymnalModel

    init(container: AppContainer) {
        _model = State(initialValue: HymnalModel(container: container))
    }

    var body: some View {
        Group {
            if let hymnal = model.hymnal {
                if hymnal.sections.isEmpty {
                    Text("Das Liederverzeichnis wird noch geladen.")
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(hymnal)
                }
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Gesangbuch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Gesangbuch").font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .task { await model.observe() }
    }

    private var subtitle: String {
        model.hymnal?.appendix.map { "Stammteil und Anhang \($0.name)" } ?? "Stammteil"
    }

    /// Mac: Anlässe als normale Zeilen statt als Abschnittsköpfe. Abschnittsköpfe bleiben beim Scrollen
    /// oben stehen, und unter Catalyst blieb ihr heller Hintergrund nach dem Zurückscrollen über dem
    /// Listenanfang liegen. Den aktuellen Anlass zeigt dort der Knopf in der Toolbar.
    private static let headersAsRows = UIDevice.current.userInterfaceIdiom == .mac

    private func songs(_ section: HymnalSection) -> some View {
        ForEach(section.songs) { song in
            let route = SuchergebnisseRoute(query: .byEgMelody(song.ixUr), label: song.title, detail: "EG \(song.number)", egIx: song.ix)
            NavigationLink(value: Route.suchergebnisse(route)) {
                SongRow(song: song, listRef: route.listRef)
            }
            .listEntryMenu(route.listRef)
            .onAppear { model.songAppeared(in: section.occasion) }
            .onDisappear { model.songDisappeared(in: section.occasion) }
        }
    }

    private func jump(to occasion: String, _ proxy: ScrollViewProxy) {
        model.jumped(to: occasion)
        proxy.scrollTo(occasion, anchor: .top)
    }

    private func list(_ hymnal: Hymnal) -> some View {
        ScrollViewReader { proxy in
            List {
                // Catalyst zeigt den Titel mit Unterzeile (`.principal`) nicht, dort steht die Unterzeile hier
                if UIDevice.current.userInterfaceIdiom == .mac {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                if hymnal.appendix == nil {
                    NavigationLink(value: Route.egAppendix) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Landeskirche wählen")
                            Text("Dann stehen hier auch die Lieder aus ihrem Anhang.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(hymnal.sections) { section in
                    if Self.headersAsRows {
                        Text(section.occasion)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .listRowSeparator(.hidden)
                            .id(section.occasion)
                        songs(section)
                    } else {
                        // Echte Abschnitte: Die Überschrift bleibt beim Scrollen oben stehen und zeigt,
                        // wo man gerade ist, wie in Kontakte oder den Einstellungen.
                        Section {
                            songs(section)
                        } header: {
                            Text(section.occasion)
                        }
                        .id(section.occasion)
                    }
                }
            }
            .listStyle(.plain)
            .readableWidth()
            .focusedSceneValue(\.pageCommands, PageCommands(
                occasions: hymnal.sections.map(\.occasion),
                currentOccasion: model.currentOccasion,
                jumpToOccasion: { jump(to: $0, proxy) }
            ))
            .toolbar {
                // Rund 40 Anlässe und 600 Lieder: Ohne Sprungmöglichkeit wäre „Abend“ weit unten
                ToolbarItem(placement: .topBarTrailing) {
                    OccasionMenu(sections: hymnal.sections, current: model.currentOccasion) { jump(to: $0, proxy) }
                        // Die Mac-Toolbar übernimmt einen geänderten Text im Menüknopf nicht, mit neuer
                        // ID baut SwiftUI ihn neu auf
                        .id(UIDevice.current.userInterfaceIdiom == .mac ? model.currentOccasion : nil)
                }
            }
            #if DEBUG
            // Für Screenshots im Simulator: BBW_JUMP = Anlass, zu dem nach dem Öffnen gesprungen wird
            .task {
                guard let occasion = ProcessInfo.processInfo.environment["BBW_JUMP"] else { return }
                try? await Task.sleep(for: .milliseconds(500))
                jump(to: occasion, proxy)
            }
            #endif
        }
    }
}

/// Knopf „Anlass“ in der Navigationsleiste. Das Menü listet alle Anlässe mit ihren Nummern,
/// der Anlass oben in der Liste hat einen Haken.
private struct OccasionMenu: View {
    let sections: [HymnalSection]
    let current: String?
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(sections) { section in
                // Als Schalter: Das Menü zeigt den Haken selbst, und VoiceOver liest den aktuellen
                // Anlass als ausgewählt vor. Ein Haken als Bild bliebe stumm.
                Toggle(isOn: Binding(get: { section.occasion == current }, set: { _ in onSelect(section.occasion) })) {
                    // Zweiter Text erscheint im Menü als Untertitel
                    Text(section.occasion)
                    Text(numbersLabel(section))
                }
            }
        } label: {
            if UIDevice.current.userInterfaceIdiom == .mac {
                // Auf dem Mac bleibt die Überschrift des Anlasses beim Scrollen nicht stehen, der Knopf
                // zeigt dafür, wo man gerade ist
                Text(current ?? "Anlass")
            } else {
                Label("Anlass", systemImage: "list.bullet")
            }
        }
        .accessibilityLabel("Anlass wählen")
        .accessibilityValue(current ?? "")
    }

    /// "Nr. 1–22 · 3 aus dem Anhang", für Anlässe nur im Anhang "Nr. 600–610 im Anhang".
    private func numbersLabel(_ section: HymnalSection) -> String {
        let stamm = section.songs.filter { !$0.isAppendix }.map(\.number)
        let appendix = section.songs.filter(\.isAppendix).map(\.number)
        func range(_ numbers: [Int]) -> String {
            let low = numbers.min() ?? 0, high = numbers.max() ?? 0
            return low == high ? "Nr. \(low)" : "Nr. \(low)–\(high)"
        }
        if stamm.isEmpty { return range(appendix) + " im Anhang" }
        if appendix.isEmpty { return range(stamm) }
        return range(stamm) + " · \(appendix.count) aus dem Anhang"
    }
}

private struct SongRow: View {
    let song: HymnalSong
    let listRef: ListEntryRef?
    @ScaledMetric private var numberWidth: CGFloat = 48

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(song.number))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brand)
                .frame(width: numberWidth, alignment: .leading)
            Text(song.title)
            Spacer(minLength: 0)
            if let listRef { FavoriteMark(ref: listRef) }
        }
        .accessibilityElement(children: .combine)
    }
}
