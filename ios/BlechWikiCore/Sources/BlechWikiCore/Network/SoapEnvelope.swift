import Foundation

enum SoapEnvelope {

    static let namespace = "http://pcportal.ddns.net/"

    static func soapAction(_ method: String) -> String { "\"\(namespace)\(method)\"" }

    static func build(_ method: String, _ params: [(String, String)]) -> String {
        var xml = #"<?xml version="1.0" encoding="utf-8"?>"#
        xml += #"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>"#
        xml += "<\(method) xmlns=\"\(namespace)\">"
        for (name, value) in params {
            xml += "<\(name)>\(value.xmlEscaped)</\(name)>"
        }
        xml += "</\(method)>"
        xml += "</soap:Body></soap:Envelope>"
        return xml
    }
}

extension String {

    var xmlEscaped: String {
        var result = ""
        result.reserveCapacity(count)
        for c in self {
            switch c {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(c)
            }
        }
        return result
    }

    /// Der Server baut seine SQL-Abfragen per String-Verkettung. Ein einzelnes Apostroph
    /// ("Ach Gott, dir muss ich's") führt dort zu einem Syntaxfehler. Verdoppeln macht daraus
    /// ein gültiges SQL-Literal. Muss auf jeden Parameter angewendet werden, der in SQL landet.
    var sqlQuoted: String { replacingOccurrences(of: "'", with: "''") }

    /// `GetTitel` und `GetTitelAnzahl` nutzen `LIKE '%…%'`. Damit `_`, `%` und `[` wörtlich
    /// gesucht werden, werden sie in SQL-Server-Klammern gesetzt.
    var likeEscaped: String {
        var result = ""
        for c in self {
            if c == "[" || c == "%" || c == "_" {
                result += "[\(c)]"
            } else {
                result.append(c)
            }
        }
        return result
    }
}
