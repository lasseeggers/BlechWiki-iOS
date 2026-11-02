import Foundation

/// Was der Nutzer selbst festlegt. Liegt bewusst nicht in der Datenbank: Die ist ein Cache
/// und wird bei Schemawechseln verworfen, diese Einstellungen müssen das überleben.
public final class UserPreferences: @unchecked Sendable {

    private let defaults: UserDefaults
    private let changes: DataChanges
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, changes: DataChanges) {
        self.defaults = defaults
        self.changes = changes
    }

    /// Kürzel des EG-Anhangs der eigenen Landeskirche, z. B. "NB".
    public var egAppendix: String? { defaults.string(forKey: Keys.egAppendix) }

    public var ownedBookIds: Set<String> { Set(defaults.stringArray(forKey: Keys.ownedBooks) ?? []) }

    public func setEgAppendix(_ code: String?) {
        defaults.set(code, forKey: Keys.egAppendix)
        changes.notify()
    }

    public func setBookOwned(_ bookId: String, owned: Bool) {
        edit { current in
            if owned { current.insert(bookId) } else { current.remove(bookId) }
        }
    }

    /// Übernimmt ein geteiltes Inventar. `replace` verwirft das bisherige.
    public func addOwnedBooks(_ bookIds: [String], replace: Bool) {
        edit { current in
            if replace { current.removeAll() }
            current.formUnion(bookIds)
        }
    }

    private func edit(_ change: (inout Set<String>) -> Void) {
        lock.lock()
        var current = ownedBookIds
        change(&current)
        defaults.set(current.sorted(), forKey: Keys.ownedBooks)
        lock.unlock()
        changes.notify()
    }

    private enum Keys {
        static let egAppendix = "eg_appendix"
        // Bis 0.6.1 standen unter "owned_books" die Kurznamen der SOAP-API. Neuer Schlüssel
        // statt Migration, vor 1.0 durfte das Inventar verloren gehen.
        static let ownedBooks = "owned_book_ids"
    }
}
