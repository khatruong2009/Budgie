import XCTest

/// Performance on a 10,000-row store (docs/PERFORMANCE.md). Skipped unless
/// `TEST_RUNNER_BUDGIE_PERF=1` is passed to xcodebuild, so the normal suites
/// never run it. It needs the store that `scripts/perf_seed.py` installs on
/// the simulator (not the UI tests' empty install): `scripts/perf_run.sh`
/// does both. Nothing here changes data. The numbers to read are the
/// signposts (`XCTOSSignpostMetric`) and the scroll metrics; the clock of a
/// block that drives the UI includes XCUITest's own overhead.
@MainActor
final class PerformanceUITests: XCTestCase {
    let app = XCUIApplication()

    private static let subsystem = "com.khatruong.budgetbuddy"

    private var iterations: Int {
        ProcessInfo.processInfo.environment["BUDGIE_PERF_ITERATIONS"].flatMap(Int.init) ?? 10
    }

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BUDGIE_PERF"] == "1", "Set TEST_RUNNER_BUDGIE_PERF=1 (scripts/perf_run.sh).")
    }

    // MARK: - Helpers

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        // XCTest runs the block `iterationCount + 1` times; the first is a warm-up.
        options.iterationCount = iterations
        return options
    }

    /// For blocks that call `startMeasuring` / `stopMeasuring` themselves.
    private var manualOptions: XCTMeasureOptions {
        let options = options
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    private func signpost(_ category: String, _ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: Self.subsystem, category: category, name: name)
    }

    private var scrollMetrics: [any XCTMetric] {
        var metrics: [any XCTMetric] = [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app), XCTClockMetric(),
        ]
        if #available(iOS 26, *) { metrics.append(XCTHitchMetric(application: app)) }
        return metrics
    }

    private func launchToHome() {
        app.budgie(homeTimeout: 60)
    }

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    /// Flow > SEE ALL, and proof that the 10,000-row store is installed.
    private func openFlowSeeAll() {
        tab("Flow")
        XCTAssertTrue(app.element("flow.netCashFlow").waitForExistence(timeout: 10))
        let seeAll = app.buttons["See all transactions"].firstMatch
        for _ in 0..<4 where !seeAll.isHittable { app.swipeUp() }
        seeAll.tap()
        let count = app.element("flow.all.count")
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.hasSuffix("of 10000"), "the perf store is installed: \(count.label)")
    }

    // MARK: - Launch

    func testLaunchToReady() {
        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric(),
                signpost("Launch", "bootstrap"), signpost("Launch", "store.read"),
                signpost("Launch", "FinancialData.load"), signpost("Launch", "recurringGeneration"),
                signpost("Launch", "ledgerIndex.first"), signpost("Launch", "insights.first"),
                signpost("Ledger", "LedgerIndex.build"), signpost("Ledger", "insights.generate"),
            ], options: options
        ) {
            app.budgie(homeTimeout: 60)
        }
    }

    // MARK: - Tabs

    func testTabSwitches() {
        launchToHome()
        measure(
            metrics: [XCTClockMetric(), signpost("UI", "tabSwitch"), XCTCPUMetric(application: app)], options: options
        ) {
            tab("Worth")
            XCTAssertTrue(app.element("worth.hero").waitForExistence(timeout: 10))
            tab("Goals")
            XCTAssertTrue(app.element("goals.summary").waitForExistence(timeout: 10))
            tab("Spend")
            XCTAssertTrue(app.element("spend.donut").waitForExistence(timeout: 10))
            tab("Flow")
            XCTAssertTrue(app.element("flow.netCashFlow").waitForExistence(timeout: 10))
            tab("Home")
            XCTAssertTrue(app.element("home.settings").waitForExistence(timeout: 10))
        }
    }

    /// The first visit to a tab builds its content (the tab view is lazy),
    /// once per process: each iteration is a fresh launch and one switch.
    private func measureFirstVisit(_ name: String, marker: String) {
        measure(
            metrics: [signpost("UI", "tabSwitch"), XCTClockMetric(), XCTCPUMetric(application: app)],
            options: manualOptions
        ) {
            launchToHome()
            startMeasuring()
            tab(name)
            XCTAssertTrue(app.element(marker).waitForExistence(timeout: 20))
            stopMeasuring()
        }
    }

    func testFirstVisitWorth() { measureFirstVisit("Worth", marker: "worth.hero") }
    func testFirstVisitGoals() { measureFirstVisit("Goals", marker: "goals.summary") }
    func testFirstVisitSpend() { measureFirstVisit("Spend", marker: "spend.donut") }
    func testFirstVisitFlow() { measureFirstVisit("Flow", marker: "flow.netCashFlow") }

    /// Everything that re-runs Home's body: the add sheet opening and
    /// closing, and the month panel. `home.safeToSpend` is the suspect.
    func testHomeBodyRerenders() {
        launchToHome()
        let monthPill = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[A-Z][a-z]+ 20[0-9]{2}")).firstMatch
        measure(
            metrics: [signpost("UI", "home.safeToSpend"), XCTClockMetric(), XCTCPUMetric(application: app)], options: options
        ) {
            app.buttons["Add transaction"].tap()
            XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 10))
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tapSettled()
            XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 10))
            if monthPill.exists { monthPill.tap(); monthPill.tap() }
        }
    }

    // MARK: - Lists

    func testFlowSeeAllScroll() {
        launchToHome()
        openFlowSeeAll()
        for _ in 0..<2 {
            let more = app.element("flow.all.loadMore")
            for _ in 0..<4 where !more.isHittable { app.swipeUp() }
            if more.isHittable { more.tap() }
        }
        app.swipeDown(velocity: .fast)
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }

    /// One keystroke per measured region: `flow.refilter` is one interval.
    private func measureKeystroke(_ text: String) {
        launchToHome()
        openFlowSeeAll()
        let search = app.textFields["flow.all.search"]
        search.tapSettled()
        measure(
            metrics: [signpost("UI", "flow.refilter"), XCTClockMetric(), XCTCPUMetric(application: app)],
            options: manualOptions
        ) {
            startMeasuring()
            search.typeText(text)
            stopMeasuring()
            // Back to the empty filter (a second refilter, not measured).
            search.typeSettled(XCUIKeyboardKey.delete.rawValue)
        }
    }

    /// "c" matches most of the 10,000 rows (the largest result set).
    func testFlowFilterTypingWide() { measureKeystroke("c") }

    /// "q" matches none.
    func testFlowFilterTypingNarrow() { measureKeystroke("q") }

    /// Home itself (hero blur, gauge, budget bars, FABs) and Spend's page
    /// (donut, progress glows): the glow-heavy screens.
    func testHomeScroll() {
        launchToHome()
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }

    func testSpendScroll() {
        launchToHome()
        tab("Spend")
        XCTAssertTrue(app.element("spend.donut").waitForExistence(timeout: 10))
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }

    func testHomeSeeAllScroll() {
        launchToHome()
        let seeAll = app.buttons["See all transactions"].firstMatch
        for _ in 0..<4 where !seeAll.isHittable { app.swipeUp() }
        seeAll.tap()
        XCTAssertTrue(app.staticTexts["Transactions"].waitForExistence(timeout: 10))
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }

    func testSpendDrillInScroll() {
        launchToHome()
        tab("Spend")
        let row = app.buttons["spend.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.element("spend.drillIn.summary").waitForExistence(timeout: 10))
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }

    // MARK: - Worth history (500 snapshots, built eagerly)

    private func openPerfHistory() {
        tab("Worth")
        let row = app.element("worth.account.Perf History")
        for _ in 0..<6 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "the Perf History account")
        row.press(forDuration: 1.0)
        let view = app.buttons["View History"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()
    }

    func testWorthHistoryOpen() {
        launchToHome()
        tab("Worth")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: manualOptions) {
            let row = app.element("worth.account.Perf History")
            for _ in 0..<6 where !row.exists || !row.isHittable { app.swipeUp() }
            row.press(forDuration: 1.0)
            let view = app.buttons["View History"]
            XCTAssertTrue(view.waitForExistence(timeout: 5))
            startMeasuring()
            view.tap()
            XCTAssertTrue(app.element("worth.history.hero").waitForExistence(timeout: 20))
            stopMeasuring()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
        }
    }

    func testWorthHistoryScroll() {
        launchToHome()
        openPerfHistory()
        XCTAssertTrue(app.element("worth.history.hero").waitForExistence(timeout: 20))
        measure(metrics: scrollMetrics, options: options) {
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
    }
}
