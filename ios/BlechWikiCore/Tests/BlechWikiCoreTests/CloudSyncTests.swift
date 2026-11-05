import Foundation
import Testing
@testable import BlechWikiCore

/// Abgleich von Inventar und Landeskirche über iCloud (`UserPreferences.merge(with:)`).
struct CloudSyncTests {

    final class FakeStore: KeyValueStore {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    final class Clock: @unchecked Sendable {
        var millis: Double = 1_000_000
        var date: Date { Date(timeIntervalSince1970: millis / 1000) }
    }

    private func device(_ clock: Clock = Clock()) -> (UserPreferences, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return (UserPreferences(defaults: defaults, changes: DataChanges(), now: { clock.date }), defaults)
    }

    @Test func zweiGeraeteHabenDanachDasselbeInventar() {
        let cloud = FakeStore()
        let (iphone, _) = device()
        let (mac, _) = device()
        iphone.setBookOwned("a", owned: true)
        mac.setBookOwned("b", owned: true)

        iphone.merge(with: cloud)
        #expect(mac.merge(with: cloud))
        iphone.merge(with: cloud)

        #expect(iphone.ownedBookIds == ["a", "b"])
        #expect(mac.ownedBookIds == ["a", "b"])
    }

    @Test func entferntesBuchKommtNichtWieder() {
        let cloud = FakeStore()
        let clock = Clock()
        let (iphone, _) = device(clock)
        let (mac, _) = device(clock)
        iphone.setBookOwned("a", owned: true)
        iphone.merge(with: cloud)
        mac.merge(with: cloud)

        clock.millis += 1000
        mac.setBookOwned("a", owned: false)
        mac.merge(with: cloud)
        iphone.merge(with: cloud)

        #expect(iphone.ownedBookIds.isEmpty)
        #expect(mac.ownedBookIds.isEmpty)
    }

    @Test func entfernenGewinntAuchMitNachgehenderUhr() {
        let cloud = FakeStore()
        let iphoneClock = Clock()
        let macClock = Clock()
        macClock.millis -= 60_000
        let (iphone, _) = device(iphoneClock)
        let (mac, _) = device(macClock)
        iphone.setBookOwned("a", owned: true)
        iphone.merge(with: cloud)
        mac.merge(with: cloud)

        mac.setBookOwned("a", owned: false)
        mac.merge(with: cloud)
        iphone.merge(with: cloud)

        #expect(iphone.ownedBookIds.isEmpty)
    }

    @Test func wiederHinzugefuegtesBuchBleibt() {
        let cloud = FakeStore()
        let (iphone, _) = device()
        iphone.setBookOwned("a", owned: true)
        iphone.setBookOwned("a", owned: false)
        iphone.setBookOwned("a", owned: true)
        iphone.merge(with: cloud)

        let (neu, _) = device()
        neu.merge(with: cloud)
        #expect(neu.ownedBookIds == ["a"])
    }

    @Test func neuinstallationHoltInventarZurueck() {
        let cloud = FakeStore()
        let (alt, _) = device()
        alt.setEgAppendix("NB")
        alt.setBookOwned("a", owned: true)
        alt.merge(with: cloud)

        let (neu, _) = device()
        #expect(neu.merge(with: cloud))
        #expect(neu.ownedBookIds == ["a"])
        #expect(neu.egAppendix == "NB")
    }

    @Test func juengereLandeskircheGewinnt() {
        let cloud = FakeStore()
        let clock = Clock()
        let (iphone, _) = device(clock)
        let (mac, _) = device(clock)
        iphone.setEgAppendix("NB")
        clock.millis += 1000
        mac.setEgAppendix("BY")

        iphone.merge(with: cloud)
        mac.merge(with: cloud)
        iphone.merge(with: cloud)

        #expect(iphone.egAppendix == "BY")
        #expect(mac.egAppendix == "BY")
    }

    /// Stand von vor 1.5.0: Liste ohne Zeitstempel, Landeskirche ohne Zeitpunkt.
    @Test func alterStandWirdUebernommenUndVereinigt() {
        let cloud = FakeStore()
        let (iphone, iphoneDefaults) = device()
        let (mac, macDefaults) = device()
        iphoneDefaults.set(["a"], forKey: "owned_book_ids")
        iphoneDefaults.set("NB", forKey: "eg_appendix")
        macDefaults.set(["b"], forKey: "owned_book_ids")
        macDefaults.set("BY", forKey: "eg_appendix")

        iphone.merge(with: cloud)
        mac.merge(with: cloud)
        iphone.merge(with: cloud)

        #expect(iphone.ownedBookIds == ["a", "b"])
        #expect(mac.ownedBookIds == ["a", "b"])
        // Gleicher Zeitpunkt 0: Beide Geräte müssen dasselbe wählen, sonst überschrieben sie sich ewig
        #expect(iphone.egAppendix == mac.egAppendix)
        #expect(!iphone.merge(with: cloud))
        #expect(!mac.merge(with: cloud))
    }

    @Test func uebernahmeMitErsetzenEntferntAuchInIcloud() {
        let cloud = FakeStore()
        let clock = Clock()
        let (iphone, _) = device(clock)
        let (mac, _) = device(clock)
        iphone.addOwnedBooks(["a", "b"], replace: false)
        iphone.merge(with: cloud)
        mac.merge(with: cloud)

        clock.millis += 1000
        iphone.addOwnedBooks(["c"], replace: true)
        iphone.merge(with: cloud)
        mac.merge(with: cloud)

        #expect(mac.ownedBookIds == ["c"])
    }

    @Test func ohneUnterschiedWirdNichtsGeschrieben() {
        let cloud = FakeStore()
        let (iphone, _) = device()
        #expect(!iphone.merge(with: cloud))
        #expect(cloud.values.isEmpty)
    }

    @Test func eigeneAenderungMeldetSich() {
        let (iphone, _) = device()
        let calls = Counter()
        iphone.onEdit = { calls.increment() }
        iphone.setBookOwned("a", owned: true)
        iphone.setEgAppendix("NB")
        #expect(calls.value == 2)
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
