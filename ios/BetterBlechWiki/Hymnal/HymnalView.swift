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
                    Text(model.hymnal?.appendix.map { "Stammteil und Anhang \($0.name)" } ?? "Stammteil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .task { await model.observe() }
    }

    private func list(_ hymnal: Hymnal) -> some View {
        ScrollViewReader { proxy in
            List {
                if hymnal.appendix == nil {
                    NavigationLink(value: Route.egAppendix) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Landeskirche wählen")
                            Text("Dann stehen hier auch die Lieder aus ihrem Anhang.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                // Echte Abschnitte: Die Überschrift bleibt beim Scrollen oben stehen und zeigt,
                // wo man gerade ist, wie in Kontakte oder den Einstellungen.
                ForEach(hymnal.sections) { section in
                    Section {
                        ForEach(section.songs) { song in
                            NavigationLink(value: Route.fundstellen(FundstellenRoute(
                                query: .byEgMelody(song.ixUr), label: song.title, detail: "EG \(song.number)"
                            ))) {
                                SongRow(song: song)
                            }
                            .onAppear { model.songAppeared(in: section.occasion) }
                            .onDisappear { model.songDisappeared(in: section.occasion) }
                        }
                    } header: {
                        Text(section.occasion)
                    }
                    .id(section.occasion)
                }
            }
            .listStyle(.plain)
            .readableWidth()
            .toolbar {
                // Rund 40 Anlässe und 600 Lieder: Ohne Sprungmöglichkeit wäre „Abend“ weit unten
                ToolbarItem(placement: .topBarTrailing) {
                    OccasionMenu(sections: hymnal.sections, current: model.currentOccasion) { occasion in
                        proxy.scrollTo(occasion, anchor: .top)
                    }
                }
            }
            #if DEBUG
            // Für Screenshots im Simulator: BBW_JUMP = Anlass, zu dem nach dem Öffnen gesprungen wird
            .task {
                guard let occasion = ProcessInfo.processInfo.environment["BBW_JUMP"] else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(occasion, anchor: .top)
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
            Label("Anlass", systemImage: "list.bullet")
        }
        .accessibilityLabel("Anlass wählen")
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
    @ScaledMetric private var numberWidth: CGFloat = 48

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(song.number))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.brand)
                .frame(width: numberWidth, alignment: .leading)
            Text(song.title)
        }
        .accessibilityElement(children: .combine)
    }
}
