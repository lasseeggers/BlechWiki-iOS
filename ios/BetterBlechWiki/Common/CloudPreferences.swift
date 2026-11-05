import BlechWikiCore
import Foundation
import os

/// Gleicht Inventar und Landeskirche über iCloud (Key-Value Store) zwischen iPhone, iPad und Mac ab.
/// Darüber kommt das Inventar auch nach einer Neuinstallation zurück. Ohne iCloud-Anmeldung bleibt
/// alles lokal. Die Share Extension gleicht nicht selbst ab, ihre Übernahme lädt `merge()` beim
/// nächsten Aktivieren oder auf ihre Meldung hin hoch.
@MainActor
final class CloudPreferences {

    private let store = NSUbiquitousKeyValueStore.default
    private let preferences: UserPreferences
    private let onChange: () -> Void
    private var observer: NSObjectProtocol?

    /// `onChange`: Ein anderes Gerät hat Inventar oder Landeskirche geändert.
    init(preferences: UserPreferences, onChange: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
    }

    /// Vor der Frage, ob die Einführung erscheint: Was iCloud schon geladen hat, ist dann übernommen.
    /// Nach einer Neuinstallation kommt der Stand womöglich erst einige Sekunden später.
    func start() {
        store.synchronize()
        merge()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.merge() }
        }
        preferences.onEdit = { [weak self] in
            Task { @MainActor in self?.merge() }
        }
    }

    func merge() {
        let changed = preferences.merge(with: store)
        log.info("iCloud abgeglichen: \(self.preferences.ownedBookIds.count) Bücher, geändert: \(changed)")
        if changed { onChange() }
    }

    private let log = Logger(subsystem: "blechwiki.eggers.media", category: "iCloud")
}
