import Foundation

/// Alle Fehler des Clients. Aufrufer müssen nur einen Fehlertyp behandeln, egal ob Netz,
/// Server oder Antwortformat schuld ist.
public enum BlechWikiError: Error, Equatable, Sendable {
    /// HTTP 500 mit SOAP-Fault. Enthält bei diesem Server oft die SQL-Fehlermeldung.
    case soapFault(String)
    case httpError(Int)
    case malformedResponse(String)
    /// Keine Verbindung, Timeout usw.
    case network(String)
}
