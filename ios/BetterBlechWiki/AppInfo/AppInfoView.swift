import BlechWikiCore
import SwiftUI

/// Einstellungen: Landeskirche, Aktualisierung, Impressum, Datenschutz und Version. Erreichbar über die Startseite.
struct AppInfoView: View {
    let container: AppContainer
    @State private var box = ModelBox<AppInfoModel>()
    @State private var confirmReload = false

    /// Gleicher Text wie auf Android.
    static let reloadExplanation = "Lädt alle Bücher, Lieder, Komponisten und Fundstellen neu von blechwiki.de, etwa 9 MB. Nur nötig, wenn Einträge fehlen oder falsch sind. Inventar und Landeskirche bleiben erhalten."

    // Liegen im öffentlichen Repo, damit sie ohne eigene Website erreichbar sind
    static let impressumURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/blob/main/docs/IMPRESSUM.md")!
    static let privacyURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/blob/main/docs/DATENSCHUTZ.md")!

    var body: some View {
        let model = box { AppInfoModel(container: container) }
        List {
            Section {
                NavigationLink(value: Route.egAppendix) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Landeskirche")
                        Text(model.selectedAppendix?.name ?? "Nicht gewählt · für die Nummern der EG-Anhänge")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Beantwortet die naheliegende Frage, ob "Offline" heißt, dass nichts mehr nachkommt
            Section {
                Text("Die Daten kommen von blechwiki.de. Alle Bücher und ihr Inhalt sind in der App enthalten. Beim Öffnen fragt die App höchstens einmal am Tag nach neuen und korrigierten Büchern, Liedern und Komponisten. Geladen wird nur, was sich geändert hat. Ohne Internet bleibt der letzte Stand nutzbar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Mehrzeilig klebte der Text auf dem Mac an Kartenrand und Trennlinie
                    .macRowPadding(12)
                LabeledContent("Zuletzt geprüft", value: model.lastCheckedAt?.formatted(standFormat) ?? "noch nie")
                reloadRow(model.syncStatus)
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
        .readableWidth()
        .alert("Alle Daten neu laden?", isPresented: $confirmReload) {
            Button("Neu laden") { model.reloadAll() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(Self.reloadExplanation)
        }
        .focusedSceneValue(\.pageCommands, PageCommands(reloadAll: { confirmReload = true }))
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Während des Ladens mit Ladekreis, nach einem Fehler mit Hinweis.
    private func reloadRow(_ status: SyncStatus) -> some View {
        let running = status == .running
        return Button { confirmReload = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alle Daten neu laden").foregroundStyle(Color.primary)
                    if running {
                        Text("Lädt …").font(.footnote).foregroundStyle(.secondary)
                    } else if status == .failed || status == .waiting(afterFailure: true) {
                        Text("Nicht geladen. Die App versucht es später erneut.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if running {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary).imageScale(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(running)
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
