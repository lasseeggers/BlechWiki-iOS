import BlechWikiCore
import notify
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Einstieg der Share Extension "Inventar übernehmen". Eine Nachricht mit Inventar-Code wird
/// per Teilen an BlechWiki geschickt, wie auf Android. Die Extension darf die App nicht
/// öffnen, deshalb übernimmt sie das Inventar selbst. Die Bücher lädt die App beim nächsten Öffnen.
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareImportModel(
            complete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            cancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: ShareImportView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        // Wischen nach unten schließt nicht still, sondern landet in
        // `presentationControllerDidAttemptToDismiss` und bricht dort sauber ab
        isModalInPresentation = true

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { model.load(await Self.sharedText(providers)) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Erst jetzt gibt es den Presentation Controller. Fehlt er, bleibt das Blatt per Wischen
        // gesperrt, und „Abbrechen“ schließt.
        presentationController?.delegate = self
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        cancel()
    }

    /// Meldet der teilenden App einen Abbruch statt einer erledigten Übernahme.
    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    /// Größte Textdatei, die gelesen wird. Ein Inventar-Code hat wenige hundert Zeichen.
    private static let maxFileBytes = 64 * 1024

    /// Text aus allen Anhängen. Messenger schicken Nachrichten als Text, manche zusätzlich als URL.
    /// Eine Textdatei aus „Dateien“ kommt als Datei-URL, dann zählt ihr Inhalt.
    private static func sharedText(_ providers: [NSItemProvider]) async -> String {
        var parts: [String] = []
        var readFiles = Set<URL>()
        for provider in providers {
            for type in [UTType.plainText, UTType.url] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) {
                    switch item {
                    case let text as String: parts.append(text)
                    case let url as URL where url.isFileURL:
                        // Dieselbe Datei kommt als Text und als URL, nur einmal lesen
                        if readFiles.insert(url.standardizedFileURL).inserted, let text = fileText(url) { parts.append(text) }
                    case let url as URL: parts.append(url.absoluteString)
                    case let data as Data: parts.append(String(decoding: data, as: UTF8.self))
                    default: break
                    }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Anfang einer geteilten Textdatei, höchstens `maxFileBytes`.
    private static func fileText(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
@Observable
final class ShareImportModel {

    enum State {
        case loading
        /// Die App wurde noch nie geöffnet, es gibt kein Bücherverzeichnis.
        case noCatalog
        case result(InventoryImport)
    }

    private(set) var state = State.loading
    private(set) var ownedCount = 0
    var replaceInventory = false
    private var repository: MyBooksRepository?
    private let complete: () -> Void
    private let onCancel: () -> Void

    init(complete: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.complete = complete
        self.onCancel = cancel
    }

    func load(_ text: String) {
        do {
            let defaults = SharedStorage.defaults()
            let changes = DataChanges()
            let db = try AppDatabase(url: SharedStorage.databaseURL(), changes: changes)
            let repository = MyBooksRepository(db: db, preferences: UserPreferences(defaults: defaults, changes: changes))
            self.repository = repository
            ownedCount = repository.ownedBookIds.count
            if try repository.books().isEmpty {
                state = .noCatalog
            } else {
                state = .result(try repository.inventoryImport(text))
            }
        } catch {
            state = .noCatalog
        }
    }

    func confirm() {
        guard case let .result(.ready(books, _)) = state else { return }
        repository?.importInventory(books.map(\.id), replace: replaceInventory)
        // Läuft die App gerade (iPad in Split View), lädt sie die Bücher sofort
        notify_post(SharedStorage.inventoryImportedNotification)
        complete()
    }

    func cancel() {
        onCancel()
    }
}

struct ShareImportView: View {
    @Bindable var model: ShareImportModel

    private static let previewTitles = 5

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .noCatalog:
                    Text("Öffne BlechWiki einmal, damit das Bücherverzeichnis geladen wird. Danach kannst du den Code hier übernehmen.")
                case .result(.noCode):
                    Text("In der geteilten Nachricht steht kein Inventar-Code. Er beginnt mit BW2 oder BBW.")
                case .result(.invalid):
                    Text("Der Code ist unvollständig oder verändert. Bitte die Nachricht noch einmal teilen.")
                case let .result(.ready(books, unknown)):
                    readyContent(books: books, unknown: unknown)
                }
            }
            .navigationTitle("Inventar übernehmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.replaceInventory ? "Ersetzen" : "Übernehmen") { model.confirm() }
                        .disabled(!canConfirm)
                }
            }
        }
        .tint(Color(uiColor: brandColor))
    }

    @ViewBuilder
    private func readyContent(books: [BookItem], unknown: Int) -> some View {
        if !books.isEmpty {
            Section {
                ForEach(books.prefix(Self.previewTitles)) { Text($0.title) }
                if books.count > Self.previewTitles {
                    Text("und \(books.count - Self.previewTitles) weitere").foregroundStyle(.secondary)
                }
            } header: {
                Text(recognizedTitle(books))
            } footer: {
                Text("Der Inhalt der Bücher wird geladen, sobald du BlechWiki öffnest.")
            }
        }
        if unknown > 0 {
            Section {
                let subject = unknown == 1 ? "1 Buch ist" : "\(unknown) Bücher sind"
                Text("\(subject) noch nicht im Verzeichnis auf diesem \(Self.deviceName). Öffne BlechWiki und wähle im Inventar „Inventar-Code einfügen“. Dann sucht die App bei BlechWiki nach neuen Büchern.")
                    .font(.subheadline)
            }
        }
        if !books.isEmpty && model.ownedCount > 0 {
            Section {
                Toggle("Bisheriges Inventar (\(model.ownedCount == 1 ? "1 Buch" : "\(model.ownedCount) Bücher")) ersetzen", isOn: $model.replaceInventory)
            }
        }
    }

    private var canConfirm: Bool {
        if case let .result(.ready(books, _)) = model.state { return !books.isEmpty }
        return false
    }

    /// Wie `deviceName` in der App, die Extension hat deren Dateien nicht.
    private static var deviceName: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: "iPad"
        case .mac: "Mac"
        default: "iPhone"
        }
    }

    private func recognizedTitle(_ books: [BookItem]) -> String {
        let count = books.count == 1 ? "1 Buch" : "\(books.count) Bücher"
        let alreadyOwned = books.filter(\.isOwned).count
        let suffix = switch alreadyOwned {
        case 0: ""
        case books.count: ", alle schon im Inventar"
        default: ", \(alreadyOwned) davon schon im Inventar"
        }
        return "\(count) erkannt\(suffix)"
    }
}

/// Markenfarbe wie `Color.brand` in der App, im Dark Mode der helle Ton. Die Extension hat deren
/// Dateien nicht. `nonisolated`: UIKit löst dynamische Farben auch außerhalb des Main Threads auf.
nonisolated private let brandColor = UIColor { @Sendable traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0xAB / 255, green: 0xC7 / 255, blue: 0xFF / 255, alpha: 1)
        : UIColor(red: 0x00 / 255, green: 0x36 / 255, blue: 0x73 / 255, alpha: 1)
}
