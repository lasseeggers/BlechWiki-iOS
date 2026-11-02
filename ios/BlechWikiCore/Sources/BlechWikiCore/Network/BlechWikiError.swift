import Foundation

/// Alle Fehler des Clients. Aufrufer müssen nur einen Fehlertyp behandeln, egal ob Netz,
/// Server oder Antwortformat schuld ist.
public enum BlechWikiError: Error, Equatable, Sendable {
    case httpError(Int)
    case malformedResponse(String)
    /// Keine Verbindung, Timeout usw.
    case network(String)
}
