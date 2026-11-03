import BlechWikiCore
import Foundation
import Observation

extension ComposerLink {
    /// Link im Fließtext. `SuchergebnisseView` fängt ihn per `openURL` ab und öffnet die Komponistensuche.
    var url: URL {
        var components = URLComponents()
        components.scheme = "komponist"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }
}

struct BookGroup: Identifiable {
    var bookId: String
    var bookTitle: String
    var bookSubtitle: String?
    var coverUrl: String?
    var isOwned: Bool
    var entries: [Fundstelle]
    var id: String { bookId }
}

/// Abgeleiteter Zustand nach allen Filtern.
struct SuchergebnisseContent {
    /// Bücher im Inventar zuerst, sonst in API-Reihenfolge.
    var books: [BookGroup] = []
    /// Einträge nach allen Filtern.
    var totalCount = 0
    /// Einträge ohne Filter.
    var unfilteredCount = 0
    /// Besetzungen nach Häufigkeit, für die Filter-Chips.
    var scoringOptions: [String] = []
    /// Wie viele der gefundenen Bücher im Inventar stehen.
    var ownedBookCount = 0
}

@MainActor
@Observable
final class SuchergebnisseModel {

    let route: SuchergebnisseRoute
    var bookFilter: String
    var selectedScoring: String?
    var onlyOwned = false
    /// Buchansicht: nach Titel statt nach Nummer im Heft.
    var sortByTitle = false

    private(set) var fetchedAt: Date?
    private(set) var owned: Set<String> = []
    /// Buchansicht: Stammdaten des Buchs für den Kopfbereich.
    private(set) var book: BookItem?
    /// Komponisten aus den Fundstellen nach Namen, ohne den Komponisten der Ansicht selbst.
    private(set) var composerLinks: [String: ComposerLink] = [:]
    /// Buchansicht: Herausgeber, wenn er auch als Komponist eingetragen ist.
    private(set) var editorLink: ComposerLink?
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false
    /// Der Server hat geantwortet, aber mit Fehler (HTTP-Status, unlesbare Antwort), etwa bei einem
    /// gelöschten Buch. Dann liegt es nicht an der Verbindung.
    private(set) var refreshFailedOnServer = false
    // Fundstellen mit vorab berechneten Suchwörtern, damit das Filtern beim Tippen schnell bleibt
    private var entries: [(fundstelle: Fundstelle, words: [String])] = []

    private let container: AppContainer
    @ObservationIgnored private var observation: ChangeObservation?

    init(container: AppContainer, route: SuchergebnisseRoute) {
        self.container = container
        self.route = route
        bookFilter = route.initialFilter ?? ""
        observation = ChangeObservation(container.changes) { [weak self] in self?.reload() }
        reload()
    }

    var hasLoaded: Bool { fetchedAt != nil }

    /// In der Buchansicht: ob dieses Buch im Inventar steht.
    var routeBookOwned: Bool { route.bookId.map(owned.contains) ?? false }

    var isBookFiltered: Bool { !TextFilter(bookFilter).isEmpty }

    var content: SuchergebnisseContent {
        let textFilter = TextFilter(bookFilter)
        let filtered = entries
            .filter { selectedScoring == nil || $0.fundstelle.scoring == selectedScoring }
            .filter { !onlyOwned || owned.contains($0.fundstelle.bookId) }
            .filter { textFilter.matchesWords($0.words) }
            .map(\.fundstelle)
        let groups = groupedInOrder(filtered, by: \.bookId).map { entries in
            let first = entries[0]
            return BookGroup(
                bookId: first.bookId, bookTitle: first.bookTitle, bookSubtitle: first.bookSubtitle,
                coverUrl: first.coverUrl, isOwned: owned.contains(first.bookId),
                entries: sortByTitle ? entries.sorted(by: Self.titleOrder) : entries
            )
        }
        let scoringCounts = groupedInOrder(entries.compactMap(\.fundstelle.scoring), by: { $0 })
        var seenBooks = Set<String>()
        return SuchergebnisseContent(
            books: groups.filter(\.isOwned) + groups.filter { !$0.isOwned },
            totalCount: filtered.count,
            unfilteredCount: entries.count,
            scoringOptions: scoringCounts.enumerated()
                .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                .map { $0.element[0] },
            ownedBookCount: entries.map(\.fundstelle.bookId).filter { seenBooks.insert($0).inserted && owned.contains($0) }.count
        )
    }

    /// Zeigt sofort den Cache und lädt nach, wenn nichts da oder der Eintrag veraltet ist.
    func observe() async {
        reload()
        await refresh(force: false)
    }

    /// `force` = false lädt nur, wenn nichts im Cache liegt oder er veraltet ist.
    func refresh(force: Bool = true) async {
        isRefreshing = true
        refreshFailed = false
        refreshFailedOnServer = false
        do {
            _ = try await container.sync.withBackgroundTime("Suchergebnisse") {
                try await container.fundstellen.refresh(route.query, force: force)
            }
        } catch {
            refreshFailed = true
            switch error as? BlechWikiError {
            case .httpError?, .malformedResponse?: refreshFailedOnServer = true
            default: break
            }
        }
        isRefreshing = false
    }

    func selectScoring(_ scoring: String) {
        selectedScoring = selectedScoring == scoring ? nil : scoring
    }

    func setOwned(_ bookId: String, owned: Bool) {
        container.myBooks.setOwned(bookId, owned: owned)
        if owned { container.sync.downloadOwnedBooks() }
    }

    /// Deutsche Sortierung („Ö“ bei „O“), bei gleichem Titel nach Nummer im Heft.
    private static func titleOrder(_ a: Fundstelle, _ b: Fundstelle) -> Bool {
        let byTitle = a.title.trimmingCharacters(in: .whitespaces)
            .compare(b.title.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "de_DE"))
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        let na = Int(a.number) ?? Int.max
        let nb = Int(b.number) ?? Int.max
        return na != nb ? na < nb : a.number < b.number
    }

    private func reload() {
        let fundstellen = (try? container.fundstellen.fundstellen(route.query)) ?? []
        entries = fundstellen.map { ($0, TextFilter.indexWords([$0.number, $0.title, $0.addition, $0.composer])) }
        fetchedAt = try? container.fundstellen.fetchedAt(route.query)
        owned = container.myBooks.ownedBookIds
        book = route.bookId.flatMap { try? container.myBooks.book(id: $0) }
        loadComposerLinks(fundstellen)
    }

    /// Zum Link gehörender Komponist, für `openURL`.
    func composerLink(for url: URL) -> ComposerLink? {
        ([editorLink].compactMap { $0 } + composerLinks.values).first { $0.url == url }
    }

    private func loadComposerLinks(_ fundstellen: [Fundstelle]) {
        let editorName = book?.editor.flatMap(ComposerNames.fromEditor)
        let names = fundstellen.compactMap(\.composer).flatMap(ComposerNames.split) + [editorName].compactMap { $0 }
        let found = (try? container.search.composerLinks(names: names)) ?? [:]
        // Auf der Seite eines Komponisten führt sein Name nirgendwohin Neues
        composerLinks = found.filter { _, link in
            if case .byComposer(let id) = route.query { link.id != id } else { true }
        }
        editorLink = editorName.flatMap { found[$0] }
    }
}
