import Foundation

/// Speicherort, den App und Share Extension gemeinsam nutzen (App Group). Die Extension liest
/// daraus das Bücherverzeichnis und schreibt das übernommene Inventar hinein.
public enum SharedStorage {

    public static let appGroup = "group.blechwiki.eggers.media"

    /// Darwin-Notification, mit der die Extension der laufenden App ein übernommenes Inventar meldet.
    public static let inventoryImportedNotification = "blechwiki.eggers.media.inventory-imported"

    /// Einstellungen in der App Group. Ohne Berechtigung (z. B. in Tests) die normalen UserDefaults.
    public static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Datenbank im Container der App Group, vom iCloud-Backup ausgenommen, weil alles neu ladbar ist.
    public static func databaseURL() throws -> URL {
        var url = try directory().appendingPathComponent("blechwiki.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Favoriten und eigene Listen (`ListsDatabase`). Eigene Datei neben der Datenbank, weil
    /// die bei Schemawechseln verworfen wird. Bewusst nicht vom Backup ausgenommen: Die Listen lassen
    /// sich nicht neu laden.
    public static func listsDatabaseURL() throws -> URL {
        try directory().appendingPathComponent("listen.sqlite")
    }

    private static func directory() throws -> URL {
        // Auf dem Mac gibt es den Pfad auch ohne Berechtigung, nur der Zugriff scheitert dann
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .flatMap { FileManager.default.isWritableFile(atPath: $0.path) ? $0 : nil }
        return try group
            ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Löscht die Datenbank mit WAL-Dateien und Markierung. Eine WAL-Datei neben einer neuen
    /// Datenbank würde diese beschädigen.
    public static func removeDatabase() {
        guard let url = try? databaseURL() else { return }
        for file in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm"), AppDatabase.corruptionMarker(url)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Bis Version 0.4.0 lagen Einstellungen und Datenbank nur in der App. Einmalig umziehen,
    /// damit die Landeskirche erhalten bleibt. Das Inventar von damals gilt seit 0.7.0 nicht mehr
    /// (siehe `UserPreferences`). Die alte Datenbank ist ein Cache und wird gelöscht, die App lädt
    /// das Verzeichnis neu.
    public static func migrateIfNeeded() {
        let shared = defaults()
        guard shared != .standard, !shared.bool(forKey: migratedKey) else { return }
        let key = "eg_appendix"
        if shared.object(forKey: key) == nil, let value = UserDefaults.standard.object(forKey: key) {
            shared.set(value, forKey: key)
        }
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("blechwiki.sqlite" + suffix))
            }
        }
        shared.set(true, forKey: migratedKey)
    }

    private static let migratedKey = "migrated_to_app_group"
}
