import Foundation
import Testing

@testable import BudgieCore

@Suite("Dart semantics: object keys and blank ids")
struct DartSemanticsFixTests {
    @Test("object keys compare as UTF-16 code units: NFC and NFD differ, escaped spellings match")
    func codeUnitKeys() throws {
        guard case .object(var object) = try JSONParser.parse(#"{"Café":1,"Café":2,"A":3,"A":4}"#) else {
            Issue.record()
            return
        }
        #expect(object.keys.count == 3)
        #expect(object["Café"]?.numberValue?.lexeme == "1")
        #expect(object["Cafe\u{301}"]?.numberValue?.lexeme == "2")
        #expect(object["A"]?.numberValue?.lexeme == "4")
        #expect(object.contains("Cafe\u{301}"))
        object["Cafe\u{301}"] = nil
        #expect(object["Café"]?.numberValue?.lexeme == "1")
        #expect(!object.contains("Cafe\u{301}"))
        object["A"] = .int(5)
        #expect(DartJSON.encodeString(.object(object)) == #"{"Café":1,"A":5}"#)
    }

    /// Dart `Transaction._validId` and `getTransactions` use `trim()`, which
    /// strips U+FEFF; Swift's `.whitespacesAndNewlines` does not.
    @Test("a transaction id of only U+FEFF is blank, as in Dart: it gets a fresh id and the load writes it")
    func byteOrderMarkIDIsBlank() throws {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        let sections = try JSONParser.parse(#"""
            {"transactions":[
             {"id":"﻿","type":"expense","description":"a","amount":1.0,"category":"General","date":"2026-09-01T00:00:00.000","createdAt":"2026-09-01T00:00:00.000","updatedAt":"2026-09-01T00:00:00.000"},
             {"id":" ﻿ x","type":"expense","description":"b","amount":1.0,"category":"General","date":"2026-09-01T00:00:00.000","createdAt":"2026-09-01T00:00:00.000","updatedAt":"2026-09-01T00:00:00.000"}]}
            """#).objectValue!
        var ids = ["fresh-1", "fresh-2"]
        let result = loadFinancialData(sections, calendar: calendar, now: now, newID: { ids.removeFirst() })
        let transactions = result.data.transactions
        #expect(transactions.map(\.id) == ["fresh-2", " \u{FEFF}\u{A0}x"])
        // Categories are seeded as well (no stored section).
        #expect(result.pendingWrites.map(\.0) == [Section.transactions, Section.categories])
        let written = result.pendingWrites.first?.1.arrayValue?.first?.objectValue?["id"]?.stringValue
        #expect(written == "fresh-2")
    }
}
