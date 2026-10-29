import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class TagRuleModelTests: XCTestCase {
    /// Before the store is loaded nothing can change and nothing is written.
    func testEditsBeforeLoadDoNothing() async {
        let model = AppModel()
        let tag = await model.addTag(name: "Work")
        XCTAssertEqual(tag, .unchanged)
        let deletedTag = await model.deleteTag(id: "t1")
        XCTAssertEqual(deletedTag, .unchanged)
        let rule = await model.addRule(RuleDraft(merchantPattern: "Whole Foods", transactionType: .expense, category: "Groceries"))
        XCTAssertEqual(rule, .unchanged)
        let deletedRule = await model.deleteRule(id: "r1")
        XCTAssertEqual(deletedRule, .unchanged)
        let updatedRule = await model.updateRule(
            id: "r1", RuleDraft(merchantPattern: "Whole Foods", transactionType: nil, maximumAmount: 20, category: "Groceries"))
        XCTAssertEqual(updatedRule, .unchanged)
        let switched = await model.setRuleEnabled(id: "r1", false)
        XCTAssertEqual(switched, .unchanged)
        XCTAssertEqual(model.tags, [])
        XCTAssertEqual(model.rules, [])
        XCTAssertNil(model.validateTagName(""))
        XCTAssertNil(model.gatedSuggestion(type: .expense, description: "whole foods", amount: 1))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    /// The outcome carries Flutter's copy for the caller's message.
    func testRejectedOutcomeCarriesFlutterCopy() {
        let outcome = AppModel.EditOutcome<CategorizationEditError>.rejected(.duplicateTagName)
        guard case .rejected(let error) = outcome else { return XCTFail() }
        XCTAssertEqual(error.message, "A tag with this name already exists")
        XCTAssertEqual(CategorizationEditError.tagNameRequired.message, "Tag name is required")
    }

    /// The rule dialog's category: the pick while the list has it (UTF-16
    /// equality), else the list's first.
    func testResolvedCategory() {
        let expense = ["Gift", "Groceries", "General"]
        XCTAssertEqual(RuleEditorDialog.resolvedCategory(nil, in: expense), "Gift")
        XCTAssertEqual(RuleEditorDialog.resolvedCategory("Groceries", in: expense), "Groceries")
        XCTAssertEqual(RuleEditorDialog.resolvedCategory("groceries", in: expense), "Gift", "case-sensitive")
        // Precomposed vs decomposed e-acute: different UTF-16, so not kept.
        XCTAssertEqual(RuleEditorDialog.resolvedCategory("Caf\u{00E9}", in: ["Cafe\u{0301}", "Other"]), "Cafe\u{0301}")
        XCTAssertEqual(RuleEditorDialog.resolvedCategory("Gift", in: []), "")
    }

    /// Flutter's type switch: the shown category survives when the new type
    /// has it, including the untouched default (Flutter starts at the first
    /// expense category, not at "nothing picked").
    func testCategoryAfterTypeChange() {
        let expense = ["Gift", "Groceries"]
        let income = ["Salary", "Gift"]
        XCTAssertEqual(RuleEditorDialog.categoryAfterTypeChange(nil, from: expense, to: income), "Gift")
        XCTAssertEqual(RuleEditorDialog.categoryAfterTypeChange("Groceries", from: expense, to: income), "Salary")
        XCTAssertEqual(RuleEditorDialog.categoryAfterTypeChange(nil, from: ["General"], to: income), "Salary")
        XCTAssertEqual(RuleEditorDialog.categoryAfterTypeChange("Gift", from: income, to: expense), "Gift")
    }

    /// Flutter's exact rule subtitle for a rule its dialog could make: raw
    /// match type, category, and " · n tags" (never singular) when it has
    /// tags. Nothing else is added for either type.
    func testRuleSubtitle() {
        func rule(_ match: MerchantMatchType, _ category: String, _ tags: [String], _ type: TransactionType = .expense)
            -> CategorizationRuleRecord
        {
            .make(id: "r", RuleDraft(
                merchantPattern: "Whole Foods", matchType: match, transactionType: type, category: category, tagIds: tags))
        }
        func subtitle(_ rule: CategorizationRuleRecord) -> String { TagsRulesView.ruleSubtitle(rule, formatter: usd) }
        XCTAssertEqual(subtitle(rule(.contains, "Groceries", [])), "contains \u{00B7} Groceries")
        XCTAssertEqual(subtitle(rule(.contains, "Groceries", ["t1"])), "contains \u{00B7} Groceries \u{00B7} 1 tags")
        XCTAssertEqual(subtitle(rule(.startsWith, "Salary", ["t1", "t2"], .income)), "startsWith \u{00B7} Salary \u{00B7} 2 tags")
        XCTAssertEqual(subtitle(rule(.exact, "Housing", [])), "exact \u{00B7} Housing")
    }

    private let usd = MoneyFormatter(currencyCode: "USD", locale: "en_US", hideBalances: false)

    /// The Swift-only parts follow Flutter's string: any type, the bounds,
    /// off; Hide balances masks the amounts.
    func testRuleSubtitleSwiftParts() {
        func subtitle(
            type: TransactionType? = .expense, min: Double? = nil, max: Double? = nil, enabled: Bool = true,
            tags: [String] = [], formatter: MoneyFormatter? = nil
        ) -> String {
            TagsRulesView.ruleSubtitle(
                .make(id: "r", RuleDraft(
                    merchantPattern: "Cafe", transactionType: type, minimumAmount: min, maximumAmount: max, category: "Gift",
                    tagIds: tags, isEnabled: enabled)),
                formatter: formatter ?? usd)
        }
        let dot = " \u{00B7} "
        XCTAssertEqual(subtitle(type: nil), "contains\(dot)Gift\(dot)any type")
        XCTAssertEqual(subtitle(min: 5), "contains\(dot)Gift\(dot)at least $5.00")
        XCTAssertEqual(subtitle(max: 1500), "contains\(dot)Gift\(dot)up to $1,500.00")
        XCTAssertEqual(subtitle(min: 5, max: 20.5), "contains\(dot)Gift\(dot)$5.00 to $20.50")
        XCTAssertEqual(subtitle(min: 20, max: 20), "contains\(dot)Gift\(dot)exactly $20.00")
        XCTAssertEqual(subtitle(enabled: false), "contains\(dot)Gift\(dot)off")
        XCTAssertEqual(
            subtitle(type: nil, max: 20, enabled: false, tags: ["t1"]),
            "contains\(dot)Gift\(dot)1 tags\(dot)any type\(dot)up to $20.00\(dot)off")
        let hidden = MoneyFormatter(currencyCode: "USD", locale: "en_US", hideBalances: true)
        XCTAssertEqual(subtitle(max: 20, formatter: hidden), "contains\(dot)Gift\(dot)up to \u{2022}\u{2022}\u{2022}\u{2022}")
    }

    /// Any type lists the expense names, then the income names they lack
    /// (UTF-16 equality), and notes a one-type category.
    func testAnyTypeCategories() {
        let expense = ["Groceries", "Gift", "Caf\u{00E9}"]
        let income = ["Salary", "Gift", "Cafe\u{0301}"]
        XCTAssertEqual(
            RuleEditorDialog.anyTypeCategories(expense: expense, income: income),
            ["Groceries", "Gift", "Caf\u{00E9}", "Salary", "Cafe\u{0301}"])
        XCTAssertNil(RuleEditorDialog.anyTypeNote("Gift", expense: expense, income: income))
        XCTAssertEqual(
            RuleEditorDialog.anyTypeNote("Groceries", expense: expense, income: income),
            "Only expenses have Groceries, so income won't be categorized by this rule.")
        XCTAssertEqual(
            RuleEditorDialog.anyTypeNote("Salary", expense: expense, income: income),
            "Only income has Salary, so expenses won't be categorized by this rule.")
        XCTAssertNil(RuleEditorDialog.anyTypeNote("Archived", expense: expense, income: income))
        XCTAssertEqual(RuleEditorDialog.typeLabel(nil), "Any type")
        XCTAssertEqual(RuleEditorDialog.types.map(RuleEditorDialog.typeLabel), ["Income", "Expense", "Any type"])
    }

    /// Bound fields: empty is no bound; the prefill keeps the stored value
    /// exactly; otherwise the locale parse (0 or more), nil when invalid.
    func testBoundParsing() {
        func bound(_ text: String, prefill: String = "", stored: Double? = nil, formatter: MoneyFormatter? = nil) -> Double?? {
            RuleEditorDialog.bound(text, prefill: prefill, stored: stored, formatter: formatter ?? usd)
        }
        XCTAssertEqual(bound(""), .some(nil))
        XCTAssertEqual(bound("  "), .some(nil))
        XCTAssertEqual(bound("20"), .some(20))
        XCTAssertEqual(bound("1,500.25"), .some(1500.25))
        XCTAssertEqual(bound("0"), .some(0))
        XCTAssertEqual(bound("-5"), .none)
        XCTAssertEqual(bound("abc"), .none)
        XCTAssertEqual(bound("1e3"), .none)
        // The stored 0.30000000000000004 prefills as "0.30" and stays exact.
        let stored = 0.1 + 0.2
        let prefill = RuleEditorDialog.prefill(stored, formatter: usd)
        XCTAssertEqual(prefill, "0.30")
        XCTAssertEqual(bound(prefill, prefill: prefill, stored: stored), .some(stored))
        XCTAssertEqual(bound("0.3", prefill: prefill, stored: stored), .some(0.3))
        XCTAssertEqual(bound("", prefill: prefill, stored: stored), .some(nil), "cleared")
        XCTAssertEqual(RuleEditorDialog.prefill(nil, formatter: usd), "")
        // A comma-decimal format.
        let euro = MoneyFormatter(currencyCode: "EUR", locale: "de_DE", hideBalances: false)
        XCTAssertEqual(bound("12,5", formatter: euro), .some(12.5))
        XCTAssertEqual(RuleEditorDialog.prefill(1500, formatter: euro), "1.500,00")
    }
}
