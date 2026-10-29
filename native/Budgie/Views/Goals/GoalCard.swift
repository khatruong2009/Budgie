import BudgieCore
import SwiftUI

/// One goal (`_SavingsGoalCard`, savings_goals_page.dart:691-892): the name
/// and status pill, "{saved} of {target}" (or "{saved} saved") with the
/// percent, a 10pt bar in the status colour, the pace or "Fully funded"
/// line, then Add money and the ellipsis (only the ellipsis, right-aligned,
/// once complete). A completed card is tinted green and long-presses to its
/// actions, as in Flutter; a tap does nothing.
///
/// VoiceOver reads the texts and bar as one element with Add money, Edit
/// goal and Delete goal actions; the two buttons stay separate elements.
struct GoalCard: View {
    let goal: SavingsGoalRecord
    let now: DartDateTime
    let calendar: DartCalendar
    let formatter: MoneyFormatter
    let onAddMoney: () -> Void
    let onMore: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var longPresses = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var titleLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    /// The saved amount.
    private static let amountText = TextSpec(face: .monoSemiBold, size: 22, tracking: -0.4, height: 1.2, tabular: true, relativeTo: .title2)
    /// " of {target}", " saved".
    private static let amountTail = TextSpec(face: .monoRegular, size: 13, height: 1.2, tabular: true, relativeTo: .footnote)
    private static let percentText = TextSpec(face: .gabaritoBold, size: 14, height: 1.25, tabular: true, relativeTo: .subheadline)

    var body: some View {
        let status = goal.status(now: now, calendar: calendar)
        let complete = status == .complete
        let color = Self.color(status)
        GlowCard(
            fill: complete
                ? AnyShapeStyle(
                    LinearGradient(
                        colors: [BudgieColor.income.opacity(0.10), BudgieColor.income.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                : nil,
            border: complete ? BudgieColor.income.opacity(0.30) : nil
        ) {
            VStack(spacing: 16) {
                summary(status: status, color: color)
                HStack(spacing: 8) {
                    if complete {
                        Spacer(minLength: 0)
                    } else {
                        PillButton(title: "Add money", symbol: "plus", filled: true, height: 44, action: onAddMoney)
                            .accessibilityIdentifier("goals.card.addMoney")
                    }
                    GoalMoreButton(action: onMore)
                }
            }
        }
        // GlowCard's own long press would merge the buttons into the card's
        // accessibility element; this keeps them reachable.
        .gesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                longPresses += 1
                onMore()
            },
            including: complete ? .all : .subviews)
        .sensoryFeedback(.impact(weight: .medium), trigger: longPresses)
        .accessibilityElement(children: .contain)
    }

    private func summary(status: SavingsGoalStatus, color: Color) -> some View {
        let complete = status == .complete
        let saved = formatter.format(goal.currentAmount, decimalDigits: 0)
        let tail = complete ? " saved" : " of \(formatter.format(goal.targetAmount, decimalDigits: 0))"
        let note = complete ? SavingsGoalText.fullyFunded(goal) : SavingsGoalText.pace(goal, now: now, calendar: calendar, formatter: formatter)
        return VStack(alignment: .leading, spacing: 0) {
            // At accessibility sizes the chip sits under the name, which
            // then has the column's full width (beside the fixed-size chip
            // it broke mid-word).
            titleLayout {
                Text(goal.name)
                    .textStyle(.goalTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .singleLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                PillChip(label: status.label, color: color, style: .badgeSmall)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(saved).font(Self.amountText.font()).foregroundStyle(BudgieColor.textPrimary)
                    + Text(tail).font(Self.amountTail.font()).foregroundStyle(BudgieColor.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BudgieColor.income)
                } else {
                    Text(SavingsGoalText.percent(goal))
                        .textStyle(Self.percentText)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .fixedSize()
                }
            }
            .padding(.top, 14)
            GlowProgressBar(value: complete ? 1 : goal.progress, height: 10, color: color)
                .padding(.top, 10)
            Text(note)
                .textStyle(.rowSubtitle)
                .foregroundStyle(complete ? BudgieColor.income : BudgieColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.name), \(status.label)")
        .accessibilityValue(
            "\(goal.progressPercent) percent, \(saved)\(tail), "
                + note.replacingOccurrences(of: " \u{00B7} ", with: ", "))
        .accessibilityIdentifier("goals.card")
        .modifier(OptionalAccessibilityAction(name: "Add money", action: complete ? nil : onAddMoney))
        .accessibilityAction(named: "Edit goal", onEdit)
        .accessibilityAction(named: "Delete goal", onDelete)
    }

    /// The status colour: success, warning or accent.
    static func color(_ status: SavingsGoalStatus) -> Color {
        switch status {
        case .complete: BudgieColor.income
        case .behind: BudgieColor.warning
        case .onTrack: BudgieColor.accent
        }
    }
}

/// `_MoreButton` (savings_goals_page.dart:919-959): a 44pt outlined circle
/// with an ellipsis, light haptic, "More goal actions".
struct GoalMoreButton: View {
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            // Material `more_horiz_rounded` 18 / w500: 11.5pt wide, 3pt
            // dots; SF `ellipsis` medium at 12 is 12 x 3.
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .foregroundStyle(BudgieColor.textSecondary)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(BudgieColor.pillBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More goal actions")
        .accessibilityIdentifier("goals.card.more")
    }
}
