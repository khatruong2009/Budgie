import BudgieCore
import SwiftUI

/// The Goals tab (`SavingsGoalsPage`, savings_goals_page.dart): header, the
/// empty state or the summary card and one card per goal (incomplete first,
/// then by target date), the add button, the actions sheet, the add / edit,
/// Add money and delete dialogs, and the completion celebration.
///
/// Every mutation is awaited while its dialog stays open (the scrim and the
/// buttons do nothing meanwhile), then the dialog closes and a toast
/// reports the result: Flutter's success copy, or the save-failed toast
/// when the write did not reach the disk. An Add money that completes the
/// goal (judged on the goal as shown before the dialog, as Flutter) then
/// plays the medium haptic and, unless Reduce Motion is on, the overlay.
struct GoalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The actions sheet or dialog showing; the actions sheet hands over
    /// to its Edit / Delete dialog in the same presentation.
    @State private var dialog: PresentedDialog?
    /// A mutation is in flight (Flutter `_isBusy`).
    @State private var busy = false
    @State private var celebration: Celebration?
    @State private var completions = 0

    var body: some View {
        // Status and pace read the clock; returning to the app re-reads it.
        let _ = scenePhase
        let goals = model.savingsGoals
        ScrollView {
            VStack(spacing: 0) {
                BudgieHeader(title: "Goals")
                if goals.isEmpty {
                    emptyState
                        .padding(EdgeInsets(top: 48, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
                } else {
                    content(goals)
                }
            }
        }
        .background(BudgieColor.background)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if let celebration {
                CelebrationOverlay(name: celebration.name, start: celebration.start)
                    .task(id: celebration.id) {
                        // Also ends it when the tab goes away mid-flight.
                        try? await Task.sleep(for: .seconds(CelebrationOverlay.duration))
                        if self.celebration?.id == celebration.id { self.celebration = nil }
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlowFab(label: "Add savings goal") { present(.add) }
                .padding(.trailing, Metrics.fabInset)
                .padding(.bottom, Metrics.fabInset)
                .accessibilityIdentifier("goals.fab")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: completions)
        // `busy` is read here, in the body: the dialog is built outside it
        // and would otherwise see the value from before the save started.
        .budgieDialog(item: $dialog, padding: isActions ? 0 : Metrics.cardPadding, placement: isActions ? .bottom : .center) {
            [busy] presented in
            dialogContent(presented, busy: busy)
                // The scrim (and its VoiceOver Dismiss) is inert while saving.
                .budgieDialogDismissDisabled(busy)
        }
    }

    // MARK: - Sections

    /// `_buildEmptyState` (savings_goals_page.dart:164-211).
    private var emptyState: some View {
        // No piggy bank in SF Symbols (D3).
        EmptyStateView(
            symbol: "banknote",
            title: "No savings goals yet",
            message: "Create a goal, set a target date, and track progress as you set money aside.",
            actionTitle: "Add goal", actionIdentifier: "goals.empty.add",
            horizontalInset: 0
        ) { present(.add) }
        .disabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goals.empty")
    }

    @ViewBuilder
    private func content(_ goals: [SavingsGoalRecord]) -> some View {
        let formatter = model.moneyFormatter
        let now = model.now
        VStack(spacing: 0) {
            GoalsSummaryCard(summary: model.savingsGoalsSummary, formatter: formatter)
                .padding(.top, Metrics.spacingL)
            // Keyed by id (Flutter's cards are unkeyed, so a re-sort moved
            // ring state between goals); a repeated id gets its occurrence.
            ForEach(goals.uniqueKeys(id: \.id), id: \.key) { item in
                let goal = item.element
                GoalCard(
                    goal: goal, now: now, calendar: model.calendar, formatter: formatter,
                    onAddMoney: { present(.allocate(goal)) },
                    onMore: { present(.actions(goal)) },
                    onEdit: { present(.edit(goal)) },
                    onDelete: { present(.delete(goal)) }
                )
                .padding(.top, Metrics.spacingM)
            }
        }
        .padding(.horizontal, Metrics.pageHorizontal)
    }

    // MARK: - Dialogs

    @ViewBuilder
    private func dialogContent(_ dialog: PresentedDialog, busy: Bool) -> some View {
        let formatter = model.moneyFormatter
        switch dialog.kind {
        case .actions(let goal):
            GoalActionsSheet(goal: goal) { present(.edit(goal)) } onDelete: { present(.delete(goal)) }
        case .add:
            GoalFormDialog(goal: nil, formatter: formatter, busy: busy, openedAt: dialog.openedAt, onCancel: closeDialog) {
                submitForm($0, editing: nil)
            }
        case .edit(let goal):
            GoalFormDialog(goal: goal, formatter: formatter, busy: busy, openedAt: dialog.openedAt, onCancel: closeDialog) {
                submitForm($0, editing: goal)
            }
        case .allocate(let goal):
            AllocationDialog(goal: goal, formatter: formatter, busy: busy, onCancel: closeDialog) { allocate($0, to: goal) }
        case .delete(let goal):
            DeleteGoalDialog(goal: goal, busy: busy, onCancel: closeDialog) { delete(goal) }
        }
    }

    private var isActions: Bool {
        if case .actions? = dialog?.kind { return true }
        return false
    }

    private func present(_ kind: GoalDialog) {
        guard !busy else { return }
        dialog = PresentedDialog(kind: kind, openedAt: model.now)
    }

    private func closeDialog() {
        guard !busy else { return }
        dialog = nil
    }

    // MARK: - Mutations

    private func submitForm(_ form: GoalFormDialog.Submission, editing goal: SavingsGoalRecord?) {
        run(success: goal == nil ? .goalAdded : .goalUpdated) {
            if let goal {
                return await model.updateSavingsGoal(
                    id: goal.id,
                    SavingsGoalRecord.Edit(
                        name: form.name, targetAmount: form.targetAmount, currentAmount: form.currentAmount,
                        targetDate: form.targetDate))
            }
            return await model.addSavingsGoal(name: form.name, targetAmount: form.targetAmount, targetDate: form.targetDate)
        }
    }

    /// `_showAllocationForm` (savings_goals_page.dart:331-368).
    private func allocate(_ amount: Double, to goal: SavingsGoalRecord) {
        let willComplete = goal.willComplete(allocating: amount)
        run(success: .allocationAdded) {
            await model.allocateToSavingsGoal(id: goal.id, amount: amount)
        } then: { saved in
            guard saved, willComplete else { return }
            completions += 1
            // Queued behind the toast's announcement.
            UIAccessibility.post(
                notification: .announcement,
                argument: NSAttributedString(
                    string: "Goal complete, \(goal.name)", attributes: [.accessibilitySpeechQueueAnnouncement: true]))
            if !reduceMotion { celebration = Celebration(name: goal.name) }
        }
    }

    private func delete(_ goal: SavingsGoalRecord) {
        run(success: .goalDeleted) { await model.deleteSavingsGoal(id: goal.id) }
    }

    /// Runs one mutation with the dialog held open, then closes it and
    /// toasts: `success` when saved, the save-failed toast when this write
    /// failed (the change is only in memory), nothing when the model refused
    /// the change without writing (e.g. the goal is gone), whatever else is
    /// still unsaved.
    private func run(
        success: Toast, _ mutation: @escaping () async -> AppModel.SaveOutcome, then: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await mutation()
            busy = false
            dialog = nil
            switch outcome {
            case .saved: model.showToast(success)
            case .failed: model.showToast(.saveFailed)
            case .rejected: break
            }
            then(outcome == .saved)
        }
    }
}

/// The actions sheet or a centred dialog of the Goals tab.
enum GoalDialog: Hashable {
    case actions(SavingsGoalRecord)
    case add
    case edit(SavingsGoalRecord)
    case allocate(SavingsGoalRecord)
    case delete(SavingsGoalRecord)
}

/// One presentation of a dialog (fresh field state each time).
private struct PresentedDialog: Identifiable {
    let id = UUID()
    let kind: GoalDialog
    /// The clock when it opened (the add form's default date).
    let openedAt: DartDateTime
}

private struct Celebration: Identifiable {
    let id = UUID()
    let name: String
    let start = Date()
}

/// Text styles of the Goals tab that Flutter derives from the named ones
/// with a size or weight override.
enum GoalText {
    /// `rowSubtitle` at 13, height 1.45 (empty state, delete body).
    static let body = TextSpec(face: .gabaritoRegular, size: 13, height: 1.45, relativeTo: .footnote)
    /// `rowSubtitle` at 13 (summary caption, dialog subtitles).
    static let caption = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)
}

// MARK: - Summary

/// `_SavingsGoalsSummary` (savings_goals_page.dart:608-687), the page's
/// feature card: the 72pt ring with the overall percent, SAVED SO FAR, the
/// saved total and "of {target} · {n} of {count} complete".
struct GoalsSummaryCard: View {
    let summary: SavingsGoalsSummary
    let formatter: MoneyFormatter

    /// `badgeSmall` at 14 / w800.
    private static let ringText = TextSpec(face: .gabaritoExtraBold, size: 14, relativeTo: .caption)
    /// `heroSmall` at 28, tracking -0.8.
    private static let amountText = TextSpec(
        face: .gabaritoExtraBold, size: 28, tracking: -0.8, height: 1.1, tabular: true, relativeTo: .title)

    var body: some View {
        let saved = formatter.format(summary.totalSaved, decimalDigits: 0)
        HStack(spacing: 18) {
            ProgressRing(
                value: summary.progress, size: 72, thickness: 8, color: BudgieColor.featureRing,
                track: BudgieColor.featureControl, inner: BudgieColor.featureFill
            ) {
                Text(SavingsGoalText.summaryPercent(summary))
                    .textStyle(Self.ringText)
                    .foregroundStyle(BudgieColor.featureText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("SAVED SO FAR")
                    .textStyle(.eyebrowTight)
                    .foregroundStyle(BudgieColor.featureSecondary)
                Text(saved)
                    .textStyle(Self.amountText)
                    .foregroundStyle(BudgieColor.featureAmount)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 6)
                Text(SavingsGoalText.summaryCaption(summary, formatter: formatter))
                    .textStyle(GoalText.caption)
                    .foregroundStyle(BudgieColor.featureSecondary)
                    .padding(.top, Metrics.spacingXXS)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // GlowCard's inset: padding 20 plus the 1pt border.
        .featureCard(padding: Metrics.cardPadding + Metrics.borderThin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved so far")
        .accessibilityValue(
            "\(saved) of \(formatter.format(summary.totalTarget, decimalDigits: 0)), "
                + "\(summary.completedCount) of \(summary.count) complete, \(summary.percent) percent")
        .accessibilityIdentifier("goals.summary")
    }
}
