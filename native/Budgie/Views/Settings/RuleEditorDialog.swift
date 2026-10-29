import BudgieCore
import SwiftUI

/// The "New merchant rule" dialog (`_addRule`,
/// categorization_settings_page.dart:128-260) in the redesign's centred
/// card, and its Swift-only edit mode ("Edit merchant rule", prefilled,
/// Save). Fields in Flutter's order: "Merchant text" (hint "Whole Foods",
/// autofocused when new), "Type" (Income, Expense, and the Swift-only "Any
/// type"; default Expense), "Match" (Contains, Starts with, Exact match;
/// default Contains), "Category", then the tags as chips when there are
/// any, selected in tap order; then the Swift-only optional "Minimum
/// amount" / "Maximum amount" (inclusive, as Dart's `matches`). Cancel and
/// Add / Save.
///
/// Category lists: the type's active categories in order; for Any type
/// the expense list followed by the income names it lacks (UTF-16), since
/// the rule then serves both forms. The form only applies a suggestion
/// whose category is in its list (and tries no later rule), so an Any-type
/// rule on a one-type category says under the picker that the other type
/// won't be categorized. An edited rule's own category stays selectable
/// under its type even when archived or unknown, so Save never changes it
/// silently. Changing the type keeps the shown category (the picked one,
/// or the old list's first when none was picked, as Flutter's variable
/// starts at the first expense category) when the new list has that name
/// (UTF-16), else takes its first; the tag selection stays.
///
/// Amounts parse with the money format's separators (`AmountInput`, D6);
/// empty is no bound; an edit prefills a bound rounded to cents and a
/// field left as prefilled keeps the stored value exactly. Checked on
/// Add / Save, inline under the field: not an amount of 0 or more, and a
/// minimum above the maximum. Add / Save is disabled while the trimmed
/// merchant text is empty (Flutter's Add does nothing then). The write is
/// awaited with the dialog inert; it closes once written, and also when
/// the write failed (the change is in memory behind the unsaved banner),
/// with the save-failed toast. A refusal shows its message above the
/// buttons. The rule's priority and enabled state are kept as stored (the
/// switch is on the page's row).
///
/// The keyboard (Flutter's: no capitalisation, a Done key) goes away on
/// Done and when a dropdown opens, so the menu is not cut by it. With the
/// keyboard up the fields scroll; the scroll indicator flashes once the
/// keyboard is shown and the bottom edge fades while more is below, cues
/// that the fields below are there.
struct RuleEditorDialog: View {
    /// The rule to edit; nil adds a new one.
    let rule: CategorizationRuleRecord?
    let formatter: MoneyFormatter
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var pattern: String
    @State private var type: TransactionType?
    @State private var matchType: MerchantMatchType
    @State private var category: String?
    @State private var tagIds: [String]
    @State private var minimumText: String
    @State private var maximumText: String
    @State private var minimumError: String?
    @State private var maximumError: String?
    @State private var error: String?
    @State private var busy = false
    /// Flashes the fields' scroll indicator.
    @State private var scrollFlash = 0
    /// The edit's bound prefills, which stand for the stored bounds exactly.
    private let minimumPrefill: String
    private let maximumPrefill: String

    init(rule: CategorizationRuleRecord?, formatter: MoneyFormatter, onClose: @escaping () -> Void) {
        self.rule = rule
        self.formatter = formatter
        self.onClose = onClose
        minimumPrefill = Self.prefill(rule?.minimumAmount, formatter: formatter)
        maximumPrefill = Self.prefill(rule?.maximumAmount, formatter: formatter)
        _pattern = State(initialValue: rule?.merchantPattern ?? "")
        _type = State(initialValue: rule == nil ? .expense : rule?.transactionType)
        _matchType = State(initialValue: rule?.matchType ?? .contains)
        _category = State(initialValue: rule?.category)
        _tagIds = State(initialValue: rule?.tagIds ?? [])
        _minimumText = State(initialValue: minimumPrefill)
        _maximumText = State(initialValue: maximumPrefill)
    }

    private static let chipText = TextSpec(face: .gabaritoSemiBold, size: 13, relativeTo: .footnote)
    private static let chipSelectedText = TextSpec(face: .gabaritoBold, size: 13, relativeTo: .footnote)

    /// Flutter's `TransactionTyp.values` order, then the Swift-only nil.
    static let types: [TransactionType?] = [.income, .expense, nil]

    var body: some View {
        let categories = categoryNames(for: type)
        let selectedCategory = Self.resolvedCategory(category, in: categories)
        let canSubmit = !DartString.trim(pattern).isEmpty
        VStack(spacing: 0) {
            DialogTitle(text: rule == nil ? "New merchant rule" : "Edit merchant rule")
            DialogScroll { fields(categories: categories, selectedCategory: selectedCategory) }
                .scrollIndicatorsFlash(trigger: scrollFlash)
                .modifier(MoreBelowFade())
                .padding(.top, 20)
            if let error {
                Text(error)
                    .textStyle(.caption)
                    .foregroundStyle(BudgieColor.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Metrics.spacingM)
            }
            DialogButtons(
                cancelId: "rules.editor.cancel", submitTitle: rule == nil ? "Add" : "Save", submitId: "rules.editor.submit",
                submitEnabled: canSubmit, cancel: onClose
            ) { submit(category: selectedCategory) }
        }
        .disabled(busy)
        .budgieDialogDismissDisabled(busy)
        .onChange(of: pattern) { error = nil }
        .onChange(of: minimumText) {
            minimumError = nil
            error = nil
        }
        .onChange(of: maximumText) {
            maximumError = nil
            error = nil
        }
        .onChange(of: type) { old, new in
            category = Self.categoryAfterTypeChange(category, from: categoryNames(for: old), to: categoryNames(for: new))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            scrollFlash += 1
        }
    }

    private func fields(categories: [String], selectedCategory: String) -> some View {
        let symbol = AmountInput.currencySymbolName(formatter)
        return VStack(alignment: .leading, spacing: Metrics.spacingM) {
            BudgieField(
                title: "Merchant text", text: $pattern, prompt: "Whole Foods", capitalization: .never, autofocus: rule == nil)
                .submitLabel(.done)
                .onSubmit(Self.dismissKeyboard)
                .accessibilityIdentifier("rules.editor.pattern")
            MenuField(
                title: "Type", options: Self.types.map(Self.typeLabel),
                selection: Binding(
                    get: { Self.types.firstIndex(of: type) ?? 1 },
                    set: { type = Self.types[$0] }),
                identifier: "rules.editor.type")
            MenuField(
                title: "Match", options: MerchantMatchType.allCases.map(Self.matchLabel),
                selection: Binding(
                    get: { MerchantMatchType.allCases.firstIndex(of: matchType) ?? 0 },
                    set: { matchType = MerchantMatchType.allCases[$0] }),
                identifier: "rules.editor.match")
            VStack(alignment: .leading, spacing: 6) {
                MenuField(
                    title: "Category", options: categories,
                    selection: Binding(
                        get: { categories.firstIndex { DartString.equal($0, selectedCategory) } ?? 0 },
                        set: { if categories.indices.contains($0) { category = categories[$0] } }),
                    identifier: "rules.editor.category")
                if type == nil, let note = anyTypeNote(selectedCategory) {
                    Text(note)
                        .textStyle(.caption)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.spacingXS)
                        .accessibilityIdentifier("rules.editor.anyTypeNote")
                }
            }
            if !model.tags.isEmpty {
                tagChips
            }
            BudgieField(
                title: "Minimum amount", text: $minimumText, prompt: "Optional", symbol: symbol, keyboard: .decimalPad,
                error: minimumError)
                .accessibilityIdentifier("rules.editor.minimum")
            BudgieField(
                title: "Maximum amount", text: $maximumText, prompt: "Optional", symbol: symbol, keyboard: .decimalPad,
                error: maximumError)
                .accessibilityIdentifier("rules.editor.maximum")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tags as the transaction form's chips (REDESIGN_PLAN 4.1: 34pt
    /// capsules; selected: accent at 13% with accent 13 w700 text and a
    /// check; else a 1pt card border with secondary 13 w600 text), under a
    /// "Tags" caption.
    private var tagChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .textStyle(.captionStrong)
                .foregroundStyle(BudgieColor.textSecondary)
                .padding(.leading, Metrics.spacingXS)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: Metrics.spacingS) {
                // By position: foreign data can repeat a tag id.
                ForEach(Array(model.tags.enumerated()), id: \.offset) { _, tag in
                    let selected = tagIds.contains { DartString.equal($0, tag.id) }
                    Button {
                        if selected { tagIds.removeAll { DartString.equal($0, tag.id) } } else { tagIds.append(tag.id) }
                    } label: {
                        HStack(spacing: 6) {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                            Text(tag.name)
                                .textStyle(selected ? Self.chipSelectedText : Self.chipText)
                                .singleLine()
                        }
                        .foregroundStyle(selected ? BudgieColor.accent : BudgieColor.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(selected ? BudgieColor.accent.opacity(0.13) : Color.clear, in: Capsule())
                        .overlay { if !selected { Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin) } }
                        // The chip draws 34pt tall; the tap area is 44.
                        .tapArea(vertical: 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tag.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("rules.editor.tag.\(tag.id)")
                }
            }
        }
    }

    /// The picker's names for `type` (nil: Any type), plus the edited
    /// rule's own category under its own type when the list lacks it.
    private func categoryNames(for type: TransactionType?) -> [String] {
        var names = type.map { model.categories(for: $0).map(\.name) }
            ?? Self.anyTypeCategories(
                expense: model.categories(for: .expense).map(\.name), income: model.categories(for: .income).map(\.name))
        if let rule, rule.transactionType == type, !names.contains(where: { DartString.equal($0, rule.category) }) {
            names.append(rule.category)
        }
        return names
    }

    /// Under Any type, when only one type has the category: the other
    /// type's form will not take this rule's suggestion.
    private func anyTypeNote(_ name: String) -> String? {
        Self.anyTypeNote(
            name, expense: model.categories(for: .expense).map(\.name), income: model.categories(for: .income).map(\.name))
    }

    private func submit(category: String) {
        guard !busy, !DartString.trim(pattern).isEmpty else { return }
        error = nil
        let minimum = Self.bound(minimumText, prefill: minimumPrefill, stored: rule?.minimumAmount, formatter: formatter)
        let maximum = Self.bound(maximumText, prefill: maximumPrefill, stored: rule?.maximumAmount, formatter: formatter)
        minimumError = minimum == nil ? Self.amountError : nil
        maximumError = maximum == nil ? Self.amountError : nil
        if let low = minimum ?? nil, let high = maximum ?? nil, low > high {
            maximumError = CategorizationEditError.ruleMinimumAboveMaximum.message
        }
        if let message = minimumError ?? maximumError {
            AccessibilityNotification.Announcement(message).post()
            return
        }
        guard let minimum, let maximum else { return }
        busy = true
        let draft = RuleDraft(
            merchantPattern: pattern, matchType: matchType, transactionType: type, minimumAmount: minimum,
            maximumAmount: maximum, category: category, tagIds: tagIds, priority: rule?.priority ?? 0,
            isEnabled: rule?.isEnabled ?? true)
        Task {
            let outcome = if let rule { await model.updateRule(id: rule.id, draft) } else { await model.addRule(draft) }
            busy = false
            outcome.handle(on: model, message: { $0.message }, close: onClose) {
                error = $0
                AccessibilityNotification.Announcement($0).post()
            }
        }
    }

    /// The inline error for a bound that is not an amount of 0 or more.
    static let amountError = "Enter an amount of 0 or more"

    /// A bound field: `.some(nil)` when empty (no bound), the stored value
    /// while the text is its prefill, else the parse (`AmountInput`: 0 or
    /// more, finite, the format's separators); nil when it does not parse.
    static func bound(_ text: String, prefill: String, stored: Double?, formatter: MoneyFormatter) -> Double?? {
        if let stored, text == prefill { return .some(stored) }
        if text.allSatisfy(\.isWhitespace) { return .some(nil) }
        return AmountInput.parse(text, formatter: formatter).map { .some($0) }
    }

    /// An edit's bound prefill: rounded to cents, locale-grouped
    /// (`formatNumber`, not masked by Hide balances, like the goal form).
    static func prefill(_ bound: Double?, formatter: MoneyFormatter) -> String {
        bound.map { formatter.formatNumber($0, decimalDigits: 2) } ?? ""
    }

    /// The Any-type list: the expense names in order, then the income
    /// names the expense list lacks (UTF-16 equality), in order.
    static func anyTypeCategories(expense: [String], income: [String]) -> [String] {
        var names = expense
        for name in income where !names.contains(where: { DartString.equal($0, name) }) { names.append(name) }
        return names
    }

    /// The Any-type caption for `name`: nil when both types have it (or
    /// neither does).
    static func anyTypeNote(_ name: String, expense: [String], income: [String]) -> String? {
        let inExpense = expense.contains { DartString.equal($0, name) }
        let inIncome = income.contains { DartString.equal($0, name) }
        if inExpense && !inIncome { return "Only expenses have \(name), so income won't be categorized by this rule." }
        if inIncome && !inExpense { return "Only income has \(name), so expenses won't be categorized by this rule." }
        return nil
    }

    /// The picked category while the type's list has it (UTF-16 equality,
    /// so "Gift" survives a type switch), else the list's first (Flutter's
    /// `if (!categories.containsKey(category)) category = keys.first`).
    static func resolvedCategory(_ picked: String?, in names: [String]) -> String {
        if let picked, names.contains(where: { DartString.equal($0, picked) }) { return picked }
        return names.first ?? ""
    }

    /// The category after a type change: the one shown under the old type
    /// (the picked one, or its first when none was picked: Flutter's
    /// variable starts at the first expense category), kept when the new
    /// type has it, else the new type's first.
    static func categoryAfterTypeChange(_ picked: String?, from old: [String], to new: [String]) -> String {
        resolvedCategory(resolvedCategory(picked, in: old), in: new)
    }

    /// Ends editing wherever the keyboard is (the field's focus is its own).
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    static func typeLabel(_ type: TransactionType?) -> String {
        switch type {
        case .income?: "Income"
        case .expense?: "Expense"
        case nil: "Any type"
        }
    }

    static func matchLabel(_ match: MerchantMatchType) -> String {
        switch match {
        case .contains: "Contains"
        case .startsWith: "Starts with"
        case .exact: "Exact match"
        }
    }
}

/// Fades the bottom edge of the dialog's scroll area while more fields are
/// below it (the keyboard is up), so the cut reads as scrollable. iOS 18
/// and later; iOS 17 keeps the indicator flash only.
private struct MoreBelowFade: ViewModifier {
    @State private var moreBelow = false

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 1
                } action: { _, more in
                    moreBelow = more
                }
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                    }
                }
        } else {
            content
        }
    }
}

/// A dropdown in the redesign's field style (Material
/// `DropdownButtonFormField`, REDESIGN_PLAN 4.1): the caption w600 above,
/// the field box (`fieldFill`, radius 16, 1pt card border, 52 tall) with
/// the value in rowTitle and an
/// up-down chevron (footnote-sized, so it scales with Dynamic Type). A tap
/// opens a popover list anchored to the box, a check on the current
/// option. With the keyboard up the tap first dismisses it and opens the
/// list once it is gone and the dialog has settled (Flutter's dropdown
/// closes the keyboard first; a system `Menu` cannot wait, so it opened
/// cut by the keyboard or detached from its moved field). Options are
/// picked by index (names are compared as UTF-16 elsewhere, and
/// equal-looking names stay separate rows). VoiceOver reads the title
/// with the value.
private struct MenuField: View {
    let title: String
    let options: [String]
    @Binding var selection: Int
    let identifier: String

    @State private var open = false
    @State private var keyboardUp = false
    /// Tapped with the keyboard up: opens when it has gone.
    @State private var opening = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 48

    var body: some View {
        let value = options.indices.contains(selection) ? options[selection] : ""
        let shape = RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textStyle(.captionStrong)
                .foregroundStyle(BudgieColor.textSecondary)
                .padding(.leading, Metrics.spacingXS)
                .accessibilityHidden(true)
            Button(action: tap) {
                HStack(spacing: 10) {
                    Text(value)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(BudgieColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(BudgieColor.fieldFill, in: shape)
                .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, attachmentAnchor: .rect(.bounds)) {
                optionList
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardUp = false
            if opening {
                opening = false
                open = true
            }
        }
    }

    private func tap() {
        if keyboardUp {
            opening = true
            RuleEditorDialog.dismissKeyboard()
        } else {
            open = true
        }
    }

    /// The options, scrolled to the current one, as tall as they need up to
    /// about nine rows.
    private var optionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { index in
                        let current = index == selection
                        Button {
                            selection = index
                            open = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(BudgieColor.accent)
                                    .opacity(current ? 1 : 0)
                                    .accessibilityHidden(true)
                                Text(options[index])
                                    .textStyle(.rowTitle)
                                    .foregroundStyle(BudgieColor.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, Metrics.spacingM)
                            .frame(minHeight: rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealWidth: 260, idealHeight: min(CGFloat(options.count), 9.5) * rowHeight + 12)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}
