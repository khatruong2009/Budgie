import BudgieCore
import SwiftUI

/// Add / edit savings goal dialog (`_GoalFormDialog`,
/// savings_goals_page.dart:1026-1216): Goal name, Target amount, Saved so
/// far (edit only) and the target date tile, then Cancel and Add / Update.
/// Validation runs on submit and shows every error at once.
///
/// Amounts parse with the money format's separators (`AmountInput`, D6).
/// An edit prefills both amounts rounded to cents (locale-grouped, like the
/// budget limit sheet), and a field left as prefilled keeps the stored
/// value exactly. The date keeps the stored value (edit) or six months from
/// the day the form opened (add, with Dart's overflow; a form left open
/// across midnight keeps its date) until a day is picked, which is stored
/// as that day's midnight.
struct GoalFormDialog: View {
    struct Submission {
        let name: String
        let targetAmount: Double
        /// The edit's "Saved so far" (0 for a new goal).
        let currentAmount: Double
        let targetDate: DartDateTime
    }

    let goal: SavingsGoalRecord?
    let formatter: MoneyFormatter
    let busy: Bool
    /// The clock when the form opened (Flutter builds the form's state once).
    let openedAt: DartDateTime
    let onCancel: () -> Void
    let onSubmit: (Submission) -> Void

    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var targetText: String
    @State private var savedText: String
    /// The picked day at midnight; nil keeps the stored or default date.
    @State private var pickedDate: DartDateTime?
    @State private var nameError: String?
    @State private var targetError: String?
    @State private var savedError: String?
    @State private var showingDatePicker = false
    @State private var picks = 0
    /// The edit's prefills, which stand for the stored amounts exactly.
    private let targetPrefill: String
    private let savedPrefill: String

    init(
        goal: SavingsGoalRecord?, formatter: MoneyFormatter, busy: Bool, openedAt: DartDateTime,
        onCancel: @escaping () -> Void, onSubmit: @escaping (Submission) -> Void
    ) {
        self.goal = goal
        self.formatter = formatter
        self.busy = busy
        self.openedAt = openedAt
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        // `formatNumber` is not masked by Hide balances; Flutter shows the
        // real amounts here too.
        targetPrefill = goal.map { formatter.formatNumber($0.targetAmount, decimalDigits: 2) } ?? ""
        savedPrefill = goal.map { formatter.formatNumber($0.currentAmount, decimalDigits: 2) } ?? ""
        _name = State(initialValue: goal?.name ?? "")
        _targetText = State(initialValue: targetPrefill)
        _savedText = State(initialValue: savedPrefill)
    }

    var body: some View {
        let amountSymbol = AmountInput.currencySymbolName(formatter)
        VStack(spacing: 0) {
            Text(goal == nil ? "Add savings goal" : "Edit savings goal")
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            DialogScroll { fields(amountSymbol: amountSymbol) }
                .padding(.top, 20)
            HStack(spacing: 12) {
                PillButton(title: "Cancel", color: BudgieColor.textPrimary, height: 44, action: onCancel)
                    .accessibilityIdentifier("goals.form.cancel")
                PillButton(
                    title: goal == nil ? "Add" : "Update", symbol: goal == nil ? "plus" : "checkmark", filled: true, height: 44,
                    action: submit
                )
                .accessibilityIdentifier("goals.form.submit")
            }
            .padding(.top, Metrics.spacingL)
        }
        .disabled(busy)
        .sheet(isPresented: $showingDatePicker) {
            DayPickerSheet(initial: resolvedDate, earliest: range.earliest, latest: range.latest, calendar: model.calendar) {
                pickedDate = $0
                picks += 1
            }
        }
        .sensoryFeedback(.selection, trigger: picks)
    }

    private func fields(amountSymbol: String) -> some View {
        VStack(spacing: 12) {
            BudgieField(
                title: "Goal name", text: $name, prompt: "Vacation, emergency fund, new car", symbol: "flag.fill",
                capitalization: .sentences, error: nameError)
            BudgieField(
                title: "Target amount", text: $targetText, prompt: "0.00", symbol: amountSymbol, keyboard: .decimalPad,
                error: targetError)
            if goal != nil {
                BudgieField(
                    title: "Saved so far", text: $savedText, prompt: "0.00", symbol: "banknote", keyboard: .decimalPad,
                    error: savedError)
            }
            DateTile(label: "Target date", value: DartDateFormat.yMMMd(resolvedDate)) { showingDatePicker = true }
                .accessibilityIdentifier("goals.form.date")
                .padding(.top, Metrics.spacingXS)
        }
    }

    // MARK: - Date

    /// The picked day, else the stored date (edit) or `DateTime(y, m + 6, d)`.
    private var resolvedDate: DartDateTime {
        if let pickedDate { return pickedDate }
        if let goal { return goal.targetDate }
        let n = openedAt.fields
        return model.calendar.date(n.year, n.month + 6, n.day)
    }

    /// Flutter's `firstDate: DateTime(year - 1)`, `lastDate: DateTime(year
    /// + 20)` (both inclusive), stretched to the shown date's day when it is
    /// outside (Flutter asserts on an old goal, D6).
    private var range: (earliest: DartDateTime, latest: DartDateTime) {
        let calendar = model.calendar
        let year = openedAt.year
        let day = calendar.startOfDay(resolvedDate)
        return (min(calendar.date(year - 1, 1, 1), day), max(calendar.date(year + 20, 1, 1), day))
    }

    // MARK: - Submit

    /// `_submit`: all three validators, then the result.
    private func submit() {
        guard !busy else { return }
        let trimmed = DartString.trim(name)
        let target = amount(targetText, prefill: targetPrefill, stored: goal?.targetAmount)
        let saved = amount(savedText, prefill: savedPrefill, stored: goal?.currentAmount)
        nameError = trimmed.isEmpty ? "Name is required" : nil
        targetError = target.map { $0 > 0 && $0.isFinite } == true ? nil : "Enter a target greater than 0"
        savedError = goal == nil || saved.map { $0 >= 0 && $0.isFinite } == true ? nil : "Enter 0 or more"
        if let error = nameError ?? targetError ?? savedError {
            AccessibilityNotification.Announcement(error).post()
            return
        }
        guard let target else { return }
        onSubmit(
            Submission(
                name: trimmed, targetAmount: target, currentAmount: goal == nil ? 0 : saved ?? 0, targetDate: resolvedDate))
    }

    /// The stored amount while the field reads its prefill, else the parse.
    private func amount(_ text: String, prefill: String, stored: Double?) -> Double? {
        if let stored, text == prefill { return stored }
        return AmountInput.parse(text, formatter: formatter)
    }
}
