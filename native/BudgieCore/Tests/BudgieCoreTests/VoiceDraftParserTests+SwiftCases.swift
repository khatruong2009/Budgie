import Foundation
import Testing

@testable import BudgieCore

extension VoiceDraftParserTests {
    // MARK: Swift superset (categories come from the caller, not a fixed map)

    @Test("a custom category in the passed list is accepted")
    func customCategoryAccepted() throws {
        let draft = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: "Coffee Beans"), "t",
            expense: flutterExpenseNames + ["Coffee Beans"])
        #expect(draft.category == "Coffee Beans")
        let income = try parse(
            jsonOutput(type: "income", description: "x", amount: .int(1), category: "Side Gig"), "t",
            income: flutterIncomeNames + ["Side Gig"])
        #expect(income.category == "Side Gig")
    }

    @Test("a built-in category missing from the passed list is not accepted")
    func removedCategoryNotAccepted() throws {
        let draft = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: "Groceries"), "t",
            expense: ["General", "Travel"])
        #expect(draft.category == "General")
    }

    @Test("the fallback name is used even when the list does not contain it")
    func fallbackNotInList() throws {
        let expense = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: "nope"), "t",
            expense: ["Groceries"], income: ["Salary"])
        #expect(expense.category == "General")
        let income = try parse(
            jsonOutput(type: "income", description: "x", amount: .int(1), category: "nope"), "t",
            expense: ["Groceries"], income: ["Salary"])
        #expect(income.category == "Other")
    }

    @Test("category membership is by UTF-16 code units: NFD is not NFC")
    func nfdCategoryIsNotAMember() throws {
        let nfc = "Caf\u{E9}"
        let nfd = "Cafe\u{301}"
        #expect(nfc == nfd)  // Swift String equality would merge them
        let list = flutterExpenseNames + [nfc]

        let exact = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: js(nfc)), "t", expense: list)
        #expect(exact.category.utf16.elementsEqual(nfc.utf16))

        let decomposed = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: js(nfd)), "t", expense: list)
        #expect(decomposed.category == "General")

        // And the other way round: the list holds the NFD spelling.
        let reversed = try parse(
            jsonOutput(type: "expense", description: "x", amount: .int(1), category: js(nfc)), "t",
            expense: flutterExpenseNames + [nfd])
        #expect(reversed.category == "General")
    }

    @Test("a category written with JSON escapes still matches")
    func escapedCategoryMatches() throws {
        let draft = try parse(
            #"{"type":"expense","category":"Eating Out","amount":1}"#, "t")
        #expect(draft.category == "Eating Out")
    }

    // MARK: Swift edge cases worth pinning (all checked against Dart in VoiceParityTests)

    @Test("a negative zero amount keeps its sign, as in Dart")
    func negativeZeroAmountKept() throws {
        // `-0.0 < 0` is false in Dart, so the clamp leaves it alone.
        let fromString = try parse(#"{"amount":"-0"}"#, "t")
        #expect(fromString.amount.bitPattern == (-0.0).bitPattern)
        let fromNumber = try parse(#"{"amount":-1e-400}"#, "t")
        #expect(fromNumber.amount.bitPattern == (-0.0).bitPattern)
    }

    @Test("NaN, infinity and overflow amounts become 0.0")
    func nonFiniteAmounts() throws {
        for text in [#""NaN""#, #""Infinity""#, #""-Infinity""#, "1e400", "-1e400"] {
            let draft = try parse(#"{"amount":\#(text)}"#, "t")
            #expect(draft.amount.bitPattern == (0.0).bitPattern, "amount \(text)")
        }
    }

    @Test("a UTC date string stays a UTC instant")
    func utcDate() throws {
        let draft = try parse(#"{"date":"2026-07-06T18:30:00Z"}"#, "t")
        #expect(draft.date.isUtc)
        #expect(draft.date.microsecondsSinceEpoch == 1_783_362_600_000_000)
    }

    @Test("the description is trimmed with Dart's whitespace set, BOM included")
    func dartTrim() throws {
        let draft = try parse(#"{"description":"﻿  Lunch  ﻿"}"#, "t")
        #expect(draft.description == "Lunch")
        let blank = try parse(#"{"description":"﻿ "}"#, "the transcript")
        #expect(blank.description == "the transcript")
    }

    @Test("the reply is trimmed before fence detection, and a fence needs no language")
    func fenceEdgeCases() throws {
        let body = #"{"amount":5}"#
        #expect(try parse("\u{FEFF}  ```json\n\(body)\n```\n ", "t").amount == 5)
        #expect(try parse("```\(body)```", "t").amount == 5)
        #expect(try parse("```json \(body) ```", "t").amount == 5)
        // The language stops at the first non-letter.
        #expect(throws: VoiceEntryError.unreadable(transcript: "t")) { try parse("```json5\n\(body)\n```", "t") }
        // A closing fence alone is not a fence.
        #expect(throws: VoiceEntryError.unreadable(transcript: "t")) { try parse("\(body)\n```", "t") }
        #expect(throws: VoiceEntryError.unreadable(transcript: "t")) { try parse("```", "t") }
    }

    @Test("an error key wins even with a full transaction next to it, and a null error still counts")
    func errorKeyPresence() {
        #expect(throws: VoiceEntryError.notATransaction(transcript: "t")) {
            try parse(#"{"error":null,"amount":5}"#, "t")
        }
        #expect(throws: VoiceEntryError.notATransaction(transcript: "t")) {
            try parse(#"{"amount":5,"error":"x"}"#, "t")
        }
    }

    @Test("the 90-day lookback uses the calendar of today's zone across a DST change")
    func lookbackAcrossDST() throws {
        // 90 days before 2026-06-06 is 2026-03-08, the New York spring-forward day.
        let today = newYork.date(2026, 6, 6, 12)
        let onBoundary = try parse(#"{"date":"2026-03-08"}"#, "t", today: today)
        #expect(onBoundary.date == newYork.date(2026, 3, 8))
        let before = try parse(#"{"date":"2026-03-07T23:59:59.999999"}"#, "t", today: today)
        #expect(before.date == today)
    }

    @Test("day underflow normalises across a year boundary")
    func lookbackAcrossYear() throws {
        // 90 days before 2026-01-15 is 2025-10-17.
        let today = newYork.date(2026, 1, 15)
        let onBoundary = try parse(#"{"date":"2025-10-17"}"#, "t", today: today)
        #expect(onBoundary.date == newYork.date(2025, 10, 17))
        let before = try parse(#"{"date":"2025-10-16"}"#, "t", today: today)
        #expect(before.date == today)
    }
}
