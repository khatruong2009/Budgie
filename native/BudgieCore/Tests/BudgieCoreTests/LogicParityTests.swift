import Foundation
import Testing

@testable import BudgieCore

@Suite("Domain: ordering and the safe-to-spend asOf inputs (the zone tests are in LogicDSTParityTests)")
struct LogicParityTests {
    /// The `asOf` values the harness passed (logic_fixtures_test.dart), in order.
    static let asOfInputs = [
        "2026-03-08T10:30:00.000", "2026-03-01T00:00:00.000", "2026-03-31T23:59:00.000",
        "2026-03-08T10:30:00.000", "2026-03-08T10:30:00.000", "2026-11-01T08:00:00.000",
        "2026-11-02T00:00:00.000", "2026-10-04T12:00:00.000",
    ]

    @Test("newest-first ordering")
    func ordering() throws {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "UTC")!)
        let fixture = try Fixtures.json("logic/ordering.json")
        let rows = fixture["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let sorted = LedgerIndex.build(rows, calendar: calendar).newestFirst
        #expect(sorted.map(\.id) == fixture["newestFirst"].array.compactMap(\.string))
    }
}
