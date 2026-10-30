import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Liest die serialisierten .NET-DataSets der ASMX-Antworten per SAX-Parser.
///
/// Aufbau einer Antwort:
/// ```
/// <XResult>
///   <xs:schema>…</xs:schema>                 (wird übersprungen)
///   <diffgr:diffgram>
///     <NewDataSet>
///       <Titel><TITEL>…</TITEL></Titel>      (eine Zeile, Spalten als Kindelemente)
///       …
/// ```
/// Bei leerem Ergebnis ist `diffgram` ein leeres Element ohne `NewDataSet`.
enum DataSetParser {

    /// Eine DataSet-Zeile. Spaltennamen wie in der API, z. B. "TITEL" oder "BuchId".
    struct Row {
        let columns: [String: String]

        /// Getrimmter Wert, leerer String wenn die Spalte fehlt.
        func text(_ column: String) -> String {
            (columns[column] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func textOrNil(_ column: String) -> String? {
            let value = text(column)
            return value.isEmpty ? nil : value
        }

        func int(_ column: String) throws -> Int {
            guard let value = Int(text(column)) else {
                throw BlechWikiError.malformedResponse("Spalte \(column) ist keine Zahl: '\(columns[column] ?? "")'")
            }
            return value
        }

        func intOrNil(_ column: String) -> Int? { Int(text(column)) }
    }

    static func parseRows<T>(_ data: Data, _ mapRow: (Row) throws -> T) throws -> [T] {
        let delegate = RowsDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        let ok = parser.parse()
        if !delegate.foundDiffgram {
            if !ok, let error = parser.parserError {
                throw BlechWikiError.malformedResponse(error.localizedDescription)
            }
            throw BlechWikiError.malformedResponse("Antwort enthält kein diffgram")
        }
        if !ok && !delegate.finished {
            throw BlechWikiError.malformedResponse(parser.parserError?.localizedDescription ?? "XML-Fehler")
        }
        return try delegate.rows.map(mapRow)
    }

    static func parseScalar(_ data: Data, resultElement: String) throws -> String {
        guard let text = firstElementText(data, namespace: SoapEnvelope.namespace, name: resultElement) else {
            throw BlechWikiError.malformedResponse("Element \(resultElement) fehlt")
        }
        return text
    }

    /// Liefert `faultstring` oder `nil`, wenn die Antwort kein lesbarer SOAP-Fault ist.
    static func parseFaultString(_ data: Data) -> String? {
        firstElementText(data, namespace: "", name: "faultstring")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstElementText(_ data: Data, namespace: String, name: String) -> String? {
        let delegate = ElementTextDelegate(namespace: namespace, name: name)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.finished ? delegate.text : nil
    }

    private static let diffgramNamespace = "urn:schemas-microsoft-com:xml-diffgram-v1"

    private final class RowsDelegate: NSObject, XMLParserDelegate {
        var rows: [Row] = []
        var foundDiffgram = false
        var finished = false

        private var depth = 0
        private var diffgramDepth: Int?
        // Unterbaum, der übersprungen wird (Schema-Teile, unbekannte Elemente)
        private var skipUntilDepth: Int?
        private var columns: [String: String] = [:]
        private var currentColumn: String?
        private var currentText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            depth += 1
            if skipUntilDepth != nil { return }
            guard let base = diffgramDepth else {
                if elementName == "diffgram" && namespaceURI == DataSetParser.diffgramNamespace {
                    diffgramDepth = depth
                    foundDiffgram = true
                }
                return
            }
            switch depth - base {
            case 1:
                if elementName != "NewDataSet" { skipUntilDepth = depth }
            case 2:
                columns = [:]
            case 3:
                currentColumn = elementName
                currentText = ""
            default:
                skipUntilDepth = depth
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentColumn != nil && skipUntilDepth == nil { currentText += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            defer { depth -= 1 }
            if let skip = skipUntilDepth {
                if depth == skip { skipUntilDepth = nil }
                return
            }
            guard let base = diffgramDepth else { return }
            switch depth - base {
            case 0:
                finished = true
                parser.abortParsing()
            case 2:
                rows.append(Row(columns: columns))
            case 3:
                if let column = currentColumn { columns[column] = currentText }
                currentColumn = nil
            default:
                break
            }
        }
    }

    private final class ElementTextDelegate: NSObject, XMLParserDelegate {
        let namespace: String
        let name: String
        var text = ""
        var finished = false
        private var inside = false

        init(namespace: String, name: String) {
            self.namespace = namespace
            self.name = name
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            if !inside && elementName == name && (namespaceURI ?? "") == namespace { inside = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inside { text += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if inside && elementName == name {
                finished = true
                parser.abortParsing()
            }
        }
    }
}
