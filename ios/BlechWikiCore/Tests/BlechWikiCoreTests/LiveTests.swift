import Foundation
import Testing
@testable import BlechWikiCore

/// Gegen den echten, privat betriebenen Server, nur mit `BLECHWIKI_LIVE=1`. Lädt keine ganze Tabelle.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLECHWIKI_LIVE"] == "1"))
struct LiveTests {

    @Test func neueFundstellenAbEinemZaehler() async throws {
        let pieces = try await JsonBlechWikiAPI().getPieces(after: 65000)
        #expect(!pieces.isEmpty)
        #expect(pieces.allSatisfy { $0.counter > 65000 && !$0.bookShortName.isEmpty })
    }

    @Test func zaehlerDerFundstellenEinesBuchs() async throws {
        let counters = try await JsonBlechWikiAPI().getBookPieceCounters("4035")
        #expect(counters.count == 76)
        #expect(counters.contains(63740))
    }
}
