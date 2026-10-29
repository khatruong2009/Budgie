import BudgieCore
import SwiftUI

/// Add money (`_AllocationDialog`, savings_goals_page.dart:1219-1400): the
/// goal's name, the autofocused "Allocation amount" field, quick chips that
/// replace the field's text ($25.00, $100.00 and, while something remains,
/// "Finish goal"), then Cancel and Add money. The amount must be above 0;
/// there is no upper limit (over-funding is allowed).
///
/// "Finish goal" fills the remainder rounded to cents, as Flutter, but while
/// the field still reads that text `finishAmount` is saved (the remainder,
/// nudged up where `current + remainder` rounds below the target), so the
/// goal always completes (Flutter can fall a fraction of a cent short).
struct AllocationDialog: View {
    let goal: SavingsGoalRecord
    let formatter: MoneyFormatter
    let busy: Bool
    let onCancel: () -> Void
    let onSubmit: (Double) -> Void

    @State private var text = ""
    @State private var error: String?
    @State private var chipTaps = 0

    /// `rowSubtitle` at 13 / w600 (the chips).
    private static let chipText = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.25, relativeTo: .footnote)

    var body: some View {
        VStack(spacing: 0) {
            Text("Add money")
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Text(goal.name)
                .textStyle(GoalText.caption)
                .foregroundStyle(BudgieColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            DialogScroll {
                VStack(alignment: .leading, spacing: 12) {
                    BudgieField(
                        title: "Allocation amount", text: $text, prompt: "0.00",
                        symbol: AmountInput.currencySymbolName(formatter), keyboard: .decimalPad,
                        error: error, autofocus: true)
                    FlowLayout(spacing: Metrics.spacingS) {
                        chip(formatter.format(25), spoken: "Fill amount \(formatter.format(25))", fill: 25, identifier: "goals.allocate.chip.25")
                        chip(formatter.format(100), spoken: "Fill amount \(formatter.format(100))", fill: 100, identifier: "goals.allocate.chip.100")
                        if goal.remainingAmount > 0 {
                            chip("Finish goal", spoken: "Finish goal", fill: goal.finishAmount, identifier: "goals.allocate.chip.finish")
                        }
                    }
                }
            }
            .padding(.top, 20)
            HStack(spacing: 12) {
                PillButton(title: "Cancel", color: BudgieColor.textPrimary, height: 44, action: onCancel)
                    .accessibilityIdentifier("goals.allocate.cancel")
                PillButton(title: "Add money", symbol: "plus", filled: true, height: 44, action: submit)
                    .accessibilityIdentifier("goals.allocate.submit")
            }
            .padding(.top, Metrics.spacingL)
        }
        .disabled(busy)
        .sensoryFeedback(.selection, trigger: chipTaps)
    }

    /// A quick amount: fills `fill` to cents, replacing the text.
    private func chip(_ label: String, spoken: String, fill: Double, identifier: String) -> some View {
        Button {
            chipTaps += 1
            text = formatter.formatNumber(fill, decimalDigits: 2)
        } label: {
            Text(label)
                .textStyle(Self.chipText)
                .foregroundStyle(BudgieColor.textPrimary)
                .padding(.horizontal, 14 + Metrics.borderThin)
                .padding(.vertical, 9 + Metrics.borderThin)
                .background(BudgieColor.chipSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
                // The chip draws 36pt tall; the tap area is 44.
                .tapArea(vertical: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint("Fills the allocation amount")
        .accessibilityIdentifier(identifier)
    }

    /// `finishAmount` while the field reads the Finish goal text, else the
    /// parsed amount; nil unless above 0.
    private var amount: Double? {
        let finish = goal.finishAmount
        if finish > 0, text == formatter.formatNumber(finish, decimalDigits: 2) { return finish }
        return AmountInput.parse(text, formatter: formatter).flatMap { $0 > 0 ? $0 : nil }
    }

    private func submit() {
        guard !busy else { return }
        guard let amount else {
            error = "Enter an amount greater than 0"
            AccessibilityNotification.Announcement("Enter an amount greater than 0").post()
            return
        }
        error = nil
        onSubmit(amount)
    }
}
