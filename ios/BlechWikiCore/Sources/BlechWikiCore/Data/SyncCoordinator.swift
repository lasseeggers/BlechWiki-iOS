import Foundation
import Observation
import os

/// Ersatz für WorkManager und `SyncScheduler` der Android-App. iOS lässt Apps im Hintergrund
/// kaum laufen, deshalb passiert alles, solange die App offen ist:
/// - beim Aktivieren der App der Stammdaten-Abgleich (überspringt sich selbst, wenn jünger als 24 h),
///   im WLAN zusätzlich der monatliche Vollabgleich
/// - danach und nach jeder Inventar-Änderung das Laden der Inventar-Bücher, nacheinander
/// - bei Fehlern bis zu drei Wiederholungen mit wachsendem Abstand (30 s, 60 s, 120 s)
@MainActor
@Observable
public final class SyncCoordinator {

    public private(set) var status: SyncStatus = .idle

    private let sync: MasterDataSync
    private let fundstellen: FundstellenRepository
    private let preferences: UserPreferences
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var ownedBooksTask: Task<Void, Never>?
    private let log = Logger(subsystem: "blechwiki.eggers.media", category: "Sync")

    private static let maxRetries = 3
    private static let backoff: Duration = .seconds(30)

    public init(sync: MasterDataSync, fundstellen: FundstellenRepository, preferences: UserPreferences) {
        self.sync = sync
        self.fundstellen = fundstellen
        self.preferences = preferences
    }

    /// Beim Aktivieren der App. Läuft schon ein Abgleich, passiert nichts.
    public func onAppActive(unmetered: Bool) {
        guard syncTask == nil else { return }
        startSync(force: false, fullRefreshIfDue: unmetered)
    }

    /// Sofort erneut versuchen, z. B. nach Fehler beim ersten Laden.
    public func retryNow() {
        startSync(force: false, fullRefreshIfDue: false)
    }

    /// Datenversion jetzt prüfen, z. B. wenn ein geteiltes Inventar unbekannte Bücher enthält.
    /// Ein Versuch ohne Wiederholung, damit der Dialog schnell eine Antwort zeigen kann.
    /// - Returns: `false`, wenn BlechWiki nicht erreichbar war
    public func checkCatalogNow() async -> Bool {
        syncTask?.cancel()
        syncTask = nil
        status = .running
        do {
            _ = try await sync.sync(force: true)
            status = .idle
            startOwnedBooks(delay: .zero)
            return true
        } catch {
            log.warning("Verzeichnis-Prüfung fehlgeschlagen: \(String(describing: error))")
            status = .idle
            return false
        }
    }

    /// Nach Änderungen am Inventar. Die Verzögerung fasst mehrere Klicks zu einem Lauf zusammen.
    public func downloadOwnedBooks() {
        startOwnedBooks(delay: .seconds(2))
    }

    private func startSync(force: Bool, fullRefreshIfDue: Bool) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.runSync(force: force, fullRefreshIfDue: fullRefreshIfDue)
        }
    }

    private func runSync(force: Bool, fullRefreshIfDue: Bool) async {
        defer { if !Task.isCancelled { syncTask = nil } }
        for attempt in 0...Self.maxRetries {
            status = .running
            do {
                let outcome = try await sync.sync(force: force, fullRefreshIfDue: fullRefreshIfDue)
                log.info("Stammdaten-Abgleich: \(String(describing: outcome))")
                status = .idle
                // Erst jetzt ist die Datenversion bekannt. Ein parallel gestarteter Bücher-Abgleich
                // hielte veraltete Bücher sonst für frisch.
                startOwnedBooks(delay: .zero)
                return
            } catch {
                if Task.isCancelled { return }
                log.warning("Stammdaten-Abgleich fehlgeschlagen (Versuch \(attempt + 1)): \(String(describing: error))")
                if attempt == Self.maxRetries { break }
                status = .waiting(afterFailure: true)
                try? await Task.sleep(for: Self.backoff * (1 << attempt))
                if Task.isCancelled { return }
            }
        }
        status = .failed
    }

    private func startOwnedBooks(delay: Duration) {
        ownedBooksTask?.cancel()
        ownedBooksTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            if Task.isCancelled { return }
            await self?.runOwnedBooks()
        }
    }

    /// Lädt den Inhalt aller markierten Bücher. Bücher mit frischem Cache kosten keinen Request.
    private func runOwnedBooks() async {
        for attempt in 0...Self.maxRetries {
            let ids = preferences.ownedBookIds.sorted()
            var loaded = 0
            var failed = 0
            // Nacheinander, um den privat betriebenen Server nicht zu belasten
            for id in ids {
                if Task.isCancelled { return }
                do {
                    if try await fundstellen.refresh(.byBook(id)) { loaded += 1 }
                } catch {
                    failed += 1
                    log.warning("Buch \(id) konnte nicht geladen werden: \(String(describing: error))")
                }
            }
            log.info("Inventar: \(ids.count) Bücher, \(loaded) geladen, \(failed) fehlgeschlagen")
            if failed == 0 || attempt == Self.maxRetries { return }
            try? await Task.sleep(for: Self.backoff * (1 << attempt))
            if Task.isCancelled { return }
        }
    }
}
