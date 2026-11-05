import Foundation
import Observation
import os

/// Ersatz für WorkManager und `SyncScheduler` der Android-App. iOS lässt Apps im Hintergrund
/// kaum laufen, deshalb passiert alles, solange die App offen ist:
/// - beim Aktivieren der App der Stammdaten-Abgleich (überspringt sich selbst, wenn jünger als 24 h),
///   im WLAN zusätzlich der monatliche Vollabgleich
/// - danach und nach jeder Inventar-Änderung der Abgleich der Inventar-Bücher mit `Buch/{id}`,
///   nacheinander, je Buch höchstens alle 30 Tage
/// - bei Fehlern bis zu drei Wiederholungen mit wachsendem Abstand (30 s, 60 s, 120 s)
///
/// Wer schreibt, bittet iOS über `beginBackgroundWork` um etwas Zeit im Hintergrund. Die
/// Datenbank liegt in der App Group, und iOS beendet Apps, die beim Wechsel in den Hintergrund
/// eine Sperre auf eine Datei dort halten (0xdead10cc).
@MainActor
@Observable
public final class SyncCoordinator {

    public private(set) var status: SyncStatus = .idle

    /// Beginnt Arbeit, die beim Wechsel in den Hintergrund zu Ende laufen soll, und liefert die
    /// Funktion, die sie beendet. Setzt die App (`UIApplication.beginBackgroundTask`), das Package
    /// kennt UIKit nicht.
    @ObservationIgnored public var beginBackgroundWork: (@MainActor (String) -> @MainActor () -> Void)?

    private let sync: MasterDataSync
    private let fundstellen: FundstellenRepository
    private let preferences: UserPreferences
    private let db: AppDatabase
    @ObservationIgnored private var syncTask: Task<Bool, Never>?
    @ObservationIgnored private var ownedBooksTask: Task<Void, Never>?
    /// Das WLAN wurde erst erkannt, als schon ein Abgleich lief. Der monatliche Vollabgleich
    /// folgt dann im Anschluss.
    @ObservationIgnored private var fullRefreshPending = false
    private let log = Logger(subsystem: "blechwiki.eggers.media", category: "Sync")

    private static let maxRetries = 3
    private static let backoff: Duration = .seconds(30)

    public init(sync: MasterDataSync, fundstellen: FundstellenRepository, preferences: UserPreferences, db: AppDatabase) {
        self.sync = sync
        self.fundstellen = fundstellen
        self.preferences = preferences
        self.db = db
    }

    /// Beim Aktivieren der App und wenn das WLAN erkannt wird. Läuft schon ein Abgleich, wird kein
    /// zweiter gestartet. `unmetered` holt dann nur den Vollabgleich nach, falls fällig.
    public func onAppActive(unmetered: Bool) {
        guard syncTask == nil else {
            if unmetered { fullRefreshPending = true }
            return
        }
        startSync(force: false, fullRefreshIfDue: unmetered)
    }

    /// Sofort erneut versuchen, z. B. nach Fehler beim ersten Laden.
    public func retryNow() {
        startSync(force: false, fullRefreshIfDue: false)
    }

    /// Datenversion jetzt prüfen, z. B. wenn ein geteiltes Inventar unbekannte Bücher enthält.
    /// Ein Versuch ohne Wiederholung, damit der Dialog schnell eine Antwort zeigen kann. Bricht
    /// einen laufenden Abgleich ab und ersetzt ihn, damit nie zwei gleichzeitig laufen und der
    /// Dialog nicht auf den alten wartet.
    /// - Returns: `false`, wenn BlechWiki nicht erreichbar war
    public func checkCatalogNow() async -> Bool {
        await startSync(force: true, fullRefreshIfDue: false, retries: 0).value
    }

    /// „Alle Daten neu laden“: alles vom Server, auch alle Fundstellen (ca. 8,5 MB). Ersetzt einen
    /// laufenden Abgleich. Fortschritt über `status`.
    public func reloadAll() {
        startSync(force: true, fullRefreshIfDue: false, reloadAll: true)
    }

    /// Nach Änderungen am Inventar. Die Verzögerung fasst mehrere Klicks zu einem Lauf zusammen.
    public func downloadOwnedBooks() {
        startOwnedBooks(delay: .seconds(2))
    }

    /// Führt `body` mit Zeit im Hintergrund aus, siehe `beginBackgroundWork`.
    public func withBackgroundTime<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let end = beginBackgroundWork?(name)
        defer { end?() }
        return try await body()
    }

    @discardableResult
    private func startSync(
        force: Bool,
        fullRefreshIfDue: Bool,
        reloadAll: Bool = false,
        retries: Int = SyncCoordinator.maxRetries
    ) -> Task<Bool, Never> {
        syncTask?.cancel()
        if fullRefreshIfDue { fullRefreshPending = false }
        let task = Task { [weak self] in
            await self?.runSync(force: force, fullRefreshIfDue: fullRefreshIfDue, reloadAll: reloadAll, retries: retries) ?? false
        }
        syncTask = task
        return task
    }

    private func runSync(force: Bool, fullRefreshIfDue: Bool, reloadAll: Bool, retries: Int) async -> Bool {
        defer { if !Task.isCancelled { syncTask = nil } }
        for attempt in 0...retries {
            status = .running
            do {
                let outcome = try await withBackgroundTime("Abgleich") {
                    try await sync.sync(force: force, fullRefreshIfDue: fullRefreshIfDue, reloadAll: reloadAll)
                }
                log.info("Stammdaten-Abgleich: \(String(describing: outcome))")
                if fullRefreshPending, !Task.isCancelled {
                    fullRefreshPending = false
                    let full = try? await withBackgroundTime("Abgleich") { try await sync.sync(fullRefreshIfDue: true) }
                    log.info("Vollabgleich im WLAN: \(String(describing: full))")
                }
                // Ersetzt, aber trotzdem fertig geworden: Status und Inventar sind Sache des neuen Laufs
                if Task.isCancelled { return true }
                status = .idle
                // Erst jetzt ist die Datenversion bekannt. Ein parallel gestarteter Bücher-Abgleich
                // hielte veraltete Bücher sonst für frisch.
                startOwnedBooks(delay: .zero)
                return true
            } catch {
                if Task.isCancelled { return false }
                log.warning("Stammdaten-Abgleich fehlgeschlagen (Versuch \(attempt + 1)): \(String(describing: error))")
                if attempt == retries { break }
                status = .waiting(afterFailure: true)
                try? await Task.sleep(for: Self.backoff * (1 << attempt))
                if Task.isCancelled { return false }
            }
        }
        status = .failed
        return false
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

    /// Gleicht alle markierten Bücher mit `Buch/{id}` ab, um gelöschte Fundstellen zu finden. Bücher,
    /// die in den letzten 30 Tagen abgeglichen wurden, kosten keinen Request. Bücher, die nicht
    /// (mehr) im Verzeichnis stehen, beantwortet der Server mit HTTP 500. Sie kosteten sonst bei
    /// jedem Aktivieren alle Wiederholungen und bleiben deshalb außen vor.
    private func runOwnedBooks() async {
        for attempt in 0...Self.maxRetries {
            let owned = preferences.ownedBookIds
            let known = Set((try? db.books(ids: Array(owned)))?.map(\.id) ?? [])
            let ids = owned.filter(known.contains).sorted()
            var loaded = 0
            var failed = 0
            // Nacheinander, um den privat betriebenen Server nicht zu belasten
            for id in ids {
                if Task.isCancelled { return }
                do {
                    if try await withBackgroundTime("Inventar", { try await fundstellen.refresh(.byBook(id)) }) { loaded += 1 }
                } catch {
                    failed += 1
                    log.warning("Buch \(id) konnte nicht geladen werden: \(String(describing: error))")
                }
            }
            log.info("Inventar: \(ids.count) Bücher, \(loaded) abgeglichen, \(failed) fehlgeschlagen, \(owned.count - ids.count) nicht im Verzeichnis")
            if failed == 0 || attempt == Self.maxRetries { return }
            try? await Task.sleep(for: Self.backoff * (1 << attempt))
            if Task.isCancelled { return }
        }
    }
}
