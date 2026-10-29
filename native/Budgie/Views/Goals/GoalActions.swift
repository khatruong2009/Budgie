import BudgieCore
import SwiftUI

/// The ellipsis sheet's content (`_showGoalActions`,
/// savings_goals_page.dart:371-428) in the sheet pattern (REDESIGN_PLAN
/// 4.3): the goal's name as the title, then "Edit goal" and "Delete goal"
/// as list rows with a hairline between them, shown by the page's
/// `budgieDialog` at the bottom placement (one floating card 20pt from the
/// edges, over the scrim, as Flutter's transparent modal sheet). A row
/// fires a light haptic; the page then swaps the sheet for that dialog.
struct GoalActionsSheet: View {
    let goal: SavingsGoalRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(goal.name)
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .singleLine()
                .accessibilityAddTraits(.isHeader)
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
            GoalActionTile(title: "Edit goal", symbol: "pencil", color: BudgieColor.textPrimary, action: onEdit)
                .accessibilityIdentifier("goals.actions.edit")
            Hairline().padding(.horizontal, Metrics.hairlineInset)
            GoalActionTile(title: "Delete goal", symbol: "trash", color: BudgieColor.danger, action: onDelete)
                .accessibilityIdentifier("goals.actions.delete")
        }
        .padding(Metrics.spacingS)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goals.actions")
    }
}

/// `_GoalActionTile` (savings_goals_page.dart:962-1001): 40pt tile tinted
/// like the label, 14pt gap, rowTitle, at least 48pt tall; the whole row
/// taps.
private struct GoalActionTile: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, color: color)
                Text(title)
                    .textStyle(.rowTitle)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

/// Delete confirmation (`_confirmDelete`, savings_goals_page.dart:431-497).
struct DeleteGoalDialog: View {
    let goal: SavingsGoalRecord
    let busy: Bool
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DialogTitle(text: "Delete savings goal?")
            DialogScroll {
                Text("This removes \"\(goal.name)\" and its saved progress from your goals.")
                    .textStyle(GoalText.body)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            DialogButtons(
                cancelId: "goals.delete.cancel", submitTitle: "Delete", submitId: "goals.delete.confirm",
                color: BudgieColor.danger, cancel: onCancel, submit: onDelete)
                .disabled(busy)
        }
    }
}
