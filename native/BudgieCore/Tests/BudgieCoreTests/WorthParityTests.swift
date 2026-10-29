import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("worth/\(name)")
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

private func ohex(_ value: Double?) -> String? { value.map { hex($0) } }

/// One line per entry, as the harness writes the model's memory.
private func memoryLines(_ data: FinancialData) -> [String] {
    ["selected \(data.selectedNetWorthMonth.toIso8601String())"]
        + data.netWorthEntries.map { e in
            let snapshots = e.snapshots.map { "\($0.recordedAt.toIso8601String())=\(hex($0.amount))" }
            return "\(e.id)|\(e.name)|\(e.type.rawValue)|\(e.createdAt.toIso8601String())|\(snapshots.joined(separator: ","))"
        }
}

private func memoryLines(_ memory: J) -> [String] {
    ["selected \(memory["selected"].string!)"]
        + memory["entries"].array.map { e in
            let snapshots = e["snapshots"].array.map { "\($0[0].string!)=\($0[1].string!)" }
            return "\(e["id"].string!)|\(e["name"].string!)|\(e["type"].string!)|\(e["createdAt"].string!)|\(snapshots.joined(separator: ","))"
        }
}

private func load(_ sections: JSONObject, calendar: DartCalendar, now: DartDateTime) -> FinancialData {
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }
    ).data
}

@Suite("Worth: net worth mutations, queries and display strings match the Flutter code (Fixtures/worth)")
struct WorthParityTests {
    /// Real `TransactionModel` calls through a real store, replayed on
    /// `FinancialData`: after every call the two agree on whether a write is
    /// due and on the model's memory; for data Dart wrote itself the stored
    /// `netWorthEntries` bytes are identical; `selectedNetWorthMonth` always
    /// is. Whatever Swift wrote loads back to the same memory.
    @Test("mutation scenarios", arguments: dstFixtureZones)
    func mutations(zone: String) throws {
        let f = try Fixtures.json("\(Fixtures.zonePath("worth", zone))/mutations.json")
        #expect(f["tz"].string == zone)
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let scenarios = f["scenarios"].array
        #expect(scenarios.count == 3)
        for s in scenarios {
            let label = "\(zone) \(s["name"].string!)"
            let byteComparable = s["byteComparable"].bool!
            var now = try calendar.parse(s["launch"].string!)
            let initial = try s["initial"].string.map { try JSONParser.parse($0).objectValue! } ?? JSONObject()
            var data = load(initial, calendar: calendar, now: now)
            #expect(memoryLines(data) == memoryLines(s["loaded"]), "\(label) load")

            for (index, step) in s["steps"].array.enumerated() {
                let at = "\(label) step \(index) \(step["op"].string!)"
                if step["op"].string == "clock" {
                    now = try calendar.parse(step["now"].string!)
                    continue
                }
                #expect(step["now"].string == now.toIso8601String(), "\(at) clock")
                func date(_ key: String) throws -> DartDateTime? { try step[key].string.map { try calendar.parse($0) } }
                var swiftWrote: Bool
                var dartWrote = step["wrote"].bool!
                switch step["op"].string! {
                case "select":
                    data.selectNetWorthMonth(try date("date")!)
                    swiftWrote = true
                case "add":
                    let added = data.addNetWorthEntry(
                        name: step["name"].string!, type: NetWorthEntryType(rawValue: step["type"].string!)!,
                        amount: bits(step["amount"])!, month: try date("month"), recordedAt: try date("recordedAt"),
                        id: step["newId"].string ?? "unused", now: now)
                    swiftWrote = added != nil
                case "update":
                    let id = step["id"].string!
                    // Dart writes the unchanged list for an unknown id; Swift writes nothing.
                    if data.netWorthEntry(id: id) == nil { dartWrote = false }
                    swiftWrote = data.updateNetWorthEntry(
                        id: id, name: step["name"].string!, type: NetWorthEntryType(rawValue: step["type"].string!)!,
                        amount: bits(step["amount"])!, month: try date("month"), recordedAt: try date("recordedAt"), now: now)
                case "deleteEntry":
                    let id = step["id"].string!
                    if data.netWorthEntry(id: id) == nil { dartWrote = false }
                    swiftWrote = data.deleteNetWorthEntry(id: id)
                case "deleteSnapshot":
                    swiftWrote = data.deleteNetWorthSnapshot(entryID: step["id"].string!, recordedAt: try date("recordedAt")!)
                case "carry":
                    swiftWrote = data.carryNetWorthMonthForward(try date("month")!, now: now)
                    #expect(swiftWrote == step["result"].bool, "\(at) result")
                default:
                    Issue.record("unknown op in \(at)")
                    continue
                }
                #expect(swiftWrote == dartWrote, "\(at) wrote")
                #expect(memoryLines(data) == memoryLines(step["memory"]), "\(at) memory")
                // Only a selection writes the section (both apps); before one
                // the stored string is whatever was loaded.
                if step["op"].string == "select" {
                    #expect(data.selectedNetWorthMonthSection().stringValue == step["selectedSection"].string, "\(at) selected section")
                }
                let swiftSection = DartJSON.encodeString(data.netWorthSection())
                if byteComparable {
                    let dartSection = step["section"].string ?? "[]"
                    #expect(Array(swiftSection.utf16) == Array(dartSection.utf16), "\(at) section:\n\(swiftSection)\n\(dartSection)")
                }
                // What Swift would write loads back as the same memory.
                var written = JSONObject()
                written[Section.netWorthEntries] = data.netWorthSection()
                written[Section.selectedNetWorthMonth] = data.selectedNetWorthMonthSection()
                #expect(memoryLines(load(written, calendar: calendar, now: now)) == memoryLines(data), "\(at) reload")
            }
            try checkQueries(data, s["queries"], now: now, label: label)
        }
    }

    private func checkQueries(_ data: FinancialData, _ q: J, now: DartDateTime, label: String) throws {
        let calendar = data.calendar
        let formatter = MoneyFormatter()
        #expect(data.netWorthAvailableMonths(now: now).map { $0.toIso8601String() } == q["availableMonths"].array.map { $0.string! },
                "\(label) available months")
        for m in q["months"].array {
            let month = try calendar.parse(m["month"].string!)
            let at = "\(label) \(m["month"].string!)"
            let assets = data.totalAssets(forMonth: month), liabilities = data.totalLiabilities(forMonth: month)
            #expect(hex(assets) == m["assets"].string, "\(at) assets")
            #expect(hex(liabilities) == m["liabilities"].string, "\(at) liabilities")
            let netWorth = data.netWorth(forMonth: month)
            #expect(hex(netWorth) == m["netWorth"].string, "\(at) net worth")
            let change = data.netWorthChange(forMonth: month)
            #expect(ohex(change) == m["change"].string, "\(at) change")
            #expect(change.map { NetWorthText.deltaPill(change: $0, previousNetWorth: netWorth - $0, formatter: formatter) } == m["deltaPill"].string,
                    "\(at) delta pill")
            #expect(data.hasNetWorthData(forMonth: month) == m["hasData"].bool, "\(at) hasData")
            #expect(data.trackedNetWorthEntryCount(forMonth: month) == m["tracked"].int, "\(at) tracked")
            #expect(data.updatedNetWorthEntryCount(forMonth: month) == m["updated"].int, "\(at) updated")
            #expect(data.staleNetWorthEntryCount(forMonth: month) == m["stale"].int, "\(at) stale")
            #expect(data.netWorthEntries(forMonth: month).map(\.id) == m["all"].array.map { $0.string! }, "\(at) order")
            for (key, type, total) in [("assetRows", NetWorthEntryType.asset, assets), ("liabilityRows", .liability, liabilities)] {
                let entries = data.netWorthEntries(forMonth: month, type: type)
                let rows = m[key].array
                #expect(entries.map(\.id) == rows.map { $0["id"].string! }, "\(at) \(key) order")
                for (entry, row) in zip(entries, rows) {
                    let stats = entry.rowStats(forMonth: month, categoryTotal: total, calendar: calendar)
                    let r = "\(at) \(key) \(entry.name)"
                    #expect(stats.effective?.recordedAt.toIso8601String() == row["effective"].string, "\(r) effective")
                    #expect(stats.previous?.recordedAt.toIso8601String() == row["previous"].string, "\(r) previous")
                    #expect(hex(stats.amount) == row["amount"].string, "\(r) amount")
                    #expect(hex(stats.share) == row["share"].string, "\(r) share")
                    #expect(ohex(stats.percentChange) == row["percentChange"].string, "\(r) change")
                    #expect(stats.changeIsFavorable == row["favorable"].bool, "\(r) favorable")
                    #expect(NetWorthText.rowShare(stats.share, isAssetsTab: type == .asset) == row["shareLabel"].string, "\(r) share label")
                    #expect(NetWorthText.rowChange(stats.percentChange) == row["changeText"].string, "\(r) change text")
                }
            }
            #expect(hex(NetWorthPresentation.splitFraction(assets: assets, liabilities: liabilities)) == m["split"].string, "\(at) split")
        }

        func checkHistory(_ points: [NetWorthHistoryPoint], _ expected: J, _ name: String) {
            #expect(points.count == expected.array.count, "\(label) \(name) count")
            for (p, e) in zip(points, expected.array) {
                #expect(p.date.toIso8601String() == e["date"].string, "\(label) \(name) date")
                #expect(hex(p.assets) == e["assets"].string && hex(p.liabilities) == e["liabilities"].string, "\(label) \(name) sums")
                #expect(p.assetCount == e["assetCount"].int && p.liabilityCount == e["liabilityCount"].int, "\(label) \(name) counts")
                #expect(p.granularity.rawValue == e["granularity"].string, "\(label) \(name) granularity")
            }
        }
        checkHistory(data.netWorthHistory(limit: 24), q["history24"], "history24")
        checkHistory(data.netWorthHistory(limit: 4), q["history4"], "history4")

        let chartData = Array(data.netWorthHistory(limit: 24).reversed())
        for range in NetWorthGrowthRange.allCases {
            let expected = q["ranges"][range.rawValue]
            let points = range.filter(chartData, calendar: calendar)
            #expect(points.map { $0.date.toIso8601String() } == expected["dates"].array.map { $0.string! }, "\(label) \(range) dates")
            let values = points.map(\.netWorth)
            let scale = NetWorthChartScale.growth(values)
            #expect([scale?.min, scale?.max].compactMap { $0 }.map { hex($0) } == expected["scale"].array.map { $0.string! },
                    "\(label) \(range) scale")
            for (i, h) in expected["hover"].array.enumerated() {
                let a = NetWorthPresentation.hoverAlignment(index: i, values: values)
                #expect(hex(a.x) == h[0].string && hex(a.y) == h[1].string && a.useBottom == h[2].bool, "\(label) \(range) hover \(i)")
            }
        }

        let accounts = q["accounts"].array
        #expect(data.netWorthEntries.map(\.id) == accounts.map { $0["id"].string! }, "\(label) accounts")
        for (entry, a) in zip(data.netWorthEntries, accounts) {
            let at = "\(label) history \(entry.name)"
            let history = NetWorthAccountHistory(history: data.netWorthEntryHistory(id: entry.id), type: entry.type)
            #expect(history.chart.map { "\($0.recordedAt.toIso8601String())=\(hex($0.amount))" }
                    == a["chart"].array.map { "\($0[0].string!)=\($0[1].string!)" }, "\(at) chart")
            #expect(history.timeline.map { ohex($0.delta) } == a["timelineDeltas"].array.map(\.string), "\(at) deltas")
            #expect(hex(history.latestAmount) == a["latestAmount"].string, "\(at) latest")
            #expect(ohex(history.changeFromPrevious) == a["changeFromPrevious"].string, "\(at) vs prior")
            #expect(ohex(history.totalChange) == a["totalChange"].string, "\(at) overall")
            #expect(history.totalChangeIsPositive == a["totalChangeIsPositive"].bool, "\(at) overall sign")
            #expect(ohex(history.peak) == a["peak"].string && ohex(history.low) == a["low"].string, "\(at) peak/low")
            let scale = NetWorthChartScale.account(history.chart.map(\.amount))
            #expect([scale?.min, scale?.max].compactMap { $0 }.map { hex($0) } == a["scale"].array.map { $0.string! }, "\(at) scale")
        }
        #expect(data.netWorthEntryHistory(id: "no-such-id").count == q["missingHistory"].int)
    }

    // MARK: - formatting.json

    @Test("compact currency and history deltas (intl 3 significant digits)")
    func compact() throws {
        let cases = try fixture("formatting.json")["compact"].array
        #expect(cases.count > 200)
        for c in cases {
            let formatter = MoneyFormatter(currencyCode: c["currency"].string!, locale: c["locale"].string, hideBalances: c["hidden"].bool!)
            let value = bits(c["value"])!
            let at = "\(c["currency"].string!) \(c["locale"].string ?? "-") \(c["hidden"].bool!) \(value)"
            #expect(formatter.formatCompact(value) == c["compact"].string, "\(at) compact")
            #expect(formatter.formatCompactDelta(value) == c["delta"].string, "\(at) delta")
        }
    }

    @Test("hero delta pill and accessibility label")
    func deltaPills() throws {
        for c in try fixture("formatting.json")["deltaPills"].array {
            let formatter = MoneyFormatter(currencyCode: c["currency"].string!, locale: c["locale"].string, hideBalances: c["hidden"].bool!)
            let change = bits(c["change"])!, previous = bits(c["previous"])!
            #expect(NetWorthText.deltaPill(change: change, previousNetWorth: previous, formatter: formatter) == c["text"].string,
                    "\(change) \(previous)")
            #expect(NetWorthText.heroAccessibilityLabel(netWorth: previous, formatter: formatter) == c["semantics"].string)
        }
    }

    @Test("editor amount: prefill, input formatter, save parse")
    func amountInput() throws {
        let f = try fixture("formatting.json")
        for c in f["prefill"].array {
            #expect(NetWorthAmountInput.prefill(bits(c["value"])!) == c["text"].string, "prefill \(bits(c["value"])!)")
        }
        for c in f["input"].array {
            #expect(NetWorthAmountInput.sanitize(old: c["old"].string!, new: c["new"].string!) == c["result"].string,
                    "input \(c["old"].string!) -> \(c["new"].string!)")
        }
        for c in f["parse"].array {
            // Swift also refuses non-finite values, which Dart accepts.
            let dart = bits(c["result"]).flatMap { $0.isFinite ? $0 : nil }
            #expect(ohex(NetWorthAmountInput.parse(c["text"].string!)) == ohex(dart), "parse \(c["text"].string!.prefix(12))")
        }
    }

    @Test("row percent strings, chart scales, hover alignment, split bar, icons")
    func presentation() throws {
        let f = try fixture("formatting.json")
        for c in f["percents"].array {
            #expect(NetWorthText.rowChange(bits(c["value"])!) == c["change"].string)
            #expect(NetWorthText.rowShare(bits(c["share"])!, isAssetsTab: true) == c["shareAssets"].string)
        }
        for c in f["scales"].array {
            let values = c["values"].array.map { bits($0)! }
            let growth = NetWorthChartScale.growth(values)!, account = NetWorthChartScale.account(values)!
            #expect([hex(growth.min), hex(growth.max)] == c["growth"].array.map { $0.string! }, "growth \(values)")
            #expect([hex(account.min), hex(account.max)] == c["account"].array.map { $0.string! }, "account \(values)")
            for (i, h) in c["hover"].array.enumerated() {
                let a = NetWorthPresentation.hoverAlignment(index: i, values: values)
                #expect(hex(a.x) == h[0].string && hex(a.y) == h[1].string && a.useBottom == h[2].bool, "hover \(values) \(i)")
            }
        }
        for c in f["splits"].array {
            let fraction = NetWorthPresentation.splitFraction(assets: bits(c["assets"])!, liabilities: bits(c["liabilities"])!)
            #expect(hex(fraction) == c["fraction"].string)
            let flex = NetWorthPresentation.splitFlex(fraction)
            #expect([flex.assets, flex.liabilities] == c["flex"].array.map { $0.int! })
        }
        for c in f["icons"].array {
            let icon = NetWorthAccountIcon(name: c["name"].string!, type: NetWorthEntryType(rawValue: c["type"].string!)!)
            #expect(icon.rawValue == c["icon"].string, "\(c["name"].string!) \(c["type"].string!)")
        }
    }

    @Test("date-based display strings")
    func texts() throws {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        for c in try fixture("formatting.json")["texts"].array {
            let p = c["date"].array.map { $0.int! }
            let d = calendar.date(p[0], p[1], p[2], p[3], p[4])
            #expect(NetWorthText.heroEyebrow(month: d) == c["eyebrow"].string)
            #expect(NetWorthText.emptyList(isAssetsTab: true, month: d) == c["emptyAssets"].string)
            #expect(NetWorthText.axisLabel(d) == c["axis"].string)
            let point = { (g: NetWorthHistoryPoint.Granularity) in
                NetWorthHistoryPoint(date: d, assets: 0, liabilities: 0, assetCount: 0, liabilityCount: 0, granularity: g)
            }
            #expect(NetWorthText.hoverTitle(point(.month)) == c["hoverMonth"].string)
            #expect(NetWorthText.hoverTitle(point(.day)) == c["hoverDay"].string)
            #expect(NetWorthText.lastUpdate(d) == c["lastUpdate"].string)
            #expect(NetWorthText.trendAxisLabel(d) == c["trendAxis"].string)
            let snapshot = NetWorthSnapshotRecord(recordedAt: d, amount: 1)
            #expect(NetWorthText.trendRange([snapshot, snapshot]) == c["trendRange"].string)
            #expect(NetWorthText.deleteSnapshotMessage(recordedAt: d, name: "Brokerage") == c["deleteSnapshot"].string)
        }
    }

    /// fl_chart 1.2.0's own `AxisChartHelper.iterateThroughAxis`, called
    /// as its grid painter does over both charts' scales (formatting.json
    /// `gridLines`), bit for bit.
    @Test("chart grid lines (fl_chart multiples of the interval from 0)")
    func gridLines() throws {
        let cases = try fixture("formatting.json")["gridLines"].array
        #expect(cases.count >= 8)
        for c in cases {
            let values = c["values"].array.map { bits($0)! }
            #expect(NetWorthChartScale.growth(values)!.gridLines.map(hex) == c["growth"].array.map { $0.string! }, "growth \(values)")
            #expect(NetWorthChartScale.account(values)!.gridLines.map(hex) == c["account"].array.map { $0.string! }, "account \(values)")
        }
    }

    /// Which points get an axis label: `_AxisLabels` and the account
    /// chart's titles through fl_chart's side-title iteration
    /// (formatting.json `axisLabels`, 1 to 30 points).
    @Test("axis label indices")
    func axisLabels() throws {
        let cases = try fixture("formatting.json")["axisLabels"].array
        #expect(cases.count == 30)
        for c in cases {
            let n = c["count"].int!
            #expect(NetWorthPresentation.growthAxisLabelIndices(count: n) == c["growth"].array.map { $0.int! }, "growth \(n)")
            #expect(NetWorthPresentation.accountAxisLabelIndices(count: n) == c["account"].array.map { $0.int! }, "account \(n)")
        }
    }

    @Test("chart spots (index x, one value drawn twice) and the x-only scrub hit")
    func chartSpots() {
        let scale = NetWorthChartScale(min: 0, max: 100)
        let size = CGSize(width: 300, height: 180)
        #expect(scale.points([50], size: size).map { [$0.x, $0.y] } == [[0, 90], [300, 90]])
        #expect(scale.points([0, 100, 25], size: size).map { [$0.x, $0.y] } == [[0, 180], [150, 0], [300, 135]])
        let two = scale.points([10, 20], size: size)
        // No 48pt threshold: a touch midway still picks a spot (the earlier on the tie).
        #expect(NetWorthPresentation.nearestSpot(toX: 150, in: two) == 0)
        #expect(NetWorthPresentation.nearestSpot(toX: 151, in: two) == 1)
        #expect(NetWorthPresentation.nearestSpot(toX: 48, in: two) == 0)
        #expect(NetWorthPresentation.nearestSpot(toX: 252, in: two) == 1)
        #expect(NetWorthPresentation.nearestSpot(toX: 100, in: []) == nil)
        // Wide plot, sparse points: every x lands on the nearest column.
        let wide = scale.points([1, 2, 3], size: CGSize(width: 800, height: 10))
        #expect(wide.map(\.x) == [0, 400, 800])
        #expect(NetWorthPresentation.nearestSpot(toX: 199, in: wide) == 0)
        #expect(NetWorthPresentation.nearestSpot(toX: 201, in: wide) == 1)
        #expect(NetWorthPresentation.nearestSpot(toX: 601, in: wide) == 2)
        // A tie keeps the earlier spot (fl_chart replaces only on a smaller distance).
        let three = scale.points([1, 2, 3], size: CGSize(width: 80, height: 10))
        #expect(NetWorthPresentation.nearestSpot(toX: 20, in: three) == 0)
        #expect(NetWorthPresentation.nearestSpot(toX: 21, in: three) == 1)
    }
}
