import BlechWikiCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Einstieg der Share Extension "Inventar übernehmen". Eine Nachricht mit Inventar-Code wird
/// per Teilen an BlechWiki geschickt, wie auf Android. Die Extension darf die App nicht
/// öffnen, deshalb übernimmt sie das Inventar selbst. Die Bücher lädt die App beim nächsten Öffnen.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareImportModel(complete: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let host = UIHostingController(rootView: ShareImportView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { model.load(await Self.sharedText(providers)) }
    }

    /// Text aus allen Anhängen. Messenger schicken Nachrichten als Text, manche zusätzlich als URL.
    private static func sharedText(_ providers: [NSItemProvider]) async -> String {
        var parts: [String] = []
        for provider in providers {
            for type in [UTType.plainText, UTType.url] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) {
                    switch item {
                    case let text as String: parts.append(text)
                    case let url as URL: parts.append(url.absoluteString)
                    case let data as Data: parts.append(String(decoding: data, as: UTF8.self))
                    default: break
                    }
                }
            }
        }
        return parts.joined(separator: "\n")
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

    init(complete: @escaping () -> Void) {
        self.complete = complete
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
        complete()
    }

    func cancel() {
        complete()
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
                    Text("In der geteilten Nachricht steht kein Inventar-Code. Er beginnt mit BBW-.")
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
        .tint(Color(red: 0x00 / 255, green: 0x36 / 255, blue: 0x73 / 255))
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
                Text("\(subject) noch nicht im Verzeichnis auf diesem iPhone. Öffne BlechWiki und füge den Code dort unter Inventar › Inventar-Code einfügen ein. Dann sucht die App bei BlechWiki nach neuen Büchern.")
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
