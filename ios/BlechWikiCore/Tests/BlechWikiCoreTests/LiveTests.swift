import Foundation
import Testing
@testable import BlechWikiCore

/// Gegen den echten, privat betriebenen Server, nur mit `BLECHWIKI_LIVE=1`. Lädt keine ganze Tabelle.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLECHWIKI_LIVE"] == "1"))
struct LiveTests {

    @Test func aenderungsprotokollDerTitelLiefertIxUndZaehler() async throws {
        let titles = try await JsonBlechWikiAPI().getTitles(after: 60).rows
        #expect(!titles.isEmpty)
        #expect(titles.allSatisfy { $0.ix > 0 && $0.changeCounter > 60 })
    }

    @Test func eg316HatFundstellenUnterDerMelodie859() async throws {
        let fundstellen = try await JsonBlechWikiAPI().getFundstellenByEgSong(859)
        #expect(fundstellen.count > 100)
        #expect(fundstellen.allSatisfy { Int($0.bookId) != nil })
    }

    @Test func fundstellenEinesBuchsUeberDieNumerischeId() async throws {
        let fundstellen = try await JsonBlechWikiAPI().getFundstellenByBook("4035")
        #expect(Set(fundstellen.map(\.bookTitle)) == ["Bläsermusik 2025 - Württemberg"])
    }
}
