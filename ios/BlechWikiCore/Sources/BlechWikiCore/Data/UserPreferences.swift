import Foundation

/// Was der Nutzer selbst festlegt. Liegt bewusst nicht in der Datenbank: Die ist ein Cache
/// und wird bei Schemawechseln verworfen, diese Einstellungen müssen das überleben.
///
/// Inventar und Landeskirche gleicht `merge(with:)` über iCloud ab. Dafür trägt jede Änderung einen
/// Zeitstempel: pro Buch, wann es hinzukam und wann es entfernt wurde, dazu der Zeitpunkt der
/// Landeskirche. Beim Zusammenführen gewinnt je der jüngere Wert. So geht nichts verloren, wenn zwei
/// Geräte offline etwas ändern, und ein entferntes Buch taucht nicht wieder auf.
public final class UserPreferences: @unchecked Sendable {

    private let defaults: UserDefaults
    private let changes: DataChanges
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// Nach jeder eigenen Änderung, damit sie gleich nach iCloud geht. Vor der ersten Änderung setzen.
    public var onEdit: (@Sendable () -> Void)?

    public init(defaults: UserDefaults = .standard, changes: DataChanges, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.changes = changes
        self.now = now
    }

    /// Kürzel des EG-Anhangs der eigenen Landeskirche, z. B. "NB".
    public var egAppendix: String? { defaults.string(forKey: Keys.egAppendix) }

    public var ownedBookIds: Set<String> { Set(defaults.stringArray(forKey: Keys.ownedBooks) ?? []) }

    /// Die Einführung beim ersten Start ist durchlaufen oder übersprungen.
    public var onboardingDone: Bool { defaults.bool(forKey: Keys.onboardingDone) }

    public func setOnboardingDone() {
        defaults.set(true, forKey: Keys.onboardingDone)
    }

    public func setEgAppendix(_ code: String?) {
        lock.lock()
        var state = localState()
        state.appendix = Appendix(code: code, at: Self.later(now(), than: state.appendix.at))
        writeLocal(state)
        lock.unlock()
        changes.notify()
        onEdit?()
    }

    public func setBookOwned(_ bookId: String, owned: Bool) {
        edit { books in
            if owned { books.add(bookId, at: now()) } else { books.remove(bookId, at: now()) }
        }
    }

    /// Übernimmt ein geteiltes Inventar. `replace` verwirft das bisherige.
    public func addOwnedBooks(_ bookIds: [String], replace: Bool) {
        edit { books in
            let at = now()
            if replace {
                for id in books.owned.subtracting(bookIds) { books.remove(id, at: at) }
            }
            for id in bookIds { books.add(id, at: at) }
        }
    }

    /// Führt den eigenen Stand mit dem in `store` zusammen und schreibt das Ergebnis auf beide Seiten,
    /// jeweils nur bei Unterschied. Gibt zurück, ob sich Inventar oder Landeskirche hier geändert haben.
    @discardableResult
    public func merge(with store: KeyValueStore) -> Bool {
        lock.lock()
        let local = localState()
        let remote = State(
            books: Books(
                added: Self.timestamps(store.object(forKey: Keys.added)),
                removed: Self.timestamps(store.object(forKey: Keys.removed))
            ),
            appendix: Appendix(store.object(forKey: Keys.egAppendix))
        )
        let merged = local.merged(with: remote)
        if merged != local { writeLocal(merged) }
        if merged.books.added != remote.books.added { store.set(merged.books.added, forKey: Keys.added) }
        if merged.books.removed != remote.books.removed { store.set(merged.books.removed, forKey: Keys.removed) }
        if merged.appendix != remote.appendix { store.set(merged.appendix.plist, forKey: Keys.egAppendix) }
        lock.unlock()
        let changed = merged.books.owned != local.books.owned || merged.appendix.code != local.appendix.code
        if changed { changes.notify() }
        return changed
    }

    private func edit(_ change: (inout Books) -> Void) {
        lock.lock()
        var state = localState()
        change(&state.books)
        writeLocal(state)
        lock.unlock()
        changes.notify()
        onEdit?()
    }

    /// Bis 1.4.0 gab es nur die Liste der Bücher ohne Zeitstempel. Diese Bücher gelten als zum
    /// Zeitpunkt 0 hinzugefügt: Der erste Abgleich vereinigt die Inventare der Geräte, und jedes
    /// spätere Entfernen ist jünger.
    private func localState() -> State {
        let books: Books
        if defaults.object(forKey: Keys.added) == nil {
            let owned = defaults.stringArray(forKey: Keys.ownedBooks) ?? []
            books = Books(added: Dictionary(owned.map { ($0, 0) }, uniquingKeysWith: max), removed: [:])
        } else {
            books = Books(
                added: Self.timestamps(defaults.object(forKey: Keys.added)),
                removed: Self.timestamps(defaults.object(forKey: Keys.removed))
            )
        }
        let appendix = Appendix(code: egAppendix, at: defaults.double(forKey: Keys.egAppendixAt))
        return State(books: books, appendix: appendix)
    }

    /// Schreibt auch die abgeleitete Liste `owned_book_ids`. Aus ihr lesen `ownedBookIds` und ältere
    /// Versionen der App.
    private func writeLocal(_ state: State) {
        defaults.set(state.books.added, forKey: Keys.added)
        defaults.set(state.books.removed, forKey: Keys.removed)
        defaults.set(state.books.owned.sorted(), forKey: Keys.ownedBooks)
        defaults.set(state.appendix.code, forKey: Keys.egAppendix)
        defaults.set(state.appendix.at, forKey: Keys.egAppendixAt)
    }

    private static func timestamps(_ value: Any?) -> [String: Double] {
        (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Zeitstempel in Millisekunden, mindestens 1 nach `previous`. Geht die Uhr dieses Geräts nach,
    /// gewinnt die Änderung trotzdem gegen den Stand, den das Gerät gerade sieht.
    static func later(_ date: Date, than previous: Double?) -> Double {
        max((date.timeIntervalSince1970 * 1000).rounded(), (previous ?? -1) + 1)
    }

    private struct State: Equatable {
        var books: Books
        var appendix: Appendix

        func merged(with other: State) -> State {
            State(
                books: Books(
                    added: books.added.merging(other.books.added, uniquingKeysWith: max),
                    removed: books.removed.merging(other.books.removed, uniquingKeysWith: max)
                ),
                appendix: max(appendix, other.appendix)
            )
        }
    }

    private struct Books: Equatable {
        var added: [String: Double]
        var removed: [String: Double]

        var owned: Set<String> { Set(added.keys.filter(isOwned)) }

        func isOwned(_ id: String) -> Bool {
            guard let at = added[id] else { return false }
            return at > removed[id] ?? -1
        }

        mutating func add(_ id: String, at date: Date) {
            guard !isOwned(id) else { return }
            added[id] = UserPreferences.later(date, than: max(added[id] ?? -1, removed[id] ?? -1))
        }

        mutating func remove(_ id: String, at date: Date) {
            guard isOwned(id) else { return }
            removed[id] = UserPreferences.later(date, than: added[id])
        }
    }

    /// Landeskirche mit dem Zeitpunkt der Wahl. `code` = nil: keine gewählt. In iCloud als ein Eintrag,
    /// damit Kürzel und Zeitpunkt nur zusammen ankommen. Die jüngere Wahl ist größer. Bei gleichem
    /// Zeitpunkt (z. B. zwei Geräte mit Werten von vor 1.5.0) entscheidet das Kürzel, damit beide
    /// Geräte dasselbe wählen und sich nicht gegenseitig überschreiben.
    private struct Appendix: Comparable {
        var code: String?
        var at: Double

        init(code: String?, at: Double) {
            self.code = code
            self.at = at
        }

        init(_ plist: Any?) {
            let dict = plist as? [String: Any]
            code = dict?["code"] as? String
            at = (dict?["at"] as? NSNumber)?.doubleValue ?? 0
        }

        static func < (lhs: Appendix, rhs: Appendix) -> Bool {
            (lhs.at, lhs.code ?? "") < (rhs.at, rhs.code ?? "")
        }

        var plist: [String: Any] {
            var dict: [String: Any] = ["at": at]
            if let code { dict["code"] = code }
            return dict
        }
    }

    private enum Keys {
        static let egAppendix = "eg_appendix"
        static let egAppendixAt = "eg_appendix_at"
        // Bis 0.6.1 standen unter "owned_books" die Kurznamen der SOAP-API. Neuer Schlüssel
        // statt Migration, vor 1.0 durfte das Inventar verloren gehen.
        static let ownedBooks = "owned_book_ids"
        static let added = "owned_book_added"
        static let removed = "owned_book_removed"
        static let onboardingDone = "onboarding_done"
    }
}

/// Speicher, mit dem `UserPreferences.merge(with:)` abgleicht. In der App `NSUbiquitousKeyValueStore`
/// (iCloud), in Tests ein Wörterbuch.
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension NSUbiquitousKeyValueStore: KeyValueStore {}
