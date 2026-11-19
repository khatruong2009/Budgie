import Foundation
import Testing

@testable import BudgieCore

@Suite("Record decoding helpers (Read)")
struct ReadHelpersTests {
    @Test("an empty date string is unparseable, so Read.optionalDate's empty check changes nothing")
    func emptyDate() {
        let calendar = DartCalendar(timeZone: newYorkZone)
        #expect(calendar.tryParse("") == nil)
    }
}
