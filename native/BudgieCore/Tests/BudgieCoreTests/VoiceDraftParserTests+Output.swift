import Foundation
import Testing

@testable import BudgieCore

extension VoiceDraftParserTests {
    // MARK: markdown fence stripping (group 'markdown fence stripping')

    @Test("strips a plain triple-backtick fence")
    func fencePlain() throws {
        let body = jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out")
        let draft = try parse("```\n\(body)\n```", "lunch")
        #expect(draft.description == "lunch")
        #expect(draft.amount == 12.5)
        #expect(draft.category == "Eating Out")
    }

    @Test("strips a triple-backtick-json fence")
    func fenceJSON() throws {
        let body = jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out")
        let draft = try parse("```json\n\(body)\n```", "lunch")
        #expect(draft.description == "lunch")
        #expect(draft.amount == 12.5)
        #expect(draft.category == "Eating Out")
    }

    // MARK: error handling (group 'error handling')

    @Test("malformed JSON throws VoiceEntryError carrying the transcript")
    func errorMalformed() {
        let transcript = "this could not be parsed"
        #expect(throws: VoiceEntryError.unreadable(transcript: transcript)) {
            try parse("{ this is not valid json", transcript)
        }
    }

    @Test("an error key throws VoiceEntryError carrying the transcript")
    func errorKey() {
        let transcript = "what is the weather today"
        #expect(throws: VoiceEntryError.notATransaction(transcript: transcript)) {
            try parse(DartJSON.encodeString(.object(JSONObject(["error": "not_a_transaction"]))), transcript)
        }
    }

    @Test("a non-object JSON root (array) throws with the transcript")
    func errorArrayRoot() {
        let transcript = "a list of things"
        #expect(throws: VoiceEntryError.unreadable(transcript: transcript)) {
            try parse("[1, 2, 3]", transcript)
        }
    }

    @Test("a bare JSON scalar root throws with the transcript")
    func errorScalarRoot() {
        let transcript = "just a number"
        #expect(throws: VoiceEntryError.unreadable(transcript: transcript)) {
            try parse("42", transcript)
        }
    }

    // MARK: returned object (group 'returned Transaction object')

    @Test("returns the correct fields for an expense")
    func returnedExpense() throws {
        let draft = try parse(
            jsonOutput(
                type: "expense", description: "Chipotle", amount: .double(12.5), category: "Eating Out",
                date: "2026-07-06"),
            "twelve fifty for lunch at chipotle yesterday")
        #expect(draft.type == .expense)
        #expect(draft.description == "Chipotle")
        #expect(draft.amount == 12.5)
        #expect(draft.category == "Eating Out")
        #expect(draft.date == newYork.date(2026, 7, 6))
    }

    @Test("returns the correct fields for income")
    func returnedIncome() throws {
        let draft = try parse(
            jsonOutput(
                type: "income", description: "Paycheck", amount: .int(3000), category: "Salary", date: "2026-07-07"),
            "got paid three thousand")
        #expect(draft.type == .income)
        #expect(draft.description == "Paycheck")
        #expect(draft.amount == 3000.0)
        #expect(draft.category == "Salary")
        #expect(draft.date == newYork.date(2026, 7, 7))
    }
}
