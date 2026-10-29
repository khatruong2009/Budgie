import Foundation
import Testing

@testable import BudgieCore

private let zone = TimeZone(identifier: "America/New_York")!
private let calendar = DartCalendar(timeZone: zone)
private let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)

private func emptyData() -> FinancialData {
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: JSONObject()), preferences: InMemoryPreferences(), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }
    ).data
}

private struct Sample {
    var type: TransactionType
    var description: String
    var amount: Double
    var category: String
    var date: DartDateTime
}

/// `sampleTransactions` of transaction_model_csv_import_test.dart.
private let samples = [
    Sample(type: .income, description: "Salary, bonus", amount: 1234.56, category: "Income", date: calendar.date(2026, 1, 5)),
    Sample(type: .expense, description: "Book \"Dart\"", amount: 19.99, category: "Education", date: calendar.date(2026, 2, 10)),
    Sample(type: .expense, description: "line1\nline2", amount: 5.00, category: "Misc", date: calendar.date(2026, 3, 15)),
    Sample(type: .expense, description: "Milk", amount: 3.49, category: "Groceries", date: calendar.date(2026, 3, 20)),
]

/// `buildExportCsv`: the exporter's bytes for these rows.
private func exportCSV(_ rows: [Sample]) -> [UInt8] {
    CSVExport.export(rows.map {
        CSVExport.Row(date: $0.date, isIncome: $0.type == .income, category: $0.category, description: $0.description, amount: $0.amount)
    })
}

private func data(with rows: [Sample]) -> FinancialData {
    var data = emptyData()
    for row in rows {
        _ = data.addTransaction(
            type: row.type, description: row.description, amount: row.amount, category: row.category, date: row.date,
            id: UUID().uuidString.lowercased(), now: now)
    }
    return data
}

private func parse(_ text: String, existing: [TransactionRecord] = []) throws(CSVImport.Failure) -> CSVImport.Summary {
    try CSVImport.parse(text: text, existing: existing, calendar: calendar)
}

private func expectEqual(_ draft: CSVImport.Draft, _ sample: Sample, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(draft.type == sample.type, sourceLocation: sourceLocation)
    #expect(DartString.equal(draft.description, sample.description), sourceLocation: sourceLocation)
    #expect(draft.amount == sample.amount, sourceLocation: sourceLocation)
    #expect(DartString.equal(draft.category, sample.category), sourceLocation: sourceLocation)
    #expect(draft.date == sample.date, sourceLocation: sourceLocation)
}

private let header = "Date,Type,Category,Description,Amount"

/// transaction_model_csv_import_test.dart, test for test.
@Suite("CSV import: the Flutter unit tests, ported")
struct CSVImportPortedTests {
    @Test("round-trips every field through export and parse")
    func roundTrip() throws {
        let summary = try CSVImport.parse(bytes: exportCSV(samples), existing: [], calendar: calendar)
        #expect(summary.duplicateCount == 0)
        #expect(summary.rowErrors.isEmpty)
        #expect(summary.drafts.count == samples.count)
        for (draft, sample) in zip(summary.drafts, samples) { expectEqual(draft, sample) }
    }

    @Test("re-importing an export of current data yields no new transactions")
    func reimport() throws {
        let data = data(with: samples)
        let rows = data.transactions.map {
            Sample(type: $0.type, description: $0.description, amount: $0.amount, category: $0.category, date: $0.date)
        }
        let summary = try CSVImport.parse(bytes: exportCSV(rows), existing: data.transactions, calendar: calendar)
        #expect(summary.drafts.isEmpty)
        #expect(summary.duplicateCount == samples.count)
        #expect(summary.rowErrors.isEmpty)
    }

    @Test("multiset dedupe imports the surplus copy of an existing row")
    func multiset() throws {
        let existing = Sample(type: .expense, description: "Coffee", amount: 4.25, category: "Eating Out", date: calendar.date(2026, 4, 1))
        let data = data(with: [existing])
        let summary = try CSVImport.parse(bytes: exportCSV([existing, existing]), existing: data.transactions, calendar: calendar)
        #expect(summary.duplicateCount == 1)
        #expect(summary.drafts.count == 1)
        expectEqual(summary.drafts[0], existing)
    }

    @Test("re-importing a three-decimal amount still detects the duplicate")
    func threeDecimals() throws {
        let fuel = Sample(type: .expense, description: "Fuel", amount: 3.005, category: "Transport", date: calendar.date(2026, 5, 1))
        let data = data(with: [fuel])
        let summary = try CSVImport.parse(bytes: exportCSV([fuel]), existing: data.transactions, calendar: calendar)
        #expect(summary.drafts.isEmpty)
        #expect(summary.duplicateCount == 1)
    }

    @Test("dedupe ignores surrounding whitespace in text fields")
    func whitespace() throws {
        let lunch = Sample(type: .expense, description: "Lunch ", amount: 12, category: "Eating Out", date: calendar.date(2026, 5, 2))
        let data = data(with: [lunch])
        let summary = try CSVImport.parse(bytes: exportCSV([lunch]), existing: data.transactions, calendar: calendar)
        #expect(summary.drafts.isEmpty)
        #expect(summary.duplicateCount == 1)
    }

    @Test("parses an LF-only file the same as CRLF")
    func lfOnly() throws {
        let crlf = String(decoding: exportCSV(samples), as: UTF8.self)
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        #expect(!lf.utf16.contains(0x0D))
        let summary = try parse(lf)
        #expect(summary.rowErrors.isEmpty)
        #expect(summary.duplicateCount == 0)
        #expect(summary.drafts.count == samples.count)
        for (draft, sample) in zip(summary.drafts, samples) { expectEqual(draft, sample) }
    }

    @Test("strips a leading UTF-8 BOM (and a second one, as utf8.decode and the parser each drop one)")
    func bom() throws {
        let text = String(decoding: exportCSV(samples), as: UTF8.self)
        #expect(try parse("\u{FEFF}" + text).drafts.count == samples.count)
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        for prefix in [bom, bom + bom, bom + bom + bom] {
            let summary = try CSVImport.parse(bytes: prefix + exportCSV(samples), existing: [], calendar: calendar)
            #expect(summary.rowErrors.isEmpty)
            #expect(summary.drafts.count == samples.count)
        }
    }

    @Test("accepts a lowercase header")
    func lowercaseHeader() throws {
        let summary = try parse("date,type,category,description,amount\r\n2026-01-01,income,Salary,Paycheck,1000.00")
        #expect(summary.rowErrors.isEmpty)
        #expect(summary.drafts.first?.amount == 1000)
        #expect(summary.drafts.first?.type == .income)
    }

    @Test("throws on empty content and a wrong header")
    func throwsOnHeader() {
        #expect(throws: CSVImport.Failure.notATransactionsCSV) { try parse("") }
        #expect(throws: CSVImport.Failure.notATransactionsCSV) {
            try parse("When,Kind,Bucket,Note,Value\r\n2026-01-01,Income,Salary,Paycheck,1000.00")
        }
    }

    @Test("reports row errors while still importing valid rows")
    func rowErrors() throws {
        let summary = try parse(
            "\(header)\r\n"
                + "2026-01-02,Income,Salary,Paycheck,1000.00\r\n"
                + "\"abc\",Expense,Food,Bad date,5.00\r\n"
                + "2026-01-03,Transfer,Food,Bad type,5.00\r\n"
                + "2026-01-04,Expense,Food,Bad amount,xyz\r\n"
                + "2026-01-05,Expense,Food,Only four columns\r\n"
                + "2026-01-06,Expense,Groceries,Milk,3.50")
        #expect(summary.drafts.map(\.amount) == [1000, 3.5])
        #expect(summary.rowErrors == [
            "Row 3: invalid date \"abc\"",
            "Row 4: invalid type \"Transfer\"",
            "Row 5: invalid amount \"xyz\"",
            "Row 6: expected 5 columns but found 4",
        ])
    }

    @Test("rejects impossible dates instead of rolling them over")
    func impossibleDates() throws {
        let summary = try parse(
            "\(header)\r\n2026-02-30,Expense,Food,Bad day,5.00\r\n2026-13-05,Expense,Food,Bad month,5.00\r\n2026-01-15,Expense,Food,Valid,5.00")
        #expect(summary.drafts.map(\.description) == ["Valid"])
        #expect(summary.rowErrors == ["Row 2: invalid date \"2026-02-30\"", "Row 3: invalid date \"2026-13-05\""])
    }

    @Test("rejects European decimal-comma amounts instead of mangling them")
    func europeanCommas() throws {
        let summary = try parse(
            "\(header)\r\n2026-01-01,Expense,Food,European format,\"1.234,56\"\r\n"
                + "2026-01-02,Expense,Food,Misplaced group,\"12,34\"\r\n2026-01-03,Expense,Food,Valid grouped,\"1,234.56\"")
        #expect(summary.drafts.map(\.amount) == [1234.56])
        #expect(summary.rowErrors == ["Row 2: invalid amount \"1.234,56\"", "Row 3: invalid amount \"12,34\""])
    }

    @Test("parses a currency-formatted amount like $1,234.56")
    func currency() throws {
        let summary = try parse("\(header)\r\n2026-01-01,Income,Bonus,Year end,\"$1,234.56\"")
        #expect(summary.rowErrors.isEmpty)
        #expect(summary.drafts.first?.amount == 1234.56)
    }

    @Test("importTransactions persists rows for a fresh model to load")
    func persists() throws {
        let base = emptyData()
        let summary = try CSVImport.parse(bytes: exportCSV(samples), existing: [], calendar: calendar)
        let result = base.importTransactions(summary, now: now, newID: { UUID().uuidString.lowercased() })
        #expect(result.data.transactions.count == samples.count)
        var sections = JSONObject()
        for (name, value) in result.sections { sections[name] = value }
        let reloaded = FinancialData.load(
            FinancialSnapshot(revision: 2, sections: sections), preferences: InMemoryPreferences(), calendar: calendar,
            now: { now }, newID: { UUID().uuidString.lowercased() }
        ).data
        #expect(reloaded.transactions == result.data.transactions)
        for (record, sample) in zip(reloaded.transactions, samples) {
            #expect(record.type == sample.type && record.amount == sample.amount && record.date == sample.date)
            #expect(DartString.equal(record.description, sample.description) && DartString.equal(record.category, sample.category))
        }
    }

    @Test("importTransactions is a no-op on an empty list")
    func emptyImport() {
        let base = emptyData()
        let result = base.importTransactions(
            CSVImport.Summary(drafts: [], duplicateCount: 0, rowErrors: []), now: now, newID: { Issue.record("id drawn"); return "" })
        #expect(result.sections.isEmpty)
        #expect(result.imported.isEmpty)
        #expect(result.data.transactions.isEmpty)
    }
}

@Suite("CSV import: Swift rows, the D6 fixes and edge cases")
struct CSVImportTests {
    @Test("new rows are Dart toJson rows; createdAt strictly increases, so the last file row sorts first on its day")
    func rows() throws {
        let summary = try parse("\(header)\n2026-09-01,Expense,Food,first,1\n2026-09-01,Expense,Food,second,2\n2026-09-01,Expense,Food,third,-0\n")
        var ids = ["id-a", "id-b", "id-c"].makeIterator()
        let result = emptyData().importTransactions(summary, now: now, newID: { ids.next()! })
        #expect(result.imported.map(\.createdAt) == [now, now.adding(microseconds: 1), now.adding(microseconds: 2)])
        #expect(result.imported.map(\.updatedAt) == result.imported.map(\.createdAt))
        #expect(LedgerIndex.build(result.data.transactions, calendar: result.data.calendar).newestFirst.map(\.record.description) == ["third", "second", "first"])
        let text = DartJSON.encodeString(.object(result.imported[2].raw))
        #expect(text == #"{"id":"id-c","type":"expense","description":"third","amount":-0.0,"category":"Food","date":"2026-09-01T00:00:00.000","recurringTemplateId":null,"tagIds":[],"createdAt":"2026-09-28T09:15:30.250127","updatedAt":"2026-09-28T09:15:30.250127"}"#)
    }

    @Test("an id already in the ledger is replaced once (Dart seenIds)")
    func idCollision() throws {
        var base = emptyData()
        _ = base.addTransaction(type: .expense, description: "x", amount: 1, category: "Food", date: now, id: "taken", now: now)
        let summary = try parse("\(header)\n2026-09-01,Expense,Food,a,1\n2026-09-01,Expense,Food,b,2\n")
        var ids = ["taken", "fresh-1", "fresh-1", "fresh-2"].makeIterator()
        let result = base.importTransactions(summary, now: now, newID: { ids.next()! })
        #expect(result.imported.map(\.id) == ["fresh-1", "fresh-2"])
    }

    @Test("category names without a definition are materialised in the same commit, as the next launch would")
    func categories() throws {
        let base = emptyData()
        #expect(base.categories.contains { $0.name == "Groceries" })
        let summary = try parse(
            "\(header)\n2026-09-01,Expense,groceries,case variant,1\n2026-09-01,Expense,Coffee Shops,new,2\n"
                + "2026-09-02,Income,Coffee Shops,new income,3\n2026-09-03,Expense,Coffee Shops,again,4\n")
        let result = base.importTransactions(summary, now: now, newID: { UUID().uuidString.lowercased() })
        #expect(result.sections.map(\.0) == [Section.transactions, Section.categories])
        #expect(result.addedCategories.map { "\($0.id)|\($0.type)|\($0.name)|\($0.sortOrder)" } == [
            "expense-coffee-shops|expense|Coffee Shops|13", "income-coffee-shops|income|Coffee Shops|4",
        ])
        #expect(result.addedCategories.allSatisfy { $0.iconIdentifier == "square_grid_2x2" && $0.colorToken == "accent" && !$0.isBuiltIn })
        // Equal to what a relaunch of the committed sections produces.
        var sections = JSONObject()
        sections[Section.categories] = base.categoriesSection()
        for (name, value) in result.sections { sections[name] = value }
        let relaunched = FinancialData.load(
            FinancialSnapshot(revision: 2, sections: sections), preferences: InMemoryPreferences(), calendar: calendar,
            now: { now }, newID: { UUID().uuidString.lowercased() })
        #expect(relaunched.pendingWrites.isEmpty)
        #expect(relaunched.data.categories == result.data.categories)

        // Only known names: the commit is the transactions section alone.
        let known = try parse("\(header)\n2026-09-01,Expense,GROCERIES,x,1\n")
        #expect(base.importTransactions(known, now: now, newID: { UUID().uuidString }).sections.map(\.0) == [Section.transactions])
    }

    @Test("dedupe keys are UTF-16: NFC and NFD spellings differ; the unescaped | collides as in Dart")
    func unicodeKeys() throws {
        var base = emptyData()
        _ = base.addTransaction(type: .expense, description: "cafe\u{301}", amount: 1, category: "c", date: calendar.date(2026, 4, 1), id: "a", now: now)
        _ = base.addTransaction(type: .expense, description: "a|b", amount: 1, category: "c", date: calendar.date(2026, 4, 1), id: "b", now: now)
        let summary = try parse("\(header)\n2026-04-01,Expense,c,caf\u{E9},1\n2026-04-01,Expense,c|a,b,1\n", existing: base.transactions)
        #expect(summary.duplicateCount == 1)
        #expect(summary.drafts.map { Array($0.description.utf16) } == [Array("caf\u{E9}".utf16)])
    }

    @Test("dates: Flutter's accept/reject set, UTC for Z and offsets")
    func dates() throws {
        let cells = [
            "2026-02-29", "2024-02-29", "2026-9-1", "2026-02-15T10:30", "2026-02-15 10:30", "2026-02-15T23:30Z",
            "2026-02-15T10:00+05:30", "2026-02-15T23:30-08:00", "20260215", "02/15/2026", "0005-06-07", "0000-01-01",
            "12345-01-01", "-0001-01-01", "+002026-02-15", "2026-02-15T24:00", "2026-02-15T10:60",
        ]
        let text = header + cells.map { "\n\($0),Expense,Food,x,1" }.joined()
        let summary = try parse(text)
        #expect(summary.drafts.map { $0.date.toIso8601String() } == [
            "2024-02-29T00:00:00.000", "2026-02-15T10:30:00.000", "2026-02-15T10:30:00.000", "2026-02-15T23:30:00.000Z",
            "2026-02-15T04:30:00.000Z", "0005-06-07T00:00:00.000", "0000-01-01T00:00:00.000", "+012345-01-01T00:00:00.000",
            "2026-02-15T11:00:00.000",
        ])
        #expect(summary.rowErrors == [
            "Row 2: invalid date \"2026-02-29\"", "Row 4: invalid date \"2026-9-1\"", "Row 9: invalid date \"2026-02-15T23:30-08:00\"",
            "Row 10: invalid date \"20260215\"", "Row 11: invalid date \"02/15/2026\"", "Row 15: invalid date \"-0001-01-01\"",
            "Row 16: invalid date \"+002026-02-15\"", "Row 17: invalid date \"2026-02-15T24:00\"",
        ])
        #expect(DartDateFormat.yyyyMMdd(calendar.date(-1, 1, 1)) == "0001-01-01")
    }

    @Test("types, categories and amounts: Flutter's accept/reject set and messages")
    func fields() throws {
        // (type, category, amount cell) per data row.
        let rows: [(String, String, String)] = [
            ("INCOME", "X", "1"), ("\u{130}ncome", "X", "1"), (" Expense ", "X", "1"), ("Transfer", "X", "1"), ("", "X", "1"),
            ("Income", "  ", "1"), ("Income", "\u{A0}Food\u{A0}", "1"), ("Income", "X", "\"$1,234.50\""), ("Income", "X", "\"1,23\""),
            ("Income", "X", "-0"), ("Income", "X", "0"), ("Income", "X", "1e3"), ("Income", "X", ".5"), ("Income", "X", "5."),
            ("Income", "X", "NaN"), ("Income", "X", "0x1A"), ("Income", "X", "-5"), ("Income", "X", "+5"), ("Income", "X", "$ 5"),
            ("Income", "X", "\"$ 1,000\""), ("Income", "X", "$"), ("Income", "X", "Infinity"), ("Income", "X", "1e999"),
            ("Income", "X", "007"), ("Income", "X", "\"1,000,000.123\""), ("Income", "X", "€5"), ("Income", "X", "\"1,000,00\""),
            ("Income", "X", "1e21"), ("Income", "X", ""),
        ]
        let summary = try parse(header + rows.map { "\n2026-01-01,\($0.0),\($0.1),d,\($0.2)" }.joined())
        #expect(summary.drafts.map { "\($0.type.rawValue)|\($0.category)|\(DartDouble.format($0.amount))" } == [
            "income|X|1.0", "income|X|1.0", "expense|X|1.0", "income|Food|1.0", "income|X|1234.5", "income|X|-0.0", "income|X|0.0",
            "income|X|1000.0", "income|X|0.5", "income|X|5.0", "income|X|5.0", "income|X|5.0", "income|X|7.0", "income|X|1000000.123",
            "income|X|1e+21",
        ])
        #expect(summary.rowErrors == [
            "Row 5: invalid type \"Transfer\"", "Row 6: invalid type \"\"", "Row 7: category is empty",
            "Row 10: invalid amount \"1,23\"", "Row 16: invalid amount \"NaN\"", "Row 17: invalid amount \"0x1A\"",
            "Row 18: invalid amount \"-5\"", "Row 21: invalid amount \"$ 1,000\"", "Row 22: invalid amount \"$\"",
            "Row 23: invalid amount \"Infinity\"", "Row 24: invalid amount \"1e999\"", "Row 27: invalid amount \"€5\"",
            "Row 28: invalid amount \"1,000,00\"", "Row 30: invalid amount \"\"",
        ])
    }

    @Test("copy: Flutter's strings with singular forms (D6), tones, bare failure text")
    func copy() {
        func summary(_ drafts: Int, _ duplicates: Int, _ errors: Int) -> CSVImport.Summary {
            CSVImport.Summary(
                drafts: Array(repeating: CSVImport.Draft(date: now, type: .expense, category: "c", description: "", amount: 1), count: drafts),
                duplicateCount: duplicates, rowErrors: Array(repeating: "Row 2: category is empty", count: errors))
        }
        #expect(summary(0, 2, 3).emptyResultMessage == .init(text: "No new transactions: 2 duplicates skipped, 3 rows could not be read", tone: .error))
        #expect(summary(0, 1, 1).emptyResultMessage == .init(text: "No new transactions: 1 duplicate skipped, 1 row could not be read", tone: .error))
        #expect(summary(0, 0, 2).emptyResultMessage == .init(text: "No transactions imported: 2 rows could not be read", tone: .error))
        #expect(summary(0, 0, 1).emptyResultMessage == .init(text: "No transactions imported: 1 row could not be read", tone: .error))
        #expect(summary(0, 1, 0).emptyResultMessage == .init(text: "All transactions in this file already exist", tone: .neutral))
        #expect(summary(0, 0, 0).emptyResultMessage == .init(text: "No transactions found in this file", tone: .neutral))
        #expect(summary(1, 0, 0).emptyResultMessage == nil)

        #expect(summary(3, 0, 0).confirmTitle == "Import 3 transactions?")
        #expect(summary(1, 0, 0).confirmTitle == "Import 1 transaction?")
        #expect(summary(3, 0, 0).confirmMessage == nil)
        #expect(summary(3, 2, 4).confirmMessage == "2 duplicates will be skipped\n4 rows could not be read")
        #expect(summary(3, 1, 1).confirmDetails == ["1 duplicate will be skipped", "1 row could not be read"])
        #expect(summary(3, 0, 1).confirmDetails == ["1 row could not be read"])

        #expect(summary(3, 0, 0).successMessage == .init(text: "Imported 3 transactions", tone: .success))
        #expect(summary(1, 1, 0).successMessage == .init(text: "Imported 1 transaction, 1 duplicate skipped", tone: .success))
        #expect(summary(2, 5, 9).successMessage == .init(text: "Imported 2 transactions, 5 duplicates skipped", tone: .success))

        #expect(CSVImport.failureMessage(.notATransactionsCSV) == .init(text: "Could not import: Not a valid transactions CSV export", tone: .error))
        #expect(CSVImport.Failure.notATransactionsCSV.flutterDescription == "FormatException: Not a valid transactions CSV export")
        #expect(CSVImport.failureMessage(.unreadableFile) == .init(text: "Could not import: The file could not be read", tone: .error))
        #expect(CSVImport.failureMessage(.fileTooLarge) == .init(text: "Could not import: The file is larger than 50 MB", tone: .error))
        #expect(CSVImport.maximumFileBytes == 52_428_800)
        #expect(CSVImport.cancelButtonTitle == "Cancel" && CSVImport.importButtonTitle == "Import")
    }

    @Test("decode: one EF BB BF dropped, malformed bytes become U+FFFD")
    func decode() {
        #expect(Array(CSVImport.decode([0xEF, 0xBB, 0xBF, 0x61]).utf16) == [0x61])
        #expect(Array(CSVImport.decode([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61]).utf16) == [0xFEFF, 0x61])
        #expect(Array(CSVImport.decode([0x63, 0x61, 0x66, 0xE9]).utf16) == [0x63, 0x61, 0x66, 0xFFFD])
    }

    @Test("far dates sort and index without trapping")
    func farDates() throws {
        let summary = try parse("\(header)\n0000-01-01,Expense,Food,a,1\n12345-01-01,Expense,Food,b,1\n275759-01-01,Expense,Food,c,1\n")
        #expect(summary.drafts.count == 3)
        let data = emptyData().importTransactions(summary, now: now, newID: { UUID().uuidString.lowercased() }).data
        #expect(LedgerIndex.build(data.transactions, calendar: data.calendar).newestFirst.map(\.record.description) == ["c", "b", "a"])
        #expect(LedgerIndex.build(data.transactions, calendar: data.calendar).availableMonths.count == 3)
    }

    @Test("20,000 rows parse and dedupe quickly")
    func volume() throws {
        var text = header
        for i in 0..<20_000 { text += "\r\n2026-\(String(format: "%02d", i % 12 + 1))-15,Expense,Cat \(i % 40),\"Row, \(i)\",\(i).25" }
        let existing = data(with: (0..<2000).map {
            Sample(type: .expense, description: "Row, \($0)", amount: Double($0) + 0.25, category: "Cat \($0 % 40)",
                   date: calendar.date(2026, $0 % 12 + 1, 15))
        }).transactions
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let summary = try parse(text, existing: existing)
            #expect(summary.drafts.count == 18_000 && summary.duplicateCount == 2000)
        }
        #expect(elapsed < .seconds(10))  // about 1 s in a debug build; slack for a loaded machine
    }
}

/// Whether the exported amount (`toStringAsFixed(2)`) is rejected on import:
/// negative after rounding ("-12.50"; "-0.00" is accepted as -0.0).
private func rejectedOnImport(_ amount: Double) -> Bool {
    DartDouble.tryParse(DartFixed.toStringAsFixed(amount, 2))! < 0
}

@Suite("CSV import: CSVExport output round-trips through the importer")
struct CSVImportRoundTripTests {
    @Test("a store's export imports into itself as all duplicates, and into an empty store as its rows", arguments: ["typical", "large_10k"])
    func stores(_ name: String) async throws {
        let scenario = try Scenario(Fixtures.url("store/\(name)"))
        guard let data = try await launch(scenario) else { Issue.record("launch"); return }
        let bytes = CSVExport.export(data.transactions.map {
            CSVExport.Row(date: $0.date, isIncome: $0.type == .income, category: $0.category, description: $0.description, amount: $0.amount)
        })
        let into = try CSVImport.parse(bytes: bytes, existing: data.transactions, calendar: data.calendar)
        // Negative amounts export as "-12.50" and are rejected on import
        // (both apps). A stored lone surrogate exports as U+FFFD, so that
        // row comes back as a new one (both apps; typical has one). Every
        // other row is a duplicate of itself.
        let negatives = data.transactions.filter { rejectedOnImport($0.amount) }.count
        let lossy = data.transactions.filter { t in
            !rejectedOnImport(t.amount)
                && (t.raw["description"]?.stringCodeUnits != Array(t.description.utf16)
                    || t.raw["category"]?.stringCodeUnits != Array(t.category.utf16))
        }.count
        #expect(into.drafts.count == lossy)
        #expect(into.duplicateCount == data.transactions.count - negatives - lossy)
        #expect(into.rowErrors.count == negatives)
        #expect(into.rowErrors.allSatisfy { $0.contains("invalid amount \"-") })

        let fresh = try CSVImport.parse(bytes: bytes, existing: [], calendar: data.calendar)
        #expect(fresh.drafts.count == data.transactions.count - negatives)
        let imported = emptyData().importTransactions(fresh, now: now, newID: { UUID().uuidString.lowercased() }).data
        let again = try CSVImport.parse(bytes: bytes, existing: imported.transactions, calendar: data.calendar)
        #expect(again.drafts.isEmpty && again.duplicateCount == fresh.drafts.count)
    }

    @Test("the Dart export in Fixtures/logic/csv_export.json imports into an empty store")
    func dartExport() throws {
        let fixture = try Fixtures.jsonObject("logic/csv_export.json") as! [String: Any]
        let bytes = [UInt8](Data(base64Encoded: fixture["base64"] as! String)!)
        let summary = try CSVImport.parse(bytes: bytes, existing: [], calendar: DartCalendar(timeZone: TimeZone(identifier: "UTC")!))
        let transactions = fixture["transactions"] as! [[String: Any]]
        let negatives = transactions.filter { rejectedOnImport(($0["amount"] as! NSNumber).doubleValue) }.count
        #expect(summary.drafts.count + summary.rowErrors.count == transactions.count)
        #expect(summary.rowErrors.count == negatives)
    }
}
