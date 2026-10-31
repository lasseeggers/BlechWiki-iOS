import BlechWikiCore
import SwiftUI

/// Aktualisierung, Impressum, Datenschutz und Version. Erreichbar über die Startseite.
struct AppInfoView: View {
    let container: AppContainer
    @State private var lastCheckedAt: Date?

    // Liegen im öffentlichen Repo, damit sie ohne eigene Website erreichbar sind
    static let impressumURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/blob/main/docs/IMPRESSUM.md")!
    static let privacyURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/blob/main/docs/DATENSCHUTZ.md")!

    var body: some View {
        List {
            // Beantwortet die naheliegende Frage, ob "Offline" heißt, dass nichts mehr nachkommt
            Section {
                Text("Die Daten kommen von blechwiki.de. Beim Öffnen fragt die App höchstens einmal am Tag nach neuen und korrigierten Büchern, Liedern und Komponisten. Geladen wird nur, was sich geändert hat, einmal im Monat im WLAN zur Sicherheit alles. Ohne Internet bleibt der letzte Stand nutzbar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LabeledContent("Zuletzt geprüft", value: lastCheckedAt?.formatted(standFormat) ?? "noch nie")
            } header: {
                header("Aktualisierung")
            }

            Section {
                link("Impressum", Self.impressumURL)
                link("Datenschutzerklärung", Self.privacyURL)
            } header: {
                header("Rechtliches")
            }

            Section {
                LabeledContent("Version", value: Self.version)
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("App-Informationen")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            lastCheckedAt = try? container.settings.lastCheckedAt()
            for await _ in container.changes.stream() {
                lastCheckedAt = try? container.settings.lastCheckedAt()
            }
        }
    }

    /// "0.6.1 (Build 48)"
    static var version: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) (Build \(build))"
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary).imageScale(.small)
            }
        }
    }
}
