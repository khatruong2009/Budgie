/// Port of csv 6.0.0 `CsvToListConverter` exactly as the Flutter app calls it
/// (transaction_model.dart `parseTransactionsCsv`):
///
///     CsvToListConverter(
///       shouldParseNumbers: false,
///       csvSettingsDetector: FirstOccurrenceSettingsDetector(eols: ['\r\n', '\n']),
///     ).convert(content)
///
/// Field delimiter `,` and text delimiter `"` are the constructor defaults,
/// `allowInvalid` is true (an unterminated quote never throws) and every
/// cell is a String. With these settings the package's generic
/// multi-character matcher (csv_parser.dart `_match`,
/// `_consumeTextEndDelimiter`, `_consumeEol`, `_parseField`, `convertRow`,
/// `convert`) reduces to the state machine below, verified against the real
/// package on random inputs (Fixtures/csvimport/parser.json).
///
/// Behaviours worth knowing:
/// - EOL is whichever of `\r\n` and `\n` occurs first in the whole text
///   (`indexOf`, quoted fields included); `\r\n` when neither occurs. A bare
///   CR is never an EOL, and a bare LF in a CRLF file stays in its field.
/// - A quote opens a quoted field only at the very start of a field; a quote
///   anywhere else in an unquoted field is literal (` "a,b"` keeps its
///   quotes and splits at the comma).
/// - Inside quotes `""` is a literal quote. After a closing quote any
///   character other than `,` or the EOL is appended and the field stays
///   quoted, so the next `,` and EOL are swallowed until another quote.
/// - A trailing EOL adds no row, a blank line in the middle is a row `[""]`,
///   and a lone unterminated `"` as the whole last line adds no row.
///
/// Works on UTF-16 code units like Dart: Swift's `Character` would treat
/// `\r\n` as one grapheme.
public enum CSVParser {
    public static func parse(_ text: String) -> [[String]] {
        parse(units: Array(text.utf16)).map { $0.map { String(decoding: $0, as: UTF16.self) } }
    }

    static func parse(units u: [UInt16]) -> [[[UInt16]]] {
        let comma: UInt16 = 0x2C, quote: UInt16 = 0x22, cr: UInt16 = 0x0D, lf: UInt16 = 0x0A

        // FirstOccurrenceSettingsDetector: the lowest `indexOf` wins.
        var firstCRLF = -1, firstLF = -1
        for i in 0..<u.count {
            if firstLF < 0 && u[i] == lf { firstLF = i }
            if firstCRLF < 0 && u[i] == cr && i + 1 < u.count && u[i + 1] == lf { firstCRLF = i }
            if firstLF >= 0 && firstCRLF >= 0 { break }
        }
        let crlf = !(firstLF >= 0 && (firstCRLF < 0 || firstLF < firstCRLF))

        var rows: [[[UInt16]]] = []
        var row: [[UInt16]] = []
        var field: [UInt16] = []
        // Dart `_insideString`, `_insideQuotedString`, `_previousWasTextEndDelimiter`.
        var inString = false, inQuoted = false, previousWasEndQuote = false
        func endField() {
            row.append(field)
            field = []
            inString = false
            inQuoted = false
            previousWasEndQuote = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }
        func append(_ c: UInt16) {
            field.append(c)
            inString = true
            previousWasEndQuote = false
        }

        var i = 0
        while i < u.count {
            let c = u[i]
            // Inside quotes only the closing quote is special.
            if inQuoted && !previousWasEndQuote {
                if c == quote { previousWasEndQuote = true } else { append(c) }
                i += 1
                continue
            }
            if c == quote {
                if !inString {
                    inString = true
                    inQuoted = true
                } else if inQuoted {
                    append(quote)  // `""` inside quotes
                } else {
                    append(c)  // a quote inside an unquoted field is literal
                }
                i += 1
                continue
            }
            if c == comma {
                endField()
                i += 1
                continue
            }
            if crlf {
                if c == cr && i + 1 < u.count && u[i + 1] == lf {
                    endRow()
                    i += 2
                    continue
                }
            } else if c == lf {
                endRow()
                i += 1
                continue
            }
            append(c)
            i += 1
        }
        // `isOptionalEolAtEnd`: nothing pending adds no row.
        if !(!previousWasEndQuote && field.isEmpty && row.isEmpty) {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
