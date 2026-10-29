import Foundation
import Testing

@testable import BudgieCore

@Suite("Flow: range, pagination and filter state rules")
struct FlowStateTests {
    let calendar = DartCalendar(timeZone: Scenario.zone)

    @Test("range options and labels")
    func range() {
        #expect(CashFlowMath.rangeOptions == [3, 6, 12])
        #expect(CashFlowMath.defaultRange == 6)
        #expect(CashFlowMath.rangeLabel(12) == "12 months")
    }

    @Test("the visible count resets only when the filter signature changes")
    func pagination() {
        var filter = TransactionFilter()
        var pages = FilterPagination()
        pages.sync(filter)
        #expect(pages.visibleCount == 50)
        pages.loadMore()
        pages.sync(filter)
        #expect(pages.visibleCount == 100)
        #expect(pages.visible(of: 60) == 60 && !pages.hasMore(60) && pages.hasMore(101))
        filter.searchText = "  "  // trims to the same query: no reset
        pages.sync(filter)
        #expect(pages.visibleCount == 100)
        filter.searchText = " a "
        pages.sync(filter)
        #expect(pages.visibleCount == 50)
        pages.loadMore()
        filter.minAmount = 5
        pages.sync(filter)
        #expect(pages.visibleCount == 50)
        #expect(filter.signature == "a|all|null|null|null|null|5.0|null")
    }

    @Test("date picks keep From <= To like the Flutter picker")
    func picks() {
        var filter = TransactionFilter()
        filter.setTo(calendar.date(2025, 1, 1))
        filter.setFrom(calendar.date(2025, 6, 1))
        #expect(filter.to == calendar.date(2025, 6, 1))
        filter.setTo(calendar.date(2025, 3, 1))
        #expect(filter.from == calendar.date(2025, 3, 1))
        #expect(TransactionFilter.dateButtonValue(filter.from) == "Mar 1")
        #expect(TransactionFilter.dateButtonValue(nil) == "Any date")
        let now = calendar.date(2026, 9, 28, 9, 15)
        #expect(filter.pickerInitialDate(isStart: true, now: now) == calendar.date(2025, 3, 1))
        #expect(TransactionFilter().pickerInitialDate(isStart: false, now: now) == now)
        let range = TransactionFilter.pickerRange(now: now, calendar: calendar)
        #expect(range.lowerBound == calendar.date(2000) && range.upperBound == calendar.date(2036, 12, 31))
        filter.reset()
        #expect(!filter.isActive && filter.emptyMessage == "No transactions have been recorded yet.")
    }

    @Test("filtering 10k rows stays interactive")
    func largeFilterTiming() throws {
        let rows = generatedFlowRows(seed: 777, count: 10_000, startYear: 2022, months: 60)
            .map { TransactionRecord.parse($0, calendar: calendar, newID: { "unused" })! }
        let index = LedgerIndex.build(rows, calendar: calendar)
        var filter = TransactionFilter()
        filter.searchText = "coffee"
        filter.kind = .expense
        filter.minAmount = 10
        let clock = ContinuousClock()
        var matches: [LedgerRow] = []
        let elapsed = clock.measure {
            for _ in 0..<5 { matches = filter.apply(index) }
        }
        let perRun = elapsed / 5
        print("TransactionFilter.apply over 10k rows: \(perRun) (\(matches.count) matches)")
        #expect(!matches.isEmpty)
        // Debug builds are several times slower than release (< 20ms target).
        #expect(perRun < .milliseconds(150))
    }
}
