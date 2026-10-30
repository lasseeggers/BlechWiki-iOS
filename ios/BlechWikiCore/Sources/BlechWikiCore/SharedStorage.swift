import Foundation

/// Speicherort, den App und Share Extension gemeinsam nutzen (App Group). Die Extension liest
/// daraus das Bücherverzeichnis und schreibt das übernommene Inventar hinein.
public enum SharedStorage {

    public static let appGroup = "group.blechwiki.eggers.media"

    /// Einstellungen in der App Group. Ohne Berechtigung (z. B. in Tests) die normalen UserDefaults.
    public static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Datenbank im Container der App Group, vom iCloud-Backup ausgenommen, weil alles neu ladbar ist.
    public static func databaseURL() throws -> URL {
        let dir = try FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = dir.appendingPathComponent("blechwiki.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Bis Version 0.4.0 lagen Einstellungen und Datenbank nur in der App. Einmalig umziehen,
    /// damit Inventar und Landeskirche erhalten bleiben. Die alte Datenbank ist ein Cache und
    /// wird gelöscht, die App lädt das Verzeichnis neu.
    public static func migrateIfNeeded() {
        let shared = defaults()
        guard shared != .standard, !shared.bool(forKey: migratedKey) else { return }
        for key in ["eg_appendix", "owned_books"] {
            if shared.object(forKey: key) == nil, let value = UserDefaults.standard.object(forKey: key) {
                shared.set(value, forKey: key)
            }
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
