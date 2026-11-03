import BlechWikiCore
import SwiftUI

extension Color {
    /// Hintergrund der Einführung, wie auf den App-Store-Bildern (Figma-Variable „Primary“). Auch im
    /// Dark Mode, die Schrift darauf ist immer hell.
    static let onboardingBackground = Color(light: 0x182540, dark: 0x182540)
    /// Gold aus dem Logo (Figma-Variable „Secondary“) für Kategorie, Seitenpunkte und Hauptknopf.
    static let onboardingAccent = Color(light: 0xDDA72A, dark: 0xDDA72A)
    /// Schrift auf Gold. Weiß hätte dort nur ~2,2:1 Kontrast, diese ~7,8:1.
    static let onboardingOnAccent = Color(light: 0x261900, dark: 0x261900)
}

/// Einführung beim ersten Start in zwei Teilen. Erst eine Tour über vier Seiten zu den Funktionen, zum
/// Wischen, im Aufbau der App-Store-Bilder: Kategorie in Gold, Überschrift, kurzer Text, darunter ein
/// Screenshot im Gerät. Dann die Einrichtung mit Landeskirche und ersten Büchern fürs Inventar. Die
/// steht bewusst im normalen Stil der App und wird wie eine Seite geöffnet: Hier ist nichts mehr zum
/// Anschauen, hier wird etwas eingestellt.
struct OnboardingView: View {

    let container: AppContainer
    /// Aus den App-Informationen geöffnet: „Schließen“ auf jeder Seite. Beim ersten Start gibt es nur „Überspringen“.
    let onClose: (() -> Void)?
    let onFinish: () -> Void
    @State private var box = ModelBox<OnboardingModel>()
    /// Seite der Tour
    @State private var page: Int
    /// Geöffnete Schritte der Einrichtung
    @State private var path: [SetupStep]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var features: [Feature] {
        [
            Feature(
                kicker: "Suche",
                title: "Lied, EG-Nummer, Buch oder Komponist",
                text: "Wortanfänge reichen: „lob herr“ findet „Lobe den Herren“. Die Suche läuft auf dem \(deviceName), auch ohne Internet.",
                image: "onboarding-suche"
            ),
            Feature(
                kicker: "Suchergebnisse",
                title: "In welchem Heft steht das Stück?",
                text: "Alle Bücher mit Nummer, Bearbeiter, Besetzung und Vorzeichen. Hefte aus eurem Notenschrank stehen oben.",
                image: "onboarding-suchergebnisse"
            ),
            Feature(
                kicker: "Inventar",
                title: "Euer Notenschrank in der App",
                text: "Hefte abhaken, offline speichern und die Liste per Code mit dem ganzen Chor teilen.",
                image: "onboarding-inventar"
            ),
            Feature(
                kicker: "Gesangbuch",
                title: "Alle EG-Lieder nach Anlass",
                text: "Stammteil und Anhang deiner Landeskirche, von Advent bis Abend. Ein Tipp auf ein Lied zeigt, in welchen Heften es steht.",
                image: "onboarding-gesangbuch"
            ),
        ]
    }

    private static let lastTourPage = 3

    /// `page`: erste Seite, außer für Screenshots immer 0. 4 und 5 öffnen die Schritte der Einrichtung.
    init(container: AppContainer, page: Int = 0, onClose: (() -> Void)? = nil, onFinish: @escaping () -> Void) {
        self.container = container
        self.onClose = onClose
        self.onFinish = onFinish
        _page = State(initialValue: min(page, Self.lastTourPage))
        _path = State(initialValue: Array([SetupStep.appendix, .books].prefix(max(0, page - Self.lastTourPage))))
    }

    private var model: OnboardingModel {
        box { OnboardingModel(container: container) }
    }

    var body: some View {
        let model = model
        NavigationStack(path: $path) {
            tour(model)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SetupStep.self) { step in
                    switch step {
                    case .appendix:
                        AppendixSetup(model: model, onClose: onClose) { path.append(.books) }
                    case .books:
                        BooksSetup(model: model, onClose: onClose) {
                            model.finish()
                            onFinish()
                        }
                    }
                }
        }
        .task { await model.observe() }
    }

    private func tour(_ model: OnboardingModel) -> some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $page) {
                ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                    FeaturePage(feature: feature).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            bottomBar(model)
        }
        // iPad und Mac: Spalte in Lesebreite, der Hintergrund reicht über das ganze Fenster
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color.onboardingBackground.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            if let onClose {
                Button("Schließen", action: onClose)
                    .foregroundStyle(.white.opacity(0.8))
                    .buttonStyle(.borderless)
            }
            Spacer()
            if page < Self.lastTourPage {
                Button("Überspringen", action: startSetup)
                    .foregroundStyle(.white.opacity(0.8))
                    .buttonStyle(.borderless)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
    }

    private func bottomBar(_ model: OnboardingModel) -> some View {
        VStack(spacing: 14) {
            PageDots(count: Self.features.count, current: page)
            LoadStatus(state: model.dataState, offline: model.offline, onRetry: model.retry)
            Button {
                if page < Self.lastTourPage {
                    if reduceMotion { page += 1 } else { withAnimation { page += 1 } }
                } else {
                    startSetup()
                }
            } label: {
                Text(page < Self.lastTourPage ? "Weiter" : "Einrichten")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Capsule())
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func startSetup() {
        path = [.appendix]
    }
}

private enum SetupStep: Hashable {
    case appendix, books
}

private struct Feature {
    let kicker: String
    let title: String
    let text: String
    /// Screenshot im Asset-Katalog, 828 Pixel breit.
    let image: String
}

private struct FeaturePage: View {
    let feature: Feature
    /// iPad: Das Gerät darf größer sein, sonst bliebe darunter viel leerer Platz.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Quer: Text links, Gerät rechts. Untereinander bliebe für das Gerät kein Platz.
                HStack(alignment: .top, spacing: 24) {
                    ScrollView {
                        PageHeader(kicker: feature.kicker, title: feature.title, text: feature.text)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    PhoneFrame(image: feature.image)
                        .frame(width: min(geo.size.width * 0.4, 240))
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 24) {
                    PageHeader(kicker: feature.kicker, title: feature.title, text: feature.text)
                        .padding(.horizontal, 24)
                    PhoneFrame(image: feature.image)
                        .frame(maxWidth: sizeClass == .regular ? 400 : 280)
                        .padding(.horizontal, 48)
                }
                .padding(.top, 8)
            }
        }
    }
}

/// Kategorie, Überschrift und Text, wie oben auf den App-Store-Bildern.
private struct PageHeader: View {
    let kicker: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(1)
                .foregroundStyle(Color.onboardingAccent)
            Text(title)
                .font(.title.bold())
                .foregroundStyle(.white)
            Text(text)
                .foregroundStyle(.white.opacity(0.8))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Screenshot in einem schlichten Gerät. Reicht der Platz nicht, endet das Gerät unten gerade und
/// läuft in den Hintergrund aus, wie auf den App-Store-Bildern.
private struct PhoneFrame: View {
    let image: String
    /// Seitenverhältnis der Screenshots (iPhone 18 Pro, 1206 × 2622)
    private static let aspect: CGFloat = 2622 / 1206

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let bezel = width * 0.035
            let radius = width * 0.15
            let screenWidth = width - 2 * bezel
            let fullHeight = screenWidth * Self.aspect + 2 * bezel
            let cut = fullHeight > geo.size.height
            let outer = UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: cut ? 0 : radius,
                bottomTrailingRadius: cut ? 0 : radius,
                topTrailingRadius: radius,
                style: .continuous
            )
            // Feste Größe, damit das Bild die Breite füllt. Unten schneidet `outer` ab.
            Image(image)
                .resizable()
                .frame(width: screenWidth, height: screenWidth * Self.aspect)
                .clipShape(RoundedRectangle(cornerRadius: radius - bezel, style: .continuous))
                .padding(bezel)
                .frame(width: width, height: min(fullHeight, geo.size.height), alignment: .top)
                .background(Color.black, in: outer)
                .clipShape(outer)
                .overlay { outer.strokeBorder(.white.opacity(0.15), lineWidth: 1) }
                .overlay(alignment: .bottom) {
                    if cut {
                        LinearGradient(colors: [.clear, .onboardingBackground], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                }
        }
        // Nur Schmuck, der Text darüber sagt dasselbe
        .accessibilityHidden(true)
    }
}

/// Schritt 1 der Einrichtung. Wie die übrigen Seiten der App, nicht wie die Tour davor.
private struct AppendixSetup: View {
    let model: OnboardingModel
    let onClose: (() -> Void)?
    let onNext: () -> Void

    var body: some View {
        List {
            SetupIntro(
                step: 1,
                text: "Davon hängt ab, welche Nummern aus den EG-Anhängen erscheinen und welche Hefte wir dir im nächsten Schritt vorschlagen. Ändern lässt sich das später auf der Startseite."
            )
            Section {
                ForEach(model.appendices) { appendix in
                    let selected = appendix.code == model.selectedAppendix?.code
                    Button {
                        model.selectAppendix(appendix.code)
                    } label: {
                        HStack {
                            Text(appendix.name).foregroundStyle(Color.primary)
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
        }
        .setupPage(title: "Landeskirche", onClose: onClose) {
            SetupButton(title: model.selectedAppendix == nil ? "Ohne Landeskirche weiter" : "Weiter", action: onNext)
        }
    }
}

/// Schritt 2 der Einrichtung: erste Bücher fürs Inventar.
private struct BooksSetup: View {
    let model: OnboardingModel
    let onClose: (() -> Void)?
    let onFinish: () -> Void

    var body: some View {
        List {
            SetupIntro(
                step: 2,
                text: "Hake an, welche Hefte in eurem Notenschrank stehen. Ihr Inhalt wird im Hintergrund geladen und steht danach auch ohne Internet zur Verfügung."
            )
            if let sections = model.sections {
                if let appendix = model.selectedAppendix, !sections.suggested.isEmpty {
                    Section(header: sectionHeader("Vorschläge für \(appendix.name)")) { rows(sections.suggested) }
                }
                if !sections.choralBooks.isEmpty {
                    Section(header: sectionHeader("Choralbücher")) { rows(sections.choralBooks) }
                }
                Section {
                } footer: {
                    Text("Alle \(sections.all.count) Bücher findest du später im Inventar. Dort lässt sich auch ein Inventar-Code aus dem Chor übernehmen.")
                }
            } else if model.dataState == .failed {
                Section {
                    WarningLabel("Die Bücherliste konnte nicht geladen werden. Entweder fehlt die Internetverbindung, oder blechwiki.de ist gerade nicht erreichbar. Die Hefte lassen sich auch später im Inventar eintragen.")
                    Button("Erneut versuchen", action: model.retry)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Bücherliste wird geladen, einmalig ca. 2 MB …")
                    }
                }
            }
        }
        .setupPage(title: "Inventar", onClose: onClose) {
            SetupButton(title: "Fertig", action: onFinish)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand).textCase(nil)
    }

    private func rows(_ books: [BookItem]) -> some View {
        ForEach(books) { book in
            Button {
                model.toggle(book)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: book.isOwned ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(book.isOwned ? Color.brand : Color.secondary)
                    BookCover(url: book.coverUrl, width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).foregroundStyle(Color.primary).lineLimit(2)
                        if !book.details.isEmpty {
                            // Color.secondary: `.secondary` hieße im Knopf die Markenfarbe, abgeschwächt
                            Text(book.details).font(.subheadline).foregroundStyle(Color.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
            .accessibilityAddTraits(book.isOwned ? .isSelected : [])
        }
    }
}

/// „Schritt 1 von 2“ und Erklärung über der Liste, ohne Kartenhintergrund.
private struct SetupIntro: View {
    let step: Int
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schritt \(step) von 2").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
    }
}

/// Hauptknopf unten in der Einrichtung, in der Markenfarbe statt im Gold der Tour.
private struct SetupButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                // Im Dark Mode ist die Markenfarbe hell, Weiß darauf wäre kaum lesbar
                .foregroundStyle(Color(light: 0xFFFFFF, dark: 0x002F66))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Color.brand)
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

extension View {
    /// Rahmen der Einrichtungsseiten: Titel, „Schließen“ beim erneuten Ansehen, Knopf unten.
    fileprivate func setupPage(title: String, onClose: (() -> Void)?, @ViewBuilder button: () -> some View) -> some View {
        modifier(SetupPage(title: title, onClose: onClose, button: button()))
    }
}

private struct SetupPage<Button: View>: ViewModifier {
    let title: String
    let onClose: (() -> Void)?
    let button: Button
    /// iPad und Mac: Der große Titel stünde am linken Rand, die Liste in Lesebreite in der Mitte.
    /// Dort deshalb klein in der Mitte der Leiste.
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .readableWidth()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) { SwiftUI.Button("Schließen", action: onClose) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { button }
    }
}

/// Stand des Verzeichnisses, das im Hintergrund lädt.
private struct LoadStatus: View {
    let state: InitialLoad
    let offline: OfflineStatus
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Liederverzeichnis lädt, einmalig ca. 2 MB")
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                    Text("Liederverzeichnis nicht geladen.")
                    Button("Erneut versuchen", action: onRetry)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.onboardingAccent)
                }
            case .ready:
                Label(readyText, systemImage: "checkmark.circle.fill")
            }
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .frame(minHeight: 36)
    }
}

extension LoadStatus {
    fileprivate var readyText: String {
        if offline.owned == 0 { return "Liederverzeichnis geladen, Suche geht auch offline" }
        if offline.available < offline.owned { return "\(booksLabel(offline.owned)) im Inventar, Inhalt lädt" }
        return "\(booksLabel(offline.owned)) im Inventar, alle offline verfügbar"
    }
}

/// Seitenpunkte der Tour. Der aktuelle ist ein goldener Strich.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.onboardingAccent : .white.opacity(0.35))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.default, value: current)
        .accessibilityElement()
        .accessibilityLabel("Seite \(current + 1) von \(count)")
    }
}

private struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.onboardingOnAccent)
            .background(Color.onboardingAccent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}
