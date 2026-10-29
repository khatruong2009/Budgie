/// Byte-exact port of the Flutter app's transaction CSV export
/// (`TransactionModel.exportToCsv` with csv 6.0.0 `ListToCsvConverter`).
public enum CSVExport {
    public struct Row: Sendable {
        public var date: DartDateTime
        public var isIncome: Bool
        public var category: String
        public var description: String
        public var amount: Double

        public init(date: DartDateTime, isIncome: Bool, category: String, description: String, amount: Double) {
            self.date = date
            self.isIncome = isIncome
            self.category = category
            self.description = description
            self.amount = amount
        }
    }

    /// Bytes of the export file: UTF-8, no BOM. Rows are separated by CRLF with
    /// no trailing newline; an empty ledger is just the header line.
    public static func export(_ rows: [Row]) -> [UInt8] {
        // Stable ascending sort on the full instant.
        let sorted = rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element.date.microsecondsSinceEpoch
            let b = rhs.element.date.microsecondsSinceEpoch
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)

        var lines = ["Date,Type,Category,Description,Amount"]
        for row in sorted {
            let fields = [
                dateText(row.date),
                row.isIncome ? "Income" : "Expense",
                row.category,
                row.description,
                DartFixed.toStringAsFixed(row.amount, 2),
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return Array(lines.joined(separator: "\r\n").utf8)
    }

    /// "transactions_yyyyMMdd_HHmmss.csv" from the local fields of `now`.
    public static func fileName(now: DartDateTime) -> String {
        "transactions_\(DartDateFormat.yyyyMMdd_HHmmss(now)).csv"
    }

    /// `DateFormat('yyyy-MM-dd')` (a negative year prints without its sign).
    private static func dateText(_ date: DartDateTime) -> String { DartDateFormat.yyyyMMdd(date) }

    /// Quote iff the field contains `,` `"` CR or LF; embedded `"` are doubled.
    /// Works on unicode scalars because "\r\n" is a single Character in Swift.
    private static func escape(_ field: String) -> String {
        let needsQuotes = field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        guard needsQuotes else { return field }
        var result = "\""
        for scalar in field.unicodeScalars {
            if scalar == "\"" { result.unicodeScalars.append("\"") }
            result.unicodeScalars.append(scalar)
        }
        result += "\""
        return result
    }
}
