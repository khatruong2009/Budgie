import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("spend/\(name)")
}

private func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

private func units(_ text: String?) -> [UInt16]? { text.map { Array($0.utf16) } }

/// ARGB hex of a palette slot as the Flutter page paints it
/// (app_colors.dart; light `categoryColors` :200-215, dark :223-238).
private func argb(_ slot: SpendPaletteSlot, dark: Bool) -> String {
    let rank = dark
        ? ["818cf8", "34d399", "fb7185", "fbbf24", "60a5fa", "f0abfc"]
        : ["6366f1", "10b981", "ef4444", "f59e0b", "3b82f6", "f0abfc"]
    let chart = dark
        ? ["818cf8", "a78bfa", "34d399", "6ee7b7", "f87171", "fca5a5", "fbbf24", "fcd34d", "60a5fa", "93c5fd", "f472b6",
           "f9a8d4", "2dd4bf", "5eead4"]
        : ["6366f1", "8b5cf6", "10b981", "34d399", "ef4444", "f87171", "f59e0b", "fbbf24", "3b82f6", "60a5fa", "ec4899",
           "f472b6", "14b8a6", "2dd4bf"]
    let rgb: String = switch slot {
    case .accent: rank[0]
    case .income: rank[1]
    case .danger: rank[2]
    case .warning: rank[3]
    case .info: rank[4]
    case .pink: rank[5]
    case .chart(let index): chart[index]
    case .remainder: dark ? "3a3a52" : "c9c9da"
    }
    return "ff" + rgb
}

private func centreTexts(_ label: CategoryBreakdown.CentreLabel, money: MoneyFormatter) -> [String] {
    switch label {
    case .total(let total, let delta):
        return ["SPENT", money.format(total, decimalDigits: 0)] + (delta.map { [$0.text] } ?? [])
    case .slice(let title, let value, let percentText):
        return [title, money.format(value, decimalDigits: 0), percentText]
    }
}

private let square = CGSize(width: 240, height: 240)

@Suite("Spend: breakdown, donut and strings match the Flutter Spend tab (Fixtures/spend)")
struct SpendParityTests {
    @Test("Dart String.hashCode over a corpus")
    func hashCodes() throws {
        let cases = try fixture("strings.json")["hashCodes"].array
        #expect(cases.count > 50)
        for c in cases {
            let text = String(decoding: c["units"].array.map { UInt16($0.int!) }, as: UTF16.self)
            #expect(DartString.hashCode(text) == c["hashCode"].int, "\(c["units"].array.map(\.int))")
        }
    }

    @Test("Dart toUpperCase for every scalar")
    func uppercase() throws {
        var expected: [UInt32: [UInt16]] = [:]
        for entry in try fixture("strings.json")["upper"].array {
            expected[UInt32(entry[0].int!)] = entry[1].array.map { UInt16($0.int!) }
        }
        #expect(expected.count > 1000)
        var mismatches: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(Character(scalar))
            let want = expected[value] ?? Array(text.utf16)
            if Array(DartString.uppercase(text).utf16) != want { mismatches.append(value) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).map { String($0, radix: 16) })")
    }

    // Generated under America/New_York. Every dataset date is local noon, so
    // the Dart output is the same in any zone (a run under Asia/Kolkata
    // differed only in "tz"); Swift is checked in each fixture zone.
    @Test("the page's breakdown, rows, tail, centre and selections for every dataset", arguments: fixtureZones)
    func breakdowns(zone: String) throws {
        let cases = try fixture("breakdowns.json")["cases"].array
        #expect(cases.count == 17)
        let money = MoneyFormatter()
        for c in cases {
            let label = "\(zone) \(c["dataset"].string!)/\(c["theme"].string!)"
            let dark = c["theme"].string == "dark"
            let unstable = c["unstableTies"].bool == true
            let data = homeData(try JSONParser.parse(c["sections"].string!).objectValue!, zone: TimeZone(identifier: zone)!)
            let active = data.categoryPicker(for: .expense).map(\.name)
            #expect(active.map { Array($0.utf16) } == c["expenseCategories"].array.map { units($0.string)! }, "\(label) active")
            let ledger = LedgerIndex.build(data.transactions, calendar: data.calendar)
            #expect(ledger.availableMonths.map { $0.toIso8601String() } == c["availableMonths"].array.map { $0.string! })

            let months = c["months"].array
            let resolved = SpendMonth.resolve(selected: nil, available: ledger.availableMonths)
            #expect(resolved.month?.toIso8601String() == months[0]["month"].string, "\(label) default month")

            for m in months {
                let where_ = "\(label) \(m["month"].string!)"
                let month = try data.calendar.parse(m["month"].string!)
                #expect(DartDateFormat.MMMM(month) == m["pill"].string, "\(where_) pill")
                let b = CategoryBreakdown.build(
                    month: month, ledger: ledger, budgetLimits: data.budgetLimits, activeExpenseCategories: active)
                let mirror = m["mirror"]
                #expect(hex(b.total) == mirror["total"].string, "\(where_) total")
                #expect(b.previousTotal.map(hex) == mirror["previousTotal"].string, "\(where_) previous")
                #expect(hex(b.largestAmount) == mirror["largest"].string, "\(where_) largest")
                #expect(b.tail.map { hex($0.total) } == mirror["tailTotal"].string, "\(where_) tail total")

                // Records against the mirror (checked against the page in Dart).
                let want = mirror["records"].array
                #expect(b.records.count == want.count, "\(where_) count")
                if unstable {
                    // Dart's quicksort above 33 elements: same amounts, tie order differs.
                    #expect(b.records.map { hex($0.amount) } == want.map { $0["amount"].string! }, "\(where_) amounts")
                    #expect(Set(b.records.map(\.name)) == Set(want.map { $0["name"].string! }), "\(where_) names")
                } else {
                    for (r, w) in zip(b.records, want) {
                        let at = "\(where_) \(r.rank) \(r.name)"
                        #expect(units(r.name) == units(w["name"].string), "\(at) name")
                        #expect(hex(r.amount) == w["amount"].string && hex(r.percentage) == w["percentage"].string, "\(at) values")
                        #expect(r.percentageText == w["percentageText"].string && r.count == w["count"].int, "\(at) text/count")
                        #expect(r.budgetLimit.map(hex) == w["budgetLimit"].string, "\(at) limit")
                        #expect((r.activeIndex == nil) == w["fromHash"].bool, "\(at) active")
                        if r.rank >= 6 { #expect(r.palette == .chart(w["colorIndex"].int!), "\(at) palette") }
                    }
                }

                if m["empty"].bool == true {
                    #expect(b.showsEmptyState, "\(where_) empty")
                    continue
                }
                #expect(!b.showsEmptyState, "\(where_) not empty")

                // Donut inputs as the page passed them.
                let donut = m["donut"]
                #expect(hex(b.total) == donut["total"].string && b.previousTotal.map(hex) == donut["previousTotal"].string)
                #expect(b.previousMonthLabel == donut["previousLabel"].string, "\(where_) previous label")
                let slices = donut["slices"].array
                #expect(b.slices.count == slices.count, "\(where_) slices")
                for (s, w) in zip(b.slices, slices) {
                    if !unstable || s.isOther { #expect(units(s.label) == units(w["label"].string), "\(where_) slice") }
                    #expect(hex(s.value) == w["value"].string, "\(where_) slice \(s.label)")
                    #expect(argb(s.palette, dark: dark) == w["color"].string, "\(where_) slice colour \(s.label)")
                }

                #expect(centreTexts(b.centreLabel(selectedSlice: nil), money: money) == m["centre"].array.map { $0.string! },
                        "\(where_) centre")

                func checkRows(_ list: J, expanded: Bool) {
                    let rows = list["rows"].array
                    let records = b.visibleRecords(expanded: expanded)
                    #expect(records.count == rows.count, "\(where_) rows")
                    for (r, w) in zip(records, rows) {
                        let at = "\(where_) row \(r.rank)"
                        #expect(money.format(r.amount, decimalDigits: 0) == w["amount"].string, "\(at) amount")
                        #expect(hex(r.barFraction) == w["bar"].string, "\(at) bar")
                        if unstable { continue }
                        #expect(units(r.name) == units(w["title"].string), "\(at) title")
                        #expect(units(r.subtitle(money: money)) == units(w["subtitle"].string), "\(at) subtitle")
                        #expect(argb(r.palette, dark: dark) == w["iconColor"].string, "\(at) colour")
                        #expect(w["barColor"].string == w["iconColor"].string)
                    }
                    #expect(list["showLess"].bool == (expanded && b.tail != nil), "\(where_) show less")
                    let tail = list["tail"]
                    if expanded || b.tail == nil {
                        #expect(tail.isNull, "\(where_) no tail row")
                    } else if let t = b.tail {
                        #expect(t.title == tail["title"].string, "\(where_) tail title")
                        if !unstable { #expect(units(t.subtitle) == units(tail["subtitle"].string), "\(where_) tail names") }
                        #expect(money.format(t.total, decimalDigits: 0) == tail["amount"].string, "\(where_) tail amount")
                        #expect(hex(t.barFraction) == tail["bar"].string, "\(where_) tail bar")
                        #expect(argb(.remainder, dark: dark) == tail["barColor"].string, "\(where_) tail colour")
                    }
                }
                checkRows(m["collapsed"], expanded: false)
                if !m["expanded"].isNull { checkRows(m["expanded"], expanded: true) }

                // Tapping each slice: what the page selected shows in the
                // centre, and which rows it tints.
                let geometry = b.donut
                for s in m["selections"].array {
                    let point = CGPoint(x: bits(s["x"])!, y: bits(s["y"])!)
                    let hit = geometry.hitTest(point: point, in: square)
                    #expect(hit != nil, "\(where_) selection \(s["index"].int!)")
                    // Tied slices hold different names in Dart's unstable order.
                    let shown = centreTexts(b.centreLabel(selectedSlice: hit), money: money).dropFirst(unstable ? 1 : 0)
                    #expect(Array(shown) == Array(s["centre"].array.map { $0.string! }.dropFirst(unstable ? 1 : 0)),
                            "\(where_) selection \(s["index"].int!)")
                    let tinted = b.visibleRecords(expanded: false).map(\.rank).filter {
                        CategoryBreakdown.isRowHighlighted(rank: $0, selectedSlice: hit)
                    }
                    #expect(tinted == s["tinted"].array.map { $0.int! }, "\(where_) tint \(s["index"].int!)")
                }
            }
        }
    }

    @Test("donut taps: hit test, deselect rules, ring edges, gaps, bulge, centre, outside")
    func donutTaps() throws {
        let distributions = try fixture("donut.json")["distributions"].array
        #expect(distributions.count == 9)
        for d in distributions {
            let name = d["name"].string!
            let geometry = DonutGeometry(values: d["values"].array.map { bits($0)! })
            let selected = d["selected"].int!
            let points = d["points"].array
            #expect(points.count > 1000)
            for p in points {
                let point = CGPoint(x: bits(p["x"])!, y: bits(p["y"])!)
                let at = "\(name) (\(hex(point.x)), \(hex(point.y)))"
                func dart(_ tap: DonutGeometry.Tap) -> Int? {
                    switch tap {
                    case .select(let i): i
                    case .deselect: -1
                    case .ignore: nil
                    }
                }
                #expect(dart(geometry.tap(at: point, in: square, selectedIndex: nil)) == p["unselected"].int, "\(at) unselected")
                #expect(dart(geometry.tap(at: point, in: square, selectedIndex: selected)) == p["selected"].int, "\(at) selected")
                #expect(geometry.hitTest(point: point, in: square) == p["unselected"].int, "\(at) hit")
            }
        }
    }

    @Test("donut arcs through the sweep-in, unselected and selected")
    func donutArcs() throws {
        for d in try fixture("donut.json")["distributions"].array {
            let name = d["name"].string!
            let geometry = DonutGeometry(values: d["values"].array.map { bits($0)! })
            for (key, selected) in [("frames", nil as Int?), ("selectedFrames", d["selected"].int)] {
                let frames = d[key].array
                #expect(frames.count == 9)
                for (f, frame) in frames.enumerated() {
                    let sweep = bits(frame["sweep"])!
                    let swift = geometry.arcs(sweep: sweep, selectedIndex: selected)
                    let dart = frame["arcs"].array
                    #expect(swift.count == dart.count, "\(name) \(key) \(f) count")
                    for (a, w) in zip(swift, dart) {
                        let at = "\(name) \(key) \(f) arc \(a.index)"
                        #expect(a.index == w["index"].int, "\(at)")
                        #expect(hex(a.startAngle) == w["start"].string && hex(a.sweepAngle) == w["sweep"].string, "\(at) angles")
                        #expect(hex(a.radius) == w["radius"].string && hex(a.lineWidth) == w["strokeWidth"].string, "\(at) ring")
                        #expect(w["centerX"].string == hex(120) && w["centerY"].string == hex(120), "\(at)")
                        #expect(w["cap"].string == "butt" && w["style"].string == "stroke" && w["useCenter"].bool == false, "\(at)")
                    }
                }
            }
        }
    }

    @Test("donut geometry by hand")
    func geometryByHand() {
        let two = DonutGeometry(values: [1, 1])
        let arcs = two.arcs(selectedIndex: nil)
        let gap = 2 * Double.pi * 0.005
        #expect(arcs.map(\.startAngle) == [-Double.pi / 2, -Double.pi / 2 + Double.pi])
        #expect(arcs.map(\.sweepAngle) == [Double.pi - gap, Double.pi - gap])
        #expect(arcs.map(\.innerRadius) == [90, 90] && arcs.map(\.outerRadius) == [120, 120])
        let selected = two.arcs(selectedIndex: 1)
        #expect(selected[1].radius == 102 && selected[1].lineWidth == 36 && selected[1].innerRadius == 84)
        #expect(two.arcs(sweep: 0, selectedIndex: nil).isEmpty)
        // Halfway through the sweep the second slice starts at 3 o'clock.
        #expect(two.arcs(sweep: 0.5, selectedIndex: nil).map(\.startAngle) == [-Double.pi / 2, 0])

        #expect(two.hitTest(point: CGPoint(x: 125, y: 15), in: square) == 0)
        #expect(two.hitTest(point: CGPoint(x: 115, y: 225), in: square) == 1)
        #expect(two.hitTest(point: CGPoint(x: 120, y: 0), in: square) == 0)  // r 120, 12 o'clock
        #expect(two.hitTest(point: CGPoint(x: 120, y: 30), in: square) == 0)  // r 90
        #expect(two.hitTest(point: CGPoint(x: 120, y: 33), in: square) == nil)  // r 87: the selected bulge
        #expect(two.hitTest(point: CGPoint(x: 120, y: 120), in: square) == nil)
        #expect(two.hitTest(point: CGPoint(x: 1, y: 1), in: square) == nil)  // corner
        #expect(two.hitTest(point: CGPoint(x: 240, y: 120), in: square) == nil)  // outside the square
        #expect(two.tap(at: CGPoint(x: 120, y: 33), in: square, selectedIndex: 0) == .deselect)
        #expect(two.tap(at: CGPoint(x: 120, y: 120), in: square, selectedIndex: nil) == .ignore)
        #expect(two.tap(at: CGPoint(x: 125, y: 15), in: square, selectedIndex: 0) == .deselect)
        #expect(two.tap(at: CGPoint(x: 125, y: 15), in: square, selectedIndex: 1) == .select(0))
        #expect(two.tap(at: CGPoint(x: 260, y: 15), in: square, selectedIndex: 1) == .ignore)
        // A stale selection still counts: a miss clears it.
        #expect(two.tap(at: CGPoint(x: 120, y: 120), in: square, selectedIndex: 7) == .deselect)

        // Tiny slice: never drawn, still hit-testable at its range.
        let tiny = DonutGeometry(values: [999, 1])
        #expect(tiny.arcs(selectedIndex: nil).map(\.index) == [0])
        let f = 0.9995, r = 105.0
        let p = CGPoint(x: 120 + r * sin(2 * .pi * f), y: 120 - r * cos(2 * .pi * f))
        #expect(tiny.hitTest(point: p, in: square) == 1)
        #expect(DonutGeometry(values: [0, 0]).hitTest(point: CGPoint(x: 120, y: 10), in: square) == nil)
    }

    @Test("month selection: newest with data, fallback when the month vanishes")
    func monthResolution() {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let months = [calendar.date(2027, 2), calendar.date(2026, 9), calendar.date(2026, 7)]
        #expect(SpendMonth.resolve(selected: nil, available: months) == .init(month: months[0], resetsSelection: true))
        #expect(SpendMonth.resolve(selected: calendar.date(2026, 9, 15, 10), available: months)
            == .init(month: calendar.date(2026, 9, 15, 10), resetsSelection: false))
        #expect(SpendMonth.resolve(selected: calendar.date(2026, 8), available: months) == .init(month: months[0], resetsSelection: true))
        #expect(SpendMonth.resolve(selected: calendar.date(2026, 8), available: []) == .init(month: calendar.date(2026, 8), resetsSelection: false))
        #expect(SpendMonth.resolve(selected: nil, available: []) == .init(month: nil, resetsSelection: false))
    }

    @Test("ties keep first appearance; exact names; counts per exact name")
    func tiesAndNames() {
        var summary = MonthSummary()
        summary.categoryExpenses = [("B", 5), ("Cafe\u{301}", 5), ("A", 9), ("Café", 5), ("Z", 0), ("N", -1), ("Q", -0.0)]
        summary.categoryExpenseCounts = [1, 2, 3, 4, 5, 6, 7]
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let b = CategoryBreakdown.build(
            month: calendar.date(2026, 9), previousMonth: calendar.date(2026, 8), summary: summary,
            previousSummary: MonthSummary(), budgetLimits: [("Café", 4)], activeExpenseCategories: ["A", "Café", "A", "B"])
        #expect(b.records.map(\.name).map { Array($0.utf16) } == ["A", "B", "Cafe\u{301}", "Café", "Z", "Q", "N"].map { Array($0.utf16) })
        #expect(b.records.map(\.count) == [3, 1, 2, 4, 5, 7, 6])
        #expect(b.records.map(\.activeIndex) == [0, 2, nil, 1, nil, nil, nil])
        #expect(b.records[3].budgetLimit == 4 && b.records[2].budgetLimit == nil && b.records[3].isOverLimit)
        #expect(b.records[6].palette == .chart(DartString.hashCode("N") % 14))
        #expect(b.previousTotal == nil && b.delta == nil)
        #expect(b.tail?.title == "1 more category" && b.slices.last?.label == "Other")
        #expect(b.centreLabel(selectedSlice: 6) == .slice(title: "OTHER", value: -1, percentText: "-4%"))
    }
}
