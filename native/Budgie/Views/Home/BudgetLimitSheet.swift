import BudgieCore
import SwiftUI

/// Sets or removes a category's monthly limit (`_BudgetLimitSheet`,
/// spending_page.dart:811-999) in the redesign's sheet pattern (REDESIGN_PLAN
/// 4.3): the category as the title with its tile, the limit field
/// (autofocused, decimal pad), then a full-width Save pill and, with a limit
/// set, an outlined Remove pill. Content-sized; it rides up with the keyboard.
struct BudgetLimitSheet: View {
    let category: String
    let currentLimit: Double?
    let formatter: MoneyFormatter

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    /// What the field opened with; while it still reads this, the stored
    /// limit is used exactly (the prefill is rounded to cents).
    private let prefill: String
    @State private var saving = false
    @State private var contentHeight: CGFloat = 0
    /// The space below the handle with nothing trimmed (the measured height
    /// plus the slack it was measured with).
    @State private var untrimmedHeight: CGFloat = 0
    @State private var keyboardSlack: CGFloat = 0

    private static let helper = "Set a positive amount for this category."
    private static let blurb = TextSpec(face: .gabaritoRegular, size: 14, height: 1.3, relativeTo: .subheadline)

    init(category: String, currentLimit: Double?, formatter: MoneyFormatter) {
        self.category = category
        self.currentLimit = currentLimit
        self.formatter = formatter
        // `formatNumber(limit, 2)`, locale-grouped; not masked by Hide balances.
        let prefill = currentLimit.map { formatter.formatNumber($0, decimalDigits: 2) } ?? ""
        self.prefill = prefill
        _text = State(initialValue: prefill)
    }

    /// The limit Save writes: the stored one while the field is untouched,
    /// else the parsed text.
    private var limit: Double? {
        Self.limit(text: text, prefill: prefill, currentLimit: currentLimit, formatter: formatter)
    }

    var body: some View {
        // The space the sheet gives the content. A frame around the
        // fixed-size content could not report less than the content's own
        // height, so a sheet that had shrunk below it (after a fold with
        // the keyboard up) was read as having room and the slack only grew.
        Color.clear
            .onGeometryChangeCompat {
                untrimmedHeight = $0.height + keyboardSlack
                updateKeyboardSlack()
            }
            .overlay(alignment: .top) { content }
            .budgieSheetChrome()
            .presentationDetents([
                .height(
                    BudgetSheetLayout.handleHeight + (contentHeight > 0 ? contentHeight : estimatedHeight) - keyboardSlack)
            ])
            .interactiveDismissDisabled(saving)
    }

    private var content: some View {
        let canSave = !saving && limit != nil
        return VStack(alignment: .leading, spacing: 0) {
            header
            field.padding(.top, 24)
            VStack(spacing: 12) {
                PillButton(title: "Save", filled: true, height: Metrics.pillButtonHeight, loading: saving, action: save)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : Metrics.opacityDisabled)
                    .accessibilityIdentifier("budgets.limit.save")
                if currentLimit != nil {
                    PillButton(
                        title: "Remove", symbol: "trash", color: BudgieColor.danger, height: Metrics.pillButtonHeight,
                        action: remove
                    )
                    .disabled(saving)
                    .opacity(saving ? Metrics.opacityDisabled : 1)
                    .accessibilityIdentifier("budgets.limit.remove")
                }
            }
            .padding(.top, 24)
        }
        // 12 + the chrome's 19pt handle inset.
        .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 16, trailing: Metrics.pageHorizontal))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChangeCompat {
            contentHeight = $0.height
            updateKeyboardSlack()
        }
    }

    /// The content's height at the default text size, so the sheet opens at
    /// its final height instead of resizing once measured: 12, the header
    /// (the 40pt tile), 24, the 64pt field, 6, the helper, 24, the 52pt Save
    /// pill (and 12 and the Remove pill), 16.
    private var estimatedHeight: CGFloat {
        12 + 52 + 24 + 64 + 6 + 15 + 24 + 52 + (currentLimit != nil ? 12 + 52 : 0) + 16
    }

    /// The room left below the content, trimmed off the detent. With the
    /// keyboard up the system keeps the sheet's home-indicator allowance
    /// above the keyboard as empty space; trimming it leaves the content's
    /// own 16pt bottom padding as the gap, as in Flutter. Without the
    /// keyboard the content already reaches into that allowance, so nothing
    /// is trimmed.
    private func updateKeyboardSlack() {
        guard contentHeight > 0, untrimmedHeight > 0 else { return }
        let slack = max(0, untrimmedHeight - contentHeight)
        if abs(slack - keyboardSlack) >= 0.5 { keyboardSlack = slack }
    }

    /// The category's tile, its name as the sheet title and the kind of limit
    /// as the blurb.
    private var header: some View {
        HStack(spacing: 14) {
            IconTile(category: model.categoryInfo(named: category, type: .expense), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(category)
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Monthly spending limit")
                    .textStyle(Self.blurb)
                    .foregroundStyle(BudgieColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The amount field (`BudgieField` `.amount`): "Limit" inside the box,
    /// the currency prefix, "0.00" hint, autofocused with the decimal pad;
    /// the helper text below. Only a hardware keyboard can submit; the
    /// decimal pad has no return key.
    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            BudgieField(
                title: "Limit", text: $text, prompt: "0.00", keyboard: .decimalPad, autofocus: true, style: .amount,
                prefix: AmountInput.currencySymbol(formatter), identifier: "budgets.limit.field"
            )
            .onSubmit(save)
            Text(Self.helper)
                .textStyle(.rowSubtitle)
                .foregroundStyle(BudgieColor.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    /// `_saveLimit`: re-checks the guard (the submit path), spins, awaits the
    /// verified write, then closes.
    private func save() {
        guard !saving, let limit else { return }
        saving = true
        Task {
            // A failed write still closes the sheet, as in Flutter: the change
            // stays in memory and the unsaved-changes banner offers the retry.
            _ = await model.setBudgetLimit(category: category, limit: limit)
            dismiss()
        }
    }

    /// `_removeLimit`: also sets `saving`, so Save spins and Remove disables.
    private func remove() {
        guard !saving else { return }
        saving = true
        Task {
            _ = await model.removeBudgetLimit(category: category)
            dismiss()
        }
    }

    // MARK: - Parsing (D6)

    /// An unchanged prefill keeps `currentLimit` exactly (99.999 stays
    /// 99.999, not the 100.0 its "100.00" parses to; 0.001 stays saveable);
    /// any edit parses (`AmountInput`, D6) and must be above 0. Flutter
    /// always parses the text.
    nonisolated static func limit(text: String, prefill: String, currentLimit: Double?, formatter: MoneyFormatter) -> Double? {
        if let currentLimit, text == prefill { return currentLimit }
        return AmountInput.parse(text, formatter: formatter).flatMap { $0 > 0 ? $0 : nil }
    }
}
