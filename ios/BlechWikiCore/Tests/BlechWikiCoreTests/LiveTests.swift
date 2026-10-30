import Foundation
import Testing
@testable import BlechWikiCore

/// Gegen die echten Server, nur mit `BLECHWIKI_LIVE=1`. Beide Server sind privat betrieben,
/// daher nur gezielt ausführen.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLECHWIKI_LIVE"] == "1"))
struct LiveTests {

    /// URLSession muss den Umlaut im SOAPAction-Header so schicken, dass der Server die Methode findet.
    @Test func methodeMitUmlaut() async throws {
        let appendices = try await SoapBlechWikiAPI().getEgAppendices()
        #expect(appendices.contains { $0.code == "NB" })
    }

    @Test func restAenderungsprotokollDerBuecherIstNichtLeer() async throws {
        #expect((try await JsonBlechWikiRestAPI().getLatestChange(.books, after: 1) ?? 0) > 1)
    }
}
