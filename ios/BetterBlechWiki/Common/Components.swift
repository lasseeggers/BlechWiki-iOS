import BlechWikiCore
import SwiftUI

extension Color {
    /// Markenfarbe aus dem Logo (Navy), im Dark Mode ein heller Ton derselben Farbe.
    static let brand = Color(light: 0x003673, dark: 0xABC7FF)
    /// Hintergrund und Schrift der Besetzungs- und Vorzeichen-Etiketten (Gold aus dem Logo).
    static let tagBackground = Color(uiColor: .tagBackground)
    static let tagForeground = Color(uiColor: .tagForeground)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor(light: light, dark: dark))
    }
}

extension UIColor {
    /// Grundlage für `Color.tagBackground` und `Color.tagForeground`.
    static let tagBackground = UIColor(light: 0xFFDEA5, dark: 0x5D4200)
    static let tagForeground = UIColor(light: 0x261900, dark: 0xFFDEA5)

    /// `nonisolated` und `@Sendable`: UIKit und SwiftUI lösen dynamische Farben auch außerhalb des
    /// Main Threads auf. Mit der Standard-Isolation MainActor prüfte Swift das zur Laufzeit und
    /// beendete die App.
    nonisolated convenience init(light: UInt32, dark: UInt32) {
        self.init { @Sendable traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// Öffnet eine Seite im `NavigationStack`. Für Knöpfe in Listenzeilen: Ein `NavigationLink`
/// dort machte die ganze Zeile zum Link.
struct OpenRouteAction: Equatable {
    let open: (Route) -> Void

    func callAsFunction(_ route: Route) { open(route) }

    // Hängt immer an denselben Pfad an. Ohne Vergleich zeichnete jede Pfadänderung alle Leser neu.
    static func == (lhs: OpenRouteAction, rhs: OpenRouteAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
}

/// Model einer Seite, einmal pro Seite angelegt. SwiftUI erzeugt Views bei jedem Neuzeichnen der
/// Elternansicht neu. Mit `State(initialValue: Model(...))` entstand dabei jedes Mal ein Model samt
/// Datenbankabfragen im `init`, das SwiftUI gleich wieder verwarf. Die Box kostet beim Erzeugen
/// nichts. Das Model entsteht beim ersten Zeichnen, die Seite hat also sofort Inhalt.
@MainActor
final class ModelBox<Model: AnyObject> {
    private var model: Model?

    func callAsFunction(_ make: () -> Model) -> Model {
        if let model { return model }
        let new = make()
        model = new
        return new
    }
}

/// Filter- oder Auswahl-Chip, ausgewählt mit Häkchen.
struct Chip: View {
    let label: String
    let systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark").imageScale(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(label)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.tagForeground : Color.primary)
            .background(selected ? Color.tagBackground : Color(.secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Color(.separator)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lesezeichen, nimmt ein Buch ins Inventar auf oder entfernt es.
struct BookmarkToggle: View {
    let isOwned: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isOwned ? "bookmark.fill" : "bookmark")
                .foregroundStyle(isOwned ? Color.brand : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isOwned ? "Aus dem Inventar entfernen" : "Zum Inventar hinzufügen")
    }
}

/// Cover in Listengröße. Geladen wird die schärfere mittlere Größe, bei Fehler die API-Variante.
struct BookCover: View {
    let url: String?
    var width: CGFloat = 40

    var body: some View {
        CoverImage(preferred: CoverUrls.thumbnail(url), fallback: CoverUrls.api(url), width: width)
    }
}

/// Großes Cover für den Buchkopf, Original mit Rückfall auf die mittlere Größe.
struct LargeBookCover: View {
    let url: String?
    let width: CGFloat

    var body: some View {
        CoverImage(preferred: CoverUrls.full(url), fallback: CoverUrls.thumbnail(url), width: width)
    }
}

private struct CoverImage: View {
    let preferred: URL?
    let fallback: URL?
    let width: CGFloat
    @State private var image: UIImage?

    init(preferred: URL?, fallback: URL?, width: CGFloat) {
        self.preferred = preferred
        self.fallback = fallback
        self.width = width
        // Aus dem Speicher sofort zeigen. Erst in `.task` stünde beim Scrollen kurz ein graues Kästchen da.
        let size = CoverLoader.pixelSize(height: width * 1.4)
        _image = State(initialValue: [preferred, fallback].lazy.compactMap { $0 }.compactMap { CoverLoader.cached($0, maxPixelSize: size) }.first)
    }

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: width, height: width * 1.4)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            .task(id: preferred) {
                // Die größeren Varianten sind nicht dokumentiert, daher bei Ladefehler die zweite URL
                image = await loadCover([preferred, fallback], maxPixelSize: CoverLoader.pixelSize(height: width * 1.4))
            }
    }
}

/// Erstes Cover aus `urls`, das sich laden lässt.
private func loadCover(_ urls: [URL?], maxPixelSize: Int) async -> UIImage? {
    for url in urls.compactMap({ $0 }) {
        if let image = try? await CoverLoader.load(url, maxPixelSize: maxPixelSize) { return image }
    }
    return nil
}

/// Cover über den ganzen Bildschirm. Schließt wie in der Fotos-App per Wischen nach unten
/// oder oben, per Tipp oder über den Schließen-Knopf. Als `fullScreenCover` zeigen.
///
/// Beim Wischen fliegt das Cover in Wischrichtung mit dem Tempo des Fingers hinaus, erst danach
/// wird die Ansicht ohne eigene Animation geschlossen. Die Standard-Animation von
/// `fullScreenCover` liefe immer nach unten und begänne bei Tempo null.
struct CoverViewer: View {
    let url: String?
    /// Buchtitel für VoiceOver.
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failed = false
    @State private var drag: CGSize = .zero
    @State private var isClosing = false

    /// Strecke bzw. vorhergesagte Endstrecke, ab der Loslassen schließt.
    private static let dismissDistance: CGFloat = 120
    private static let dismissPredicted: CGFloat = 320

    var body: some View {
        GeometryReader { geometry in
            let progress = min(abs(drag.height) / 400, 1)
            ZStack {
                // Blendet beim Ziehen aus, damit die Seite darunter durchscheint
                Color.black.opacity(isClosing ? 0 : 1 - progress * 0.8).ignoresSafeArea()
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(title.map { "Cover von \($0)" } ?? "Cover")
                    } else if failed {
                        Text("Cover nicht verfügbar").foregroundStyle(.white)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .padding()
                .scaleEffect(1 - progress * 0.25)
                .offset(drag)
            }
            .overlay(alignment: .topTrailing) {
                Button("Schließen", systemImage: "xmark") { dismiss() }
                    // Esc auf Mac und iPad mit Tastatur
                    .keyboardShortcut(.cancelAction)
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
                    .padding()
                    .opacity(isClosing ? 0 : 1 - progress)
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isClosing { drag = value.translation }
                    }
                    .onEnded { value in
                        guard !isClosing else { return }
                        if abs(value.translation.height) > Self.dismissDistance
                            || abs(value.predictedEndTranslation.height) > Self.dismissPredicted {
                            flyOut(value, height: geometry.size.height)
                        } else {
                            // Zurückfedern mit dem Tempo des Fingers, ohne Überschwingen
                            let velocity = relativeVelocity(value.velocity.height, from: drag.height, to: 0)
                            withAnimation(.interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: velocity)) {
                                drag = .zero
                            }
                        }
                    }
            )
        }
        .presentationBackground(.clear)
        .statusBarHidden()
        .task {
            image = await loadCover([CoverUrls.full(url), CoverUrls.thumbnail(url)], maxPixelSize: CoverLoader.fullScreenPixelSize)
            failed = image == nil
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private func flyOut(_ value: DragGesture.Value, height: CGFloat) {
        if reduceMotion {
            dismiss()
            return
        }
        // Richtung aus dem Schwung, nicht aus der Position: Wer nach unten zieht und nach oben
        // schnippt, will nach oben
        let projected = value.predictedEndTranslation
        let direction: CGFloat = (abs(projected.height) > 1 ? projected.height : value.translation.height) < 0 ? -1 : 1
        let target = CGSize(width: projected.width, height: direction * (height + 100))
        let velocity = max(0, relativeVelocity(value.velocity.height, from: drag.height, to: target.height))
        isClosing = true
        withAnimation(.interpolatingSpring(duration: 0.35, bounce: 0, initialVelocity: velocity)) {
            drag = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    /// Fingertempo als Anteil der verbleibenden Strecke pro Sekunde, wie `interpolatingSpring` es erwartet.
    private func relativeVelocity(_ velocity: CGFloat, from current: CGFloat, to target: CGFloat) -> CGFloat {
        let distance = target - current
        return abs(distance) < 1 ? 0 : velocity / distance
    }
}

/// Auswahl der Landeskirche als eigene Seite. Bewusst kein `Picker` mit `.navigationLink`-Stil:
/// Der navigiert an `NavigationStack(path:)` vorbei und bleibt nach der Auswahl offen stehen.
struct EgAppendixSelectionView: View {
    let settings: SettingsRepository
    @Environment(\.dismiss) private var dismiss
    /// Eigener Stand für das Häkchen: Steht die Seite rechts neben der Suche, schließt `dismiss` sie
    /// nicht, und das Häkchen muss trotzdem wandern.
    @State private var selected: String?

    init(settings: SettingsRepository) {
        self.settings = settings
        _selected = State(initialValue: (try? settings.selectedEgAppendix())?.code)
    }

    var body: some View {
        let appendices = (try? settings.egAppendices()) ?? []
        List {
            Section {
                option("Keine Angabe", code: nil, selected: selected == nil)
                ForEach(appendices) { appendix in
                    option(appendix.name, code: appendix.code, selected: appendix.code == selected)
                }
            } footer: {
                Text("Bestimmt, welche Nummern aus den EG-Anhängen angezeigt werden, und welche Hefte wir dir vorschlagen.")
            }
        }
        .readableWidth()
        .navigationTitle("Landeskirche")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ label: String, code: String?, selected: Bool) -> some View {
        Button {
            settings.selectEgAppendix(code)
            self.selected = code
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(Color.primary)
                Spacer()
                if selected {
                    // Vorgelesen wird die Auswahl über .isSelected
                    Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "iPhone", "iPad" oder "Mac", für Texte wie „Die Suche läuft auf dem iPhone“.
var deviceName: String {
    switch UIDevice.current.userInterfaceIdiom {
    case .pad: "iPad"
    case .mac: "Mac"
    default: "iPhone"
    }
}

/// "1 Buch", "12 Bücher"
func booksLabel(_ count: Int) -> String { count == 1 ? "1 Buch" : "\(count) Bücher" }

/// "01.11.2026", wie in der Android-App. Die Texte sind deutsch, das Datum folgt nicht der Region des Geräts.
let standFormat: Date.FormatStyle = .dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "de_DE"))

extension View {
    /// Auf dem Mac haben Listenzeilen oben und unten kaum Abstand, Cover und Text kleben dann an
    /// Trennlinie und Kartenrand. iPhone und iPad bringen den Abstand selbst mit.
    @ViewBuilder
    func macRowPadding(_ value: CGFloat = 8) -> some View {
        #if targetEnvironment(macCatalyst)
        padding(.vertical, value)
        #else
        self
        #endif
    }

    /// Handzeiger über Text-Links auf dem Mac. SwiftUIs `pointerStyle(.link)` gibt es unter Mac
    /// Catalyst nicht, deshalb `NSCursor` von AppKit über die Objective-C-Laufzeit (öffentliche API,
    /// AppKit ist in Catalyst-Apps geladen).
    @ViewBuilder
    func linkPointer(_ enabled: Bool = true) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(LinkPointer(enabled: enabled))
        #else
        self
        #endif
    }

    /// Markenfarbe, in einer ausgewählten Zeile (Hintergrund in Markenfarbe, iPad und Mac) weiß.
    /// Sonst wäre der Inhalt dort unsichtbar.
    func brandForeground() -> some View {
        modifier(BrandForeground())
    }

    /// Hält Listen in breiten Spalten (iPad quer, Mac, aufgeklapptes iPhone Duo) auf lesbarer Breite.
    /// Der Rand kommt als Safe Area dazu: Hintergrund und Scrollen bleiben über die ganze Breite,
    /// und unter `maxWidth` ändert sich nichts.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }

    /// Suchfeld, ab iOS 26 unten als schwebendes Glasfeld in Reichweite des Daumens. Mit
    /// `minimized` steht dort nur eine Lupe, die Liste behält den Platz. Vor iOS 26 gäbe es unten
    /// nur eine normale Toolbar, dort bleibt das Feld oben unter dem Titel.
    @ViewBuilder
    func appSearchable(text: Binding<String>, prompt: LocalizedStringKey, minimized: Bool = false) -> some View {
        #if targetEnvironment(macCatalyst)
        // Der Mac hat keine Leiste unten und keinen Daumen. Das Feld steht oben in der Fensterleiste,
        // wo man es dort erwartet.
        searchable(text: text, prompt: Text(prompt))
        #else
        if #available(iOS 26, *), minimized {
            // Allein stünde die Lupe mittig über dem Inhalt, rechts unten wie in Mail
            searchable(text: text, prompt: Text(prompt))
                .searchToolbarBehavior(.minimize)
                .toolbar {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
        } else if #available(iOS 26, *) {
            searchable(text: text, prompt: Text(prompt))
        } else {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Zu `linkPointer`. Merkt sich, ob der Handzeiger gerade auf dem Stapel von `NSCursor` liegt:
/// Nach einem Klick auf einen Link öffnet sich eine neue Seite, und `onHover(false)` kommt oft
/// nicht mehr. Dann nimmt `onDisappear` den Zeiger wieder herunter.
private struct LinkPointer: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled { push() } else { pop() }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled { pop() }
            }
            .onDisappear { pop() }
    }

    private static var cursorClass: NSObject.Type? { NSClassFromString("NSCursor") as? NSObject.Type }

    private func push() {
        guard !pushed, let cursor = Self.cursorClass else { return }
        (cursor.value(forKey: "pointingHandCursor") as? NSObject)?.perform(NSSelectorFromString("push"))
        pushed = true
    }

    private func pop() {
        guard pushed, let cursor = Self.cursorClass else { return }
        cursor.perform(NSSelectorFromString("pop"))
        pushed = false
    }
}
#endif

private struct BrandForeground: ViewModifier {
    /// `.increased`, wenn die Zeile ausgewählt ist und in der Markenfarbe hinterlegt wird.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white : Color.brand)
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.horizontal, margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                margin = max(0, (width - maxWidth) / 2)
            }
    }
}
