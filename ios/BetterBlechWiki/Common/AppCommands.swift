import BlechWikiCore
import SwiftUI
import UIKit

/// Navigation im vorderen Fenster, für „Gehe zu“ in der Menüleiste. Setzt `RootView`.
struct WindowNavigation {
    let select: (Route) -> Void
    /// `nil`: rechts liegt keine Seite, zu der es zurückgeht.
    let back: (() -> Void)?
    let sidebarVisible: Bool
    let toggleSidebar: () -> Void
    /// Einführung, wie „Hilfe“ auf der Startseite.
    let showHelp: () -> Void
}

/// Befehle der Seite, die gerade rechts steht. Jede Seite setzt nur, was sie kann, der Rest bleibt
/// im Menü ausgegraut. Ausblenden statt Ausgrauen ließe die Menüs je nach Seite springen.
struct PageCommands {
    var refresh: (() -> Void)?
    /// Einstellungen: „Alle Daten neu laden“ mit Rückfrage.
    var reloadAll: (() -> Void)?
    /// Buchansicht: ob das Buch im Inventar ist, und Umschalten.
    var bookOwned: Bool?
    var toggleBookOwned: (() -> Void)?
    var showCover: (() -> Void)?
    /// Inventar: Nachricht zum Teilen und Import-Dialog.
    var shareMessage: String?
    var importCode: (() -> Void)?
    /// Gesangbuch: Anlässe, aktueller Anlass und Sprung dorthin.
    var occasions: [String] = []
    var currentOccasion: String?
    var jumpToOccasion: ((String) -> Void)?
    /// Suchergebnisse für Titel und EG-Lieder: ob das Lied Favorit ist, Umschalten und Blatt
    /// „Zu Liste hinzufügen“.
    var isFavorite: Bool?
    var toggleFavorite: (() -> Void)?
    var addToList: (() -> Void)?
    /// Übersicht der Listen: Dialog „Neue Liste“.
    var newList: (() -> Void)?
}

extension FocusedValues {
    @Entry var windowNavigation: WindowNavigation?
    @Entry var pageCommands: PageCommands?
}

/// Menüleiste auf dem Mac und dem iPad mit Tastatur. Jeder Befehl aus Toolbar und Seiten steht auch
/// hier, sonst findet ihn auf dem Mac niemand. Ein eigenes ⌘F für das Suchfeld gibt es bewusst
/// nicht: UIKit legt „Suchen“ (find:) mit ⌘F selbst ins Menü „Bearbeiten“, SwiftUI kann es nicht
/// ersetzen, und zwei Befehle auf ⌘F wären laut UIKit undefiniert.
struct AppCommands: Commands {
    static let issuesURL = URL(string: "https://github.com/lasseeggers/BlechWiki-iOS/issues")!

    @FocusedValue(\.windowNavigation) private var navigation
    @FocusedValue(\.pageCommands) private var page
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if targetEnvironment(macCatalyst)
        CommandGroup(replacing: .appSettings) {
            Button("Einstellungen …") { openWindow(id: SettingsWindow.id, value: SettingsWindow.id) }
                .keyboardShortcut(",")
        }
        #endif

        // Menü „Darstellung“
        CommandGroup(before: .toolbar) {
            // Catalyst bringt für `NavigationSplitView` keinen eigenen Befehl mit
            Button(navigation?.sidebarVisible == false ? "Seitenleiste einblenden" : "Seitenleiste ausblenden") {
                navigation?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(navigation == nil)
            Divider()
            Button("Aktualisieren") { page?.refresh?() }
                .keyboardShortcut("r")
                .disabled(page?.refresh == nil)
            Button("Alle Daten neu laden …") { page?.reloadAll?() }
                .disabled(page?.reloadAll == nil)
            Button("Cover anzeigen") { page?.showCover?() }
                .disabled(page?.showCover == nil)
        }

        CommandMenu("Gehe zu") {
            Button("Zurück") { navigation?.back?() }
                .keyboardShortcut("[")
                .disabled(navigation?.back == nil)
            Divider()
            Button("Inventar") { navigation?.select(.myBooks) }
                .keyboardShortcut("1")
                .disabled(navigation == nil)
            Button("Gesangbuch") { navigation?.select(.hymnal) }
                .keyboardShortcut("2")
                .disabled(navigation == nil)
            Button("Listen") { navigation?.select(.lists) }
                .keyboardShortcut("3")
                .disabled(navigation == nil)
            Button("Einstellungen") { navigation?.select(.appInfo) }
                .disabled(navigation == nil)
            Divider()
            Menu("Anlass") {
                ForEach(page?.occasions ?? [], id: \.self) { occasion in
                    Toggle(occasion, isOn: Binding(get: { occasion == page?.currentOccasion }, set: { _ in page?.jumpToOccasion?(occasion) }))
                }
            }
            .disabled(page?.jumpToOccasion == nil)
        }

        CommandMenu("Inventar") {
            Button(page?.bookOwned == true ? "Aus dem Inventar entfernen" : "Zum Inventar hinzufügen") { page?.toggleBookOwned?() }
                .keyboardShortcut("d")
                .disabled(page?.toggleBookOwned == nil)
            Divider()
            if let message = page?.shareMessage {
                ShareLink("Inventar teilen …", item: message)
            } else {
                Button("Inventar teilen …") {}.disabled(true)
            }
            Button("Inventar-Code einfügen …") { page?.importCode?() }
                .disabled(page?.importCode == nil)
        }

        CommandMenu("Listen") {
            Button(page?.isFavorite == true ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen") { page?.toggleFavorite?() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(page?.toggleFavorite == nil)
            Button("Zu Liste hinzufügen …") { page?.addToList?() }
                .disabled(page?.addToList == nil)
            Divider()
            Button("Neue Liste …") { page?.newList?() }
                .disabled(page?.newList == nil)
        }

        // Statt „Hilfe ist nicht verfügbar“
        CommandGroup(replacing: .help) {
            Button("Einführung ansehen") { navigation?.showHelp() }
                .disabled(navigation == nil)
            Button("Fehler melden") { UIApplication.shared.open(Self.issuesURL) }
            Divider()
            Button("Impressum") { UIApplication.shared.open(AppInfoView.impressumURL) }
            Button("Datenschutzerklärung") { UIApplication.shared.open(AppInfoView.privacyURL) }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Einstellungen auf dem Mac, geöffnet mit ⌘, aus dem App-Menü. Die Landeskirche ist die einzige
/// Einstellung, daher ein Fenster ohne Bereiche mit dem Titel „BlechWiki-Einstellungen“. Die Seite
/// „Einstellungen“ auf der Startseite bleibt, wie auf iPhone und Android.
struct SettingsWindow: View {
    /// Fenster-ID und zugleich einziger Wert: Ein zweites ⌘, holt das offene Fenster nach vorn,
    /// statt ein weiteres zu öffnen.
    static let id = "einstellungen"
    let settings: SettingsRepository

    var body: some View {
        EgAppendixSelectionView(settings: settings, inSettingsWindow: true)
            .background(SettingsWindowScene(title: "BlechWiki-Einstellungen", size: CGSize(width: 460, height: 560)))
    }
}

/// Setzt Titel und feste Größe des Einstellungsfensters. Bei fester Größe graut macOS den Knopf zum
/// Vergrößern aus. SwiftUI kommt unter Catalyst nicht an die `UIWindowScene`, die Ansicht schon.
private struct SettingsWindowScene: UIViewRepresentable {
    let title: String
    let size: CGSize

    func makeUIView(context: Context) -> SceneView { SceneView(title: title, size: size) }
    func updateUIView(_ uiView: SceneView, context: Context) {}

    final class SceneView: UIView {
        let title: String
        let size: CGSize

        init(title: String, size: CGSize) {
            self.title = title
            self.size = size
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            scene.title = title
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
        }
    }
}
#endif
