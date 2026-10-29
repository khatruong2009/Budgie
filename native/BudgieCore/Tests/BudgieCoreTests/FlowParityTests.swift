import Foundation
import Testing

@testable import BudgieCore

/// Datasets written by native/ParityHarness/parity/flow_fixtures_test.dart.
let flowDatasets = ["typical", "gaps", "cross_year", "empty", "one_month", "negative_tiny", "large"]

private func flowFixture(_ relative: String) throws -> J {
    try Fixtures.json("flow/" + relative)
}

private func flowZoneFixture(_ zone: String, _ name: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("flow", zone))/\(name)")
}

private func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

private func utf16(_ strings: [String]) -> [[UInt16]] { strings.map { Array($0.utf16) } }

private func idsFnv(_ ids: [String]) -> String {
    StoreFile.checksum(Array(ids.joined(separator: "\n").utf8))
}

/// The harness's `generated` rows (flow_fixtures_test.dart `Lcg`,
/// `generated`): same LCG, same call order, same JSON.
private struct Lcg {
    var state: Int
    mutating func next() -> Int {
        state = (state * 1_103_515_245 + 12345) & 0x7fff_ffff
        return state >> 16
    }
}

private let generatedCategories = [
    "Groceries", "Eating Out", "Housing", "Travel", "groceries", "Caf\u{E9}", "Cafe\u{301}", "Salary",
]
private let generatedDescriptions = [
    "Coffee shop", "COFFEE beans", "Trader Joe's", "\u{130}stanbul trip", "Stra\u{DF}e fest", "rent", "  padded  ", "",
    "\u{3A3}\u{39F}\u{3A6}\u{399}\u{391}", "na\u{EF}ve", "Cafe\u{301} latte", "Caf\u{E9} au lait", "\u{2615}\u{FE0F} Coffee",
    "Paycheck",
]
private let generatedTags = ["t-food", "t-work", "t-trip"]

private func pad(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    return String(repeating: "0", count: max(0, width - text.count)) + text
}

private func localIso(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> String {
    "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(h, 2)):\(pad(min, 2)):00.000"
}

func generatedFlowRows(seed: Int, count: Int, startYear: Int, months: Int) -> [JSONValue] {
    var r = Lcg(state: seed)
    var rows: [JSONValue] = []
    rows.reserveCapacity(count)
    for i in 0..<count {
        let offset = r.next() % months
        let y = startYear + offset / 12
        let m = offset % 12 + 1
        let d = 1 + r.next() % 28
        let h = r.next() % 24
        let mi = r.next() % 60
        let isIncome = r.next() % 5 == 0
        let high = r.next()
        let amount = Double((high * 32768 + r.next()) % 500_000) / 100
        let category = generatedCategories[r.next() % generatedCategories.count]
        let description = "\(generatedDescriptions[r.next() % generatedDescriptions.count]) \(i % 97)"
        let tagRoll = r.next() % 8
        let created = r.next() % 3
        let createdAt = localIso(y, m, d, 12, created)
        rows.append(.object(JSONObject(ordered: [
            ("id", .string("G" + pad(i, 5))),
            ("type", .string(isIncome ? "income" : "expense")),
            ("description", .string(description)),
            ("amount", .double(amount)),
            ("category", .string(category)),
            ("date", .string(localIso(y, m, d, h, mi))),
            ("recurringTemplateId", .null),
            ("tagIds", .array(tagRoll < 3 ? [.string(generatedTags[tagRoll])] : [])),
            ("createdAt", .string(createdAt)),
            ("updatedAt", .string(createdAt)),
        ])))
    }
    return rows
}

/// The dataset's transactions, parsed as the app parses stored rows.
private func records(_ fixture: J, calendar: DartCalendar) -> [TransactionRecord] {
    let values: [JSONValue]
    if fixture["rows"].value != nil {
        values = fixture["rows"].array.compactMap(\.value)
    } else {
        let g = fixture["generator"]
        values = generatedFlowRows(seed: g["seed"].int!, count: g["count"].int!, startYear: g["startYear"].int!, months: g["months"].int!)
    }
    return values.map { TransactionRecord.parse($0, calendar: calendar, newID: { "unused" })! }
}

/// A filter built the way the harness's `FilterSpec.state` builds Dart's.
private func filter(_ spec: J, calendar: DartCalendar) -> TransactionFilter {
    var filter = TransactionFilter()
    filter.searchText = spec["search"].string!
    filter.kind = TransactionFilter.Kind(rawValue: spec["type"].string!)!
    filter.category = spec["category"].string
    filter.tagId = spec["tag"].string
    for pick in spec["picks"].array {
        let day = calendar.date(pick["y"].int!, pick["m"].int!, pick["d"].int!)
        if pick["isStart"].bool! { filter.setFrom(day) } else { filter.setTo(day) }
    }
    filter.minAmount = TransactionFilter.parseAmount(spec["minText"].string!)
    filter.maxAmount = TransactionFilter.parseAmount(spec["maxText"].string!)
    return filter
}

@Suite("Flow: cash-flow figures and SEE ALL filters match the Flutter page (Fixtures/flow)")
struct FlowParityTests {
    @Test("series, windows, metrics, bars, YoY, trend curve and filters", arguments: fixtureZones, flowDatasets)
    func dataset(zone: String, name: String) throws {
        let fixture = try flowZoneFixture(zone, name + ".json")
        let specs = try flowZoneFixture(zone, "filter_specs.json")["specs"].array
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let formatter = MoneyFormatter()
        let rows = records(fixture, calendar: calendar)
        let index = LedgerIndex.build(rows, calendar: calendar)
        let context = "\(zone) \(name)"

        // Model series.
        #expect(index.newestFirst.count == fixture["count"].int, "\(context) count")
        #expect(index.availableMonths.map { $0.toIso8601String() } == fixture["availableMonths"].array.map(\.string!), "\(context) months")
        let history = index.netCashFlowHistory
        let wantHistory = fixture["history"].array
        #expect(history.count == wantHistory.count, "\(context) history")
        for (entry, want) in zip(history, wantHistory) {
            #expect(entry.month.toIso8601String() == want["month"].string)
            #expect(hex(entry.income) == want["income"].string && hex(entry.expenses) == want["expenses"].string, "\(context) \(want["month"].string!)")
            #expect(hex(entry.net) == want["net"].string)
        }
        let ids = index.newestFirst.map(\.id)
        if fixture["sortedIds"].value != nil {
            #expect(ids == fixture["sortedIds"].array.map(\.string!), "\(context) order")
        }
        #expect(idsFnv(ids) == fixture["sortedIdsFnv"].string, "\(context) order hash")
        #expect(utf16(index.categoryNames) == utf16(fixture["categoryOptions"].array.map(\.string!)), "\(context) category options")

        // Row strings (subtitle, amount), newest first.
        let rowTexts = index.newestFirst.map { [$0.flowSubtitle, $0.flowAmountText(formatter)] }
        if fixture["rowTexts"].value != nil {
            let want = fixture["rowTexts"].array.map { $0.array.map(\.string!) }
            #expect(want.count == rowTexts.count, "\(context) row texts")
            for (row, (got, expected)) in zip(index.newestFirst, zip(rowTexts, want)) {
                #expect(utf16(got) == utf16(expected), "\(context) row \(row.id)")
            }
        } else {
            let joined = rowTexts.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            #expect(StoreFile.checksum(Array(joined.utf8)) == fixture["rowTextsFnv"].string, "\(context) row texts hash")
        }
        for row in index.newestFirst where row.record.type == .expense && row.record.amount == 0 {
            #expect(row.flowAmountText(formatter) == "$0.00", "\(context) zero expense \(row.id)")
        }

        // Page figures per selected month.
        for selection in fixture["selections"].array {
            let selected = try calendar.parse(selection["selected"].string!)
            let at = "\(context) \(selection["selected"].string!)"
            for view in selection["views"].array {
                let range = view["range"].int!
                let window = CashFlowMath.chartWindow(history, selectedMonth: selected, months: range)
                let here = "\(at) range \(range)"
                #expect(window.map { $0.month.toIso8601String() } == view["window"].array.map(\.string!), "\(here) window")
                let metrics = CashFlowMath.metrics(window)
                #expect(hex(metrics.avgSaved) == view["avgSaved"].string && hex(metrics.savingsRate) == view["savingsRate"].string, "\(here) metrics")
                #expect(CashFlowMath.avgSavedText(metrics.avgSaved, formatter: formatter) == view["avgText"].string, "\(here) avg text")
                #expect(CashFlowMath.savingsRateText(metrics.savingsRate) == view["rateText"].string, "\(here) rate text")
                #expect(metrics.avgSavedIsPositive == view["avgIsPositive"].bool && metrics.savingsRateIsPositive == view["rateIsPositive"].bool)

                for want in view["bars"].array {
                    let width = bits(want["availableWidth"])!
                    let layout = CashFlowMath.barLayout(window, selectedMonth: selected, availableWidth: width)
                    #expect(hex(layout.barWidth) == want["barWidth"].string, "\(here) width \(width)")
                    let bars = want["bars"].array
                    #expect(layout.bars.count == bars.count)
                    for (bar, wantBar) in zip(layout.bars, bars) {
                        let b = "\(here) bar \(wantBar["month"].string!)"
                        #expect(bar.entry.month.toIso8601String() == wantBar["month"].string, "\(b)")
                        #expect(hex(bar.height) == wantBar["height"].string && hex(bar.top) == wantBar["top"].string, "\(b) geometry")
                        #expect(bar.isPositive == wantBar["isPositive"].bool && bar.isCurrent == wantBar["isCurrent"].bool, "\(b) flags")
                        #expect(bar.monthLabel == wantBar["label"].string, "\(b) label")
                        #expect(CashFlowMath.badgeText(bar.entry.net, formatter: formatter) == wantBar["badge"].string, "\(b) badge")
                    }
                }

                let details = view["details"].array
                #expect(details.count == window.count)
                for (entry, want) in zip(window, details) {
                    let detail = CashFlowMath.MonthDetail(entry: entry)
                    #expect(detail.title == want["title"].string, "\(here) detail title")
                    #expect(detail.incomeText(formatter) == want["income"].string, "\(here) detail income")
                    #expect(detail.expensesText(formatter) == want["expenses"].string, "\(here) detail expenses")
                    #expect(detail.netText(formatter) == want["net"].string, "\(here) detail net")
                    #expect(detail.netIsPositive == want["netIsPositive"].bool)
                }
            }

            let yoy = CashFlowMath.yearOverYear(index, selectedMonth: selected)
            let wantYoY = selection["yoy"]
            #expect(yoy.currentMonth.toIso8601String() == wantYoY["currentMonth"].string, "\(at) yoy month")
            #expect(yoy.previousMonth.toIso8601String() == wantYoY["previousMonth"].string)
            #expect(yoy.headerText == wantYoY["header"].string, "\(at) yoy header")
            for (row, want) in [(yoy.income, wantYoY["income"]), (yoy.expenses, wantYoY["expenses"])] {
                #expect(hex(row.current) == want["current"].string && hex(row.previous) == want["previous"].string, "\(at) yoy values")
                #expect(row.delta.map(hex) == want["delta"].string, "\(at) yoy delta")
                #expect(row.deltaLabel == want["label"].string, "\(at) yoy label")
                #expect(hex(row.thisYearFraction) == want["this"].string && hex(row.lastYearFraction) == want["last"].string, "\(at) yoy fills")
            }
            #expect(yoy.incomeDeltaIsGood == wantYoY["income"]["isGood"].bool)
            #expect(yoy.expenseDeltaIsBad == wantYoY["expenses"]["isBad"].bool)

            let trend = selection["trend"]
            let series = CashFlowMath.trendSeries(index, selectedMonth: selected)
            #expect(series.map { $0.month.toIso8601String() } == trend["months"].array.map(\.string!), "\(at) trend months")
            let nets = series.map(\.net)
            #expect(nets.map(hex) == trend["nets"].array.map(\.string!), "\(at) trend nets")
            #expect(hex(CashFlowMath.sparklineBound(nets)) == trend["bound"].string, "\(at) bound")
            expectCurve(nets: nets, size: trend["size"], trend, "\(at) trend")
        }

        // Filters.
        let results = fixture["filters"].array
        #expect(results.count == specs.count)
        for (spec, want) in zip(specs, results) {
            let f = filter(spec["spec"], calendar: calendar)
            let here = "\(context) filter \(spec["spec"].value.map { DartJSON.encodeString($0) } ?? "")"
            #expect(Array(f.query.utf16) == Array(spec["query"].string!.utf16), "\(here) query")
            #expect(f.minAmount.map(hex) == spec["min"].string && f.maxAmount.map(hex) == spec["max"].string, "\(here) amounts")
            #expect(f.from?.toIso8601String() == spec["start"].string && f.to?.toIso8601String() == spec["end"].string, "\(here) dates")
            #expect(f.isActive == spec["isActive"].bool, "\(here) active")
            #expect(Array(f.signature.utf16) == Array(spec["signature"].string!.utf16), "\(here) signature \(f.signature)")
            let matches = f.apply(index)
            let matchIDs = matches.map(\.id)
            if want["ids"].value != nil {
                #expect(matchIDs == want["ids"].array.map(\.string!), "\(here) ids")
            } else {
                #expect(idsFnv(matchIDs) == want["idsFnv"].string, "\(here) ids hash (\(matchIDs.count))")
            }
            let summary = TransactionFilter.summary(matches)
            #expect(summary.count == want["count"].int, "\(here) count")
            #expect(hex(summary.income) == want["income"].string && hex(summary.expenses) == want["expenses"].string, "\(here) sums")

            // The results block on first open (50 rows visible).
            let texts = want["texts"]
            #expect(texts.value != nil, "\(here) texts")
            #expect(TransactionFilter.countText(matches: matches.count, total: index.newestFirst.count) == texts["count"].string, "\(here) count text")
            #expect(summary.incomeText(formatter) == texts["income"].string, "\(here) income pill")
            #expect(summary.expensesText(formatter) == texts["expenses"].string, "\(here) expenses pill")
            #expect(summary.netText(formatter) == texts["net"].string, "\(here) net pill")
            var pages = FilterPagination()
            pages.sync(f)
            let showing = pages.hasMore(matches.count)
                ? TransactionFilter.showingText(visible: pages.visible(of: matches.count), matches: matches.count) : nil
            #expect(showing == texts["showing"].string, "\(here) showing")
            #expect((matches.isEmpty ? f.emptyMessage : nil) == texts["empty"].string, "\(here) empty")
        }
    }

    private func expectCurve(nets: [Double], size: J, _ want: J, _ context: String) {
        let size = CGSize(width: bits(size[0])!, height: bits(size[1])!)
        let points = CashFlowMath.trendPoints(nets, size: size)
        #expect(points.map { [hex(Double($0.x)), hex(Double($0.y))] } == want["points"].array.map { $0.array.map(\.string!) }, "\(context) points")
        let controls = CashFlowMath.trendControlPoints(points)
        let wantControls = want["controls"].array
        #expect(controls.count == wantControls.count, "\(context) segments")
        for (index, (pair, expected)) in zip(controls, wantControls).enumerated() {
            let got = [[hex(Double(pair.0.x)), hex(Double(pair.0.y))], [hex(Double(pair.1.x)), hex(Double(pair.1.y))]]
            #expect(got == expected.array.map { $0.array.map(\.string!) }, "\(context) segment \(index)")
        }
    }

    @Test("percent deltas, metric strings, amount parsing and fl_chart curves")
    func formulas() throws {
        let fixture = try flowFixture("formulas.json")
        let formatter = MoneyFormatter()

        let deltas = fixture["deltas"].array
        #expect(deltas.count > 100)
        for want in deltas {
            let delta = CashFlowMath.percentDelta(current: bits(want["current"])!, previous: bits(want["previous"])!)
            #expect(delta.map(hex) == want["delta"].string, "delta \(want["current"].string!) \(want["previous"].string!)")
            #expect(CashFlowMath.formatPercentDelta(delta) == want["label"].string, "label \(want["label"].string!)")
        }

        for want in fixture["metricTexts"].array {
            let value = bits(want["value"])!
            #expect(CashFlowMath.savingsRateText(value) == want["rateText"].string, "rate \(value)")
            #expect(CashFlowMath.avgSavedText(value, formatter: formatter) == want["avgText"].string, "avg \(value)")
            #expect(CashFlowMath.badgeText(value, formatter: formatter) == want["badge"].string, "badge \(value)")
        }

        // Dart keeps NaN and infinities from double.tryParse; Swift drops
        // them (PARITY_GAPS). Every finite result is bit-identical.
        var nonFinite = 0
        for want in fixture["amounts"].array {
            let text = want["text"].string!
            let parsed = TransactionFilter.parseAmount(text)
            if want["result"].isNull || want["isFinite"].bool == true {
                #expect(parsed.map(hex) == want["result"].string, "amount \(text)")
            } else {
                nonFinite += 1
                #expect(parsed == nil, "amount \(text) is not finite in Dart and rejected in Swift")
            }
        }
        #expect(nonFinite == 4)

        for curve in fixture["curves"].array {
            expectCurve(nets: curve["values"].array.map { bits($0)! }, size: curve["size"], curve, "curve")
            #expect(hex(CashFlowMath.sparklineBound(curve["values"].array.map { bits($0)! })) == curve["bound"].string)
        }
        for curve in fixture["rawCurves"].array {
            let points = curve["points"].array.map { CGPoint(x: bits($0[0])!, y: bits($0[1])!) }
            let controls = CashFlowMath.trendControlPoints(points, smoothness: bits(curve["smoothness"])!)
            let got = controls.map { [[hex(Double($0.0.x)), hex(Double($0.0.y))], [hex(Double($0.1.x)), hex(Double($0.1.y))]] }
            #expect(got == curve["controls"].array.map { $0.array.map { $0.array.map(\.string!) } })
        }
    }
}

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
