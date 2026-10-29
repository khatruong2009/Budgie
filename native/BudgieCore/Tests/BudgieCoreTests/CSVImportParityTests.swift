import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("csvimport/\(name)")
}

private func units(_ value: J) -> [UInt16] { value.array.map { UInt16($0.int!) } }

private func bytes(_ base64: J) -> [UInt8] { [UInt8](Data(base64Encoded: base64.string!)!) }

/// Same UTF-16 code units (Swift `==` on String is canonical equivalence).
private func same(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): DartString.equal(a, b)
    default: false
    }
}

/// D6 singular forms: Flutter's text with "1 transactions", "1 duplicates"
/// and "1 rows" in the singular, which is what Swift shows.
func csvImportSingular(_ flutter: String) -> String {
    var text = flutter
    for (plural, singular) in [("transactions", "transaction"), ("duplicates", "duplicate"), ("rows", "row")] {
        text = text.replacingOccurrences(of: "(?<![0-9])1 \(plural)\\b", with: "1 \(singular)", options: .regularExpression)
    }
    return text
}

/// D6 bare failure text: Flutter prints `e.toString()`.
func csvImportBareFailure(_ flutter: String) -> String {
    flutter.replacingOccurrences(of: "Could not import: FormatException: ", with: "Could not import: ")
}

/// Where two byte strings first differ, with some context.
private func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> String {
    var i = 0
    while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
    let from = max(0, i - 120)
    return "at \(i): swift «\(String(decoding: a[from..<min(a.count, i + 120)], as: UTF8.self))» "
        + "dart «\(String(decoding: b[from..<min(b.count, i + 120)], as: UTF8.self))»"
}

let csvImportZones = ["America/New_York", "UTC", "Australia/Lord_Howe", "Asia/Kolkata", "America/Santiago"]

private func load(_ sections: JSONObject, prefs: [String: PreferenceValue] = [:], calendar: DartCalendar, now: DartDateTime)
    -> FinancialData
{
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences(prefs), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }, matchesPaddedCategoryNames: false
    ).data
}

private func transactionsSection(_ text: String) throws -> JSONObject {
    JSONObject(ordered: [(Section.transactions, try JSONParser.parse(Array(text.utf8)))])
}

/// The summary and the copy against Dart's (`summaryJson`, `messages`).
private func expectSummary(_ summary: CSVImport.Summary, _ expected: J, messages: J, _ label: String) {
    let drafts = summary.drafts.map { d in
        [Array(d.date.toIso8601String().utf16), Array(d.type.rawValue.utf16), Array(d.category.utf16), Array(d.description.utf16),
         Array(DartDouble.format(d.amount).utf16)]
    }
    let dart = expected["drafts"].array.map { row in
        [Array(row[0].string!.utf16), Array(row[1].string!.utf16), units(row[2]), units(row[3]), Array(row[4].string!.utf16)]
    }
    #expect(drafts == dart, "\(label) drafts")
    #expect(summary.duplicateCount == expected["duplicateCount"].int, "\(label) duplicates")
    #expect(summary.rowErrors.map { Array($0.utf16) } == expected["rowErrors"].array.map(units), "\(label) row errors")

    if messages["empty"].isNull {
        #expect(summary.emptyResultMessage == nil, "\(label) empty")
    } else {
        let empty = summary.emptyResultMessage
        #expect(same(empty?.text, csvImportSingular(messages["empty"]["text"].string!)), "\(label) empty text")
        #expect(empty?.tone == (messages["empty"]["red"].bool! ? .error : .neutral), "\(label) empty tone")
    }
    #expect(same(summary.confirmTitle, csvImportSingular(messages["confirmTitle"].string!)), "\(label) confirm title")
    #expect(same(summary.confirmMessage, messages["confirmContent"].string.map(csvImportSingular)), "\(label) confirm body")
    #expect(same(summary.successMessage.text, csvImportSingular(messages["success"].string!)), "\(label) success")
    #expect(summary.successMessage.tone == .success)
}

private func expectFailure(_ failure: CSVImport.Failure?, _ item: J, _ label: String) {
    #expect(failure == .notATransactionsCSV, "\(label) throws")
    #expect(same(failure?.flutterDescription, item["error"].string), "\(label) error")
    #expect(same(failure.map { CSVImport.failureMessage($0).text }, csvImportBareFailure(item["failure"].string!)), "\(label) failure")
}

@Suite("CSV import: parser, decode, validation, dedupe, copy and commit match Flutter (Fixtures/csvimport)")
struct CSVImportParityTests {
    @Test("csv 6.0.0 on the corpus and 3000 random strings; utf8.decode(allowMalformed) on 2000 byte strings")
    func parser() throws {
        let f = try fixture("parser.json")
        let cases = f["cases"].array
        #expect(cases.count > 3000)
        var mismatches: [String] = []
        for item in cases {
            let rows = CSVParser.parse(units: units(item["input"]))
            let expected = item["rows"].array.map { $0.array.map(units) }
            if rows != expected { mismatches.append(item["name"].string!) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) parser mismatches: \(mismatches.prefix(20))")

        let decode = f["decode"].array
        #expect(decode.count == 2000)
        var decodeMismatches: [String] = []
        for item in decode {
            let hex = item["hex"].string!
            let input = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            if Array(CSVImport.decode(input).utf16) != units(item["units"]) { decodeMismatches.append(hex) }
        }
        #expect(decodeMismatches.isEmpty, "\(decodeMismatches.count) decode mismatches: \(decodeMismatches.prefix(20))")
    }

    /// The corpus through a real Dart store: Swift loads the store Dart had
    /// before the import, parses the same bytes, and its one commit writes
    /// the transactions Dart's import wrote (new ids as "<new:N>"; D6:
    /// createdAt = launch + N microseconds where Dart's are all the pinned
    /// launch clock) and the categories Dart's next launch writes.
    @Test("adversarial corpus and 600 random files", arguments: csvImportZones)
    func imports(_ zone: String) throws {
        let f = try Fixtures.json("\(Fixtures.zonePath("csvimport", zone))/import.json")
        #expect(f["tz"].string == zone)
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let now = try calendar.parse(f["now"].string!)
        let cases = f["cases"].array
        #expect(cases.count >= 45)
        var committed = 0
        var singular = 0

        for item in cases {
            let label = "\(zone) \(item["name"].string!)"
            let before = try JSONParser.parse(Array(item["before"].string!.utf8)).objectValue!
            let data = load(before, prefs: typedPreferences(item["prefs"]), calendar: calendar, now: now)
            let input = bytes(item["bytes"])
            var text = Array(CSVImport.decode(input).utf16)
            if text.first == 0xFEFF { text.removeFirst() }
            #expect(CSVParser.parse(units: text) == item["csvRows"].array.map { $0.array.map(units) }, "\(label) csv rows")

            let summary: CSVImport.Summary
            do {
                summary = try CSVImport.parse(bytes: input, existing: data.transactions, calendar: calendar)
            } catch {
                expectFailure(error, item, label)
                continue
            }
            #expect(item["error"].isNull, "\(label) Dart threw \(item["error"].string ?? "")")
            expectSummary(summary, item["summary"], messages: item["messages"], label)
            if !same(summary.confirmTitle + (summary.confirmMessage ?? "") + summary.successMessage.text,
                     item["messages"]["confirmTitle"].string! + (item["messages"]["confirmContent"].string ?? "")
                        + item["messages"]["success"].string!)
            {
                singular += 1
            }

            let result = data.importTransactions(summary, now: now, newID: { UUID().uuidString.lowercased() })
            let after = item["after"]
            guard !summary.drafts.isEmpty else {
                #expect(after.isNull && result.sections.isEmpty, "\(label) nothing to commit")
                continue
            }
            committed += 1
            #expect(after["revisionDelta"].int == 1 && after["hasUnsavedChanges"].bool == false, "\(label) one Dart commit")
            #expect(result.sections.map(\.0) == [Section.transactions] + (result.addedCategories.isEmpty ? [] : [Section.categories]),
                    "\(label) sections")
            #expect(result.data.transactions.count == after["reloadedCount"].int, "\(label) count")

            // Transactions: the new rows equal Dart's (new ids and the D6
            // timestamps normalised). The rows already stored stay exactly
            // as they were (Swift patches in place; Flutter rewrites the
            // whole section in `toJson` form, which differs only for rows it
            // did not write itself, e.g. typical's New York midnight read in
            // Santiago, where that midnight does not exist).
            var known = Set<[UInt16]>()
            for row in before[Section.transactions]?.arrayValue ?? [] {
                if case .string(let id)? = row.objectValue?["id"] { known.insert(id.codeUnits) }
            }
            var n = 0
            var kept: [JSONValue] = []
            var added: [JSONValue] = []
            for row in result.data.transactionsSection().arrayValue! {
                guard var object = row.objectValue, case .string(let id)? = object["id"], !known.contains(id.codeUnits) else {
                    kept.append(row)
                    continue
                }
                let created = now.adding(microseconds: Int64(n)).toIso8601String()
                #expect(object["createdAt"]?.stringValue == created && object["updatedAt"]?.stringValue == created, "\(label) D6 createdAt \(n)")
                object["id"] = .string("<new:\(n)>")
                object["createdAt"] = .string(now.toIso8601String())
                object["updatedAt"] = .string(now.toIso8601String())
                added.append(.object(object))
                n += 1
            }
            #expect(n == summary.drafts.count)
            let dartRows = try JSONParser.parse(Array(after["transactions"].string!.utf8)).arrayValue!
            let dartAdded = dartRows.filter { $0.objectValue?["id"]?.stringValue?.hasPrefix("<new:") == true }
            #expect(dartRows.count - dartAdded.count == kept.count, "\(label) kept rows")
            #expect(DartJSON.encode(.array(kept)) == DartJSON.encode(before[Section.transactions] ?? .array([])), "\(label) kept verbatim")
            let swiftAdded = DartJSON.encode(.array(added), mode: .dartCanonical)
            let expectedAdded = DartJSON.encode(.array(dartAdded), mode: .dartCanonical)
            #expect(swiftAdded == expectedAdded, "\(label) new rows \(firstDifference(swiftAdded, expectedAdded))")

            // Categories: what Dart's relaunch wrote; new uuid ids normalised.
            var knownCategories = Set<[UInt16]>()
            for row in before[Section.categories]?.arrayValue ?? [] {
                if case .string(let id)? = row.objectValue?["id"] { knownCategories.insert(id.codeUnits) }
            }
            let categories = result.data.categoriesSection().arrayValue!.map { row -> JSONValue in
                guard var object = row.objectValue, case .string(let id)? = object["id"], !knownCategories.contains(id.codeUnits)
                else { return row }
                for type in ["income", "expense"] where id.value.hasPrefix("\(type)-")
                    && UUID(uuidString: String(id.value.dropFirst(type.count + 1))) != nil
                {
                    object["id"] = .string("\(type)-<uuid>")
                }
                return .object(object)
            }
            let swiftCategories = DartJSON.encode(.array(categories), mode: .dartCanonical)
            #expect(swiftCategories == Array(after["categories"].string!.utf8),
                    "\(label) categories section \(firstDifference(swiftCategories, Array(after["categories"].string!.utf8)))")
        }
        #expect(committed >= 30)
        #expect(singular >= 1, "the singular-copy difference is exercised")

        let random = f["random"].array
        #expect(random.count == 600)
        for (index, item) in random.enumerated() {
            let label = "\(zone) random \(index)"
            let data = load(try transactionsSection(item["existing"].string!), calendar: calendar, now: now)
            do {
                let summary = try CSVImport.parse(bytes: bytes(item["bytes"]), existing: data.transactions, calendar: calendar)
                #expect(item["error"].isNull, "\(label) Dart threw")
                expectSummary(summary, item["summary"], messages: item["messages"], label)
            } catch {
                expectFailure(error, item, label)
            }
        }
    }

    /// The real Settings page (fake file picker): its dialog and SnackBar
    /// are Swift's copy with the D6 singular forms and bare failure text,
    /// the neutral SnackBars are the neutral tone, and the store is written
    /// exactly when Swift would commit.
    @Test("the real Settings page's dialog and SnackBars")
    func page() throws {
        let f = try fixture("page.json")
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)
        let cases = f["cases"].array
        #expect(cases.count == 14)
        for item in cases {
            let label = item["name"].string!
            let cancel = item["cancel"].bool ?? false
            #expect(item["picker"]["type"].string == "custom" && item["picker"]["withData"].bool == true, "\(label) picker")
            #expect(item["picker"]["allowedExtensions"].array.map(\.string) == ["csv"], "\(label) extensions")
            let dialog = item["dialog"], snackbar = item["snackbar"]
            guard !item["bytes"].isNull else {
                // Cancelled picker: nothing shown, nothing written (Swift too).
                #expect(dialog.isNull && snackbar.isNull && item["storeWritten"].bool == false, "\(label)")
                continue
            }
            let data = load(try transactionsSection(item["existing"].string!), calendar: calendar, now: now)
            let summary: CSVImport.Summary
            do {
                summary = try CSVImport.parse(bytes: bytes(item["bytes"]), existing: data.transactions, calendar: calendar)
            } catch {
                let message = CSVImport.failureMessage(error)
                #expect(dialog.isNull, "\(label)")
                #expect(same(message.text, csvImportBareFailure(snackbar["text"].string!)) && message.tone == .error, "\(label)")
                #expect(snackbar["color"].string == "expense", "\(label)")
                continue
            }
            if let empty = summary.emptyResultMessage {
                #expect(dialog.isNull, "\(label)")
                #expect(same(empty.text, csvImportSingular(snackbar["text"].string!)), "\(label)")
                #expect(snackbar["color"].string == (empty.tone == .error ? "expense" : "default"), "\(label)")
                #expect(item["storeWritten"].bool == false, "\(label)")
                continue
            }
            #expect(same(summary.confirmTitle, csvImportSingular(dialog["title"].string!)), "\(label)")
            #expect(same(summary.confirmMessage, dialog["content"].string.map(csvImportSingular)), "\(label)")
            #expect(dialog["buttons"].array.map(\.string) == [CSVImport.cancelButtonTitle, CSVImport.importButtonTitle], "\(label)")
            if cancel {
                #expect(snackbar.isNull && item["storeWritten"].bool == false, "\(label)")
            } else {
                #expect(same(summary.successMessage.text, csvImportSingular(snackbar["text"].string!)), "\(label)")
                #expect(snackbar["color"].string == "income", "\(label)")
                #expect(item["storeWritten"].bool == true, "\(label)")
            }
        }
    }
}
