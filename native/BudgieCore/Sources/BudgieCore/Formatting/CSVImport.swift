/// The Settings "Import from CSV" pipeline: a port of
/// `TransactionModel.parseTransactionsCsv` (transaction_model.dart:1044-1176)
/// and the copy of `SettingsPageState._importTransactions` /
/// `_confirmImport` (settings_page.dart:116-286), with the D6 fixes listed
/// in PARITY_GAPS ("CSV import").
///
/// Pipeline: `decode` the picked bytes, `parse` them against the readable
/// transactions (validation and multiset dedupe; pure, writes nothing), show
/// `emptyResultMessage` or the confirm dialog, then
/// `FinancialData.importTransactions` builds the rows and the one commit.
public enum CSVImport {
    /// One valid row to import (Flutter builds a `Transaction` here; the id
    /// and timestamps are assigned at import, see `importTransactions`).
    public struct Draft: Sendable, Hashable {
        /// Local midnight for a date-only cell, the time of day when given; a
        /// `Z` or `+hh:mm` cell is a UTC value (stored with `Z`).
        public let date: DartDateTime
        public let type: TransactionType
        /// Trimmed, never empty; not matched against the definitions.
        public let category: String
        /// Trimmed; may be empty.
        public let description: String
        /// Finite and not negative (`-0` is accepted as -0.0, as in Dart).
        public let amount: Double
    }

    public struct Summary: Sendable {
        /// Rows to import, in file order (duplicates of existing rows removed).
        public let drafts: [Draft]
        /// Valid rows that matched an existing transaction.
        public let duplicateCount: Int
        /// Flutter's messages, e.g. `Row 3: invalid date "2026-02-30"`, in
        /// file order. The UI shows only their count (as Flutter).
        public let rowErrors: [String]
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Empty file, or a first row that is not the five header cells.
        case notATransactionsCSV
        /// Swift only (D6): the picked file's bytes could not be read.
        /// Flutter returns silently when `bytes == null`.
        case unreadableFile
        /// Swift only: the picked file is larger than `maximumFileBytes`,
        /// refused before it is read (Flutter reads any size).
        case fileTooLarge

        /// The bare message the toast shows (D6: Flutter shows
        /// `e.toString()`, "FormatException: ...").
        public var message: String {
            switch self {
            case .notATransactionsCSV: "Not a valid transactions CSV export"
            case .unreadableFile: "The file could not be read"
            case .fileTooLarge: "The file is larger than 50 MB"
            }
        }

        /// Dart's `e.toString()` for the failure Flutter has.
        public var flutterDescription: String? {
            switch self {
            case .notATransactionsCSV: "FormatException: Not a valid transactions CSV export"
            case .unreadableFile, .fileTooLarge: nil
            }
        }
    }

    /// The largest file either import reads (a CSV or a backup): 50 MB,
    /// far above any real export (10,000 transactions are about 1 MB as a
    /// backup), so a file picked by mistake is refused before it is read.
    public static let maximumFileBytes = 50 * 1024 * 1024

    // MARK: - Decode and parse

    /// `utf8.decode(bytes, allowMalformed: true)` (settings_page.dart:138):
    /// drops one leading EF BB BF; malformed sequences become U+FFFD.
    public static func decode(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        if slice.starts(with: [0xEF, 0xBB, 0xBF]) { slice = slice.dropFirst(3) }
        return String(decoding: slice, as: UTF8.self)
    }

    /// `decode` then `parse(text:existing:calendar:)`. The decoded string
    /// is dropped once its UTF-16 units are taken, so it is not held
    /// during the parse.
    public static func parse(
        bytes: [UInt8], existing: [TransactionRecord], calendar: DartCalendar
    ) throws(Failure) -> Summary {
        try parse(units: Array(decode(bytes).utf16), existing: existing, calendar: calendar)
    }

    /// `parseTransactionsCsv`: header check, per-row validation in Flutter's
    /// order with its exact messages, then a multiset dedupe against
    /// `existing` (the readable transactions). Pure.
    public static func parse(
        text: String, existing: [TransactionRecord], calendar: DartCalendar
    ) throws(Failure) -> Summary {
        try parse(units: Array(text.utf16), existing: existing, calendar: calendar)
    }

    private static func parse(
        units: consuming [UInt16], existing: [TransactionRecord], calendar: DartCalendar
    ) throws(Failure) -> Summary {
        if units.first == 0xFEFF { units.removeFirst() }  // :1045-1048, a second BOM
        let rows = CSVParser.parse(units: consume units)

        func trimmed(_ cell: [UInt16]) -> String { DartString.trim(String(decoding: cell, as: UTF16.self)) }
        // :1058-1066
        guard let header = rows.first, header.count == 5,
            zip(header, ["date", "type", "category", "description", "amount"]).allSatisfy({
                DartString.equal(DartString.lowercase(trimmed($0)), $1)
            })
        else { throw .notATransactionsCSV }

        var parsed: [Draft] = []
        var errors: [String] = []
        // Row 1 is the header; records are numbered by CSV record, blank
        // ones included.
        for i in rows.indices.dropFirst() {
            let rowNumber = i + 1
            let row = rows[i]
            if row.allSatisfy({ trimmed($0).isEmpty }) { continue }
            if row.count != 5 {
                errors.append("Row \(rowNumber): expected 5 columns but found \(row.count)")
                continue
            }

            // Dart normalises out-of-range fields (2026-02-30 is March 2),
            // so the text must start with the parsed day.
            let dateText = trimmed(row[0])
            guard let date = calendar.tryParse(dateText), DartString.hasPrefix(dateText, DartDateFormat.yyyyMMdd(date)) else {
                errors.append("Row \(rowNumber): invalid date \"\(dateText)\"")
                continue
            }

            let typeText = trimmed(row[1])
            let typeLower = DartString.lowercase(typeText)
            let type: TransactionType
            if DartString.equal(typeLower, "income") {
                type = .income
            } else if DartString.equal(typeLower, "expense") {
                type = .expense
            } else {
                errors.append("Row \(rowNumber): invalid type \"\(typeText)\"")
                continue
            }

            let category = trimmed(row[2])
            if category.isEmpty {
                errors.append("Row \(rowNumber): category is empty")
                continue
            }
            let description = trimmed(row[3])

            // One leading "$"; commas only as US thousands separators.
            let amountText = trimmed(row[4])
            var value = Array(amountText.utf16)
            if value.first == 0x24 { value.removeFirst() }
            if value.contains(0x2C) {
                guard isUSThousands(value) else {
                    errors.append("Row \(rowNumber): invalid amount \"\(amountText)\"")
                    continue
                }
                value.removeAll { $0 == 0x2C }
            }
            guard let amount = DartDouble.tryParse(String(decoding: value, as: UTF16.self)), amount.isFinite, !(amount < 0) else {
                errors.append("Row \(rowNumber): invalid amount \"\(amountText)\"")
                continue
            }
            parsed.append(Draft(date: date, type: type, category: category, description: description, amount: amount))
        }

        // Each existing row cancels one identical incoming row; identical
        // rows within the file stay distinct.
        // A stored name can hold a lone surrogate, which a Swift String
        // cannot: key existing rows by their stored code units.
        var counts: [[UInt16]: Int] = [:]
        for t in existing {
            let category = t.raw["category"]?.stringCodeUnits ?? Array(t.category.utf16)
            let description = t.raw["description"]?.stringCodeUnits ?? Array(t.description.utf16)
            counts[dedupeKey(t.date, t.type, category, description, t.amount), default: 0] += 1
        }
        var drafts: [Draft] = []
        var duplicates = 0
        for d in parsed {
            let key = dedupeKey(d.date, d.type, Array(d.category.utf16), Array(d.description.utf16), d.amount)
            if let remaining = counts[key], remaining > 0 {
                counts[key] = remaining - 1
                duplicates += 1
            } else {
                drafts.append(d)
            }
        }
        return Summary(drafts: drafts, duplicateCount: duplicates, rowErrors: errors)
    }

    /// `^\d{1,3}(,\d{3})+(\.\d+)?$` (Dart's `\d` is ASCII only).
    static func isUSThousands(_ u: [UInt16]) -> Bool {
        func digit(_ i: Int) -> Bool { i < u.count && (0x30...0x39).contains(u[i]) }
        var i = 0
        while digit(i) { i += 1 }
        guard (1...3).contains(i) else { return false }
        var groups = 0
        while i < u.count, u[i] == 0x2C {
            guard digit(i + 1), digit(i + 2), digit(i + 3) else { return false }
            i += 4
            groups += 1
        }
        guard groups >= 1 else { return false }
        if i == u.count { return true }
        guard u[i] == 0x2E, digit(i + 1) else { return false }
        i += 1
        while digit(i) { i += 1 }
        return i == u.count
    }

    /// `_csvDedupeKey` as UTF-16 code units: Dart compares strings by code
    /// unit, Swift `String` by canonical equivalence (NFC and NFD "café" are
    /// different keys in Dart). Joined by `|` without escaping, as Dart.
    static func dedupeKey(
        _ date: DartDateTime, _ type: TransactionType, _ category: [UInt16], _ description: [UInt16], _ amount: Double
    ) -> [UInt16] {
        var key = Array(DartDateFormat.yyyyMMdd(date).utf16)
        for part in [Array(type.rawValue.utf16), DartString.trimUnits(category), DartString.trimUnits(description), Array(DartFixed.toStringAsFixed(amount, 2).utf16)] {
            key.append(0x7C)
            key.append(contentsOf: part)
        }
        return key
    }

    // MARK: - Copy

    public enum Tone: Sendable, Hashable {
        /// Flutter's default SnackBar (no colour override).
        case neutral
        case success
        case error
    }

    public struct Message: Sendable, Hashable {
        public let text: String
        public let tone: Tone
    }

    public static let cancelButtonTitle = "Cancel"
    public static let importButtonTitle = "Import"

    /// "1 transaction", "2 transactions" (D6: Flutter always uses the plural).
    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    /// "Could not import: {message}" (red). D6: the bare message, where
    /// Flutter prints `e.toString()` ("FormatException: ...").
    public static func failureMessage(_ failure: Failure) -> Message {
        Message(text: "Could not import: \(failure.message)", tone: .error)
    }
}

extension CSVImport.Summary {
    /// The toast when there is nothing to import (settings_page.dart:141-166),
    /// red only when some rows could not be read; nil when there are drafts.
    public var emptyResultMessage: CSVImport.Message? {
        guard drafts.isEmpty else { return nil }
        let errors = rowErrors.count
        if errors > 0 {
            let rows = CSVImport.count(errors, "row", "rows")
            let text = duplicateCount > 0
                ? "No new transactions: \(CSVImport.count(duplicateCount, "duplicate", "duplicates")) skipped, \(rows) could not be read"
                : "No transactions imported: \(rows) could not be read"
            return CSVImport.Message(text: text, tone: .error)
        }
        return CSVImport.Message(
            text: duplicateCount > 0 ? "All transactions in this file already exist" : "No transactions found in this file",
            tone: .neutral)
    }

    /// `_confirmImport` title: "Import 3 transactions?".
    public var confirmTitle: String {
        "Import \(CSVImport.count(drafts.count, "transaction", "transactions"))?"
    }

    /// The dialog body lines (none when nothing was skipped).
    public var confirmDetails: [String] {
        var details: [String] = []
        if duplicateCount > 0 { details.append("\(CSVImport.count(duplicateCount, "duplicate", "duplicates")) will be skipped") }
        if !rowErrors.isEmpty { details.append("\(CSVImport.count(rowErrors.count, "row", "rows")) could not be read") }
        return details
    }

    /// `confirmDetails` joined by newlines, or nil (Flutter's `content: null`).
    public var confirmMessage: String? {
        confirmDetails.isEmpty ? nil : confirmDetails.joined(separator: "\n")
    }

    /// The green toast after a verified write (D6: Flutter shows it even
    /// when the write failed).
    public var successMessage: CSVImport.Message {
        let imported = "Imported \(CSVImport.count(drafts.count, "transaction", "transactions"))"
        return CSVImport.Message(
            text: duplicateCount > 0
                ? "\(imported), \(CSVImport.count(duplicateCount, "duplicate", "duplicates")) skipped" : imported,
            tone: .success)
    }
}

extension FinancialData {
    public struct CSVImportResult: Sendable {
        /// The data after the import.
        public let data: FinancialData
        /// The new rows, in file order.
        public let imported: [TransactionRecord]
        /// Definitions made for category names the ledger now uses without
        /// one (the launch pass, run in the same commit).
        public let addedCategories: [CategoryInfo]
        /// What to persist in one commit: `transactions`, plus `categories`
        /// when it changed. Empty when there is nothing to import.
        public let sections: [(String, JSONValue)]
    }

    /// `TransactionModel.importTransactions` (transaction_model.dart:1178-1193)
    /// for `summary.drafts`, pure:
    ///
    /// - each draft becomes a `Transaction.toJson` row appended in file
    ///   order: a new id (one already in the ledger is replaced once, as
    ///   Dart's `seenIds`), `recurringTemplateId` null, no tags;
    /// - `createdAt` = `updatedAt` = `now` + i microseconds for the i-th row
    ///   (D6: Dart's per-row `DateTime.now()` can repeat, which leaves the
    ///   same-day order to the random ids; this keeps the last file row on
    ///   top);
    /// - then the naming step of the launch pass for the imported rows,
    ///   which Flutter runs at its next launch: a category name without a
    ///   definition gets one in the same commit, so the end state equals
    ///   Flutter's after a relaunch. Only the imported names: the other
    ///   rows' names were materialised when this data was loaded (running
    ///   the whole pass again would re-add a padded legacy name once more,
    ///   see PARITY_GAPS).
    public func importTransactions(_ summary: CSVImport.Summary, now: DartDateTime, newID: () -> String) -> CSVImportResult {
        guard !summary.drafts.isEmpty else {
            return CSVImportResult(data: self, imported: [], addedCategories: [], sections: [])
        }
        var next = self
        var seen = Set(transactions.map { Array($0.id.utf16) })
        var imported: [TransactionRecord] = []
        for (index, draft) in summary.drafts.enumerated() {
            var id = newID()
            if !seen.insert(Array(id.utf16)).inserted {
                id = newID()
                seen.insert(Array(id.utf16))
            }
            let at = now.adding(microseconds: Int64(index))
            let record = TransactionRecord.make(
                id: id, type: draft.type, description: draft.description, amount: draft.amount, category: draft.category,
                date: draft.date, now: at)
            next.transactionRows.append(.record(record))
            imported.append(record)
        }

        let countBefore = next.categoryRows.count
        var sections = [(Section.transactions, next.transactionsSection())]
        if next.materializeCategories(imported.map { ($0.type, $0.category) }, newID: newID) {
            sections.append((Section.categories, next.categoriesSection()))
        }
        return CSVImportResult(
            data: next, imported: imported, addedCategories: next.categoryRows.dropFirst(countBefore).compactMap(\.record),
            sections: sections)
    }
}
