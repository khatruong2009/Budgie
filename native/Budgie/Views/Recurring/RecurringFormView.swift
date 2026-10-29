import BudgieCore
import SwiftUI

/// Add (`template == nil`) or edit a recurring template
/// (`recurring_transaction_form.dart`), as a card-styled sheet like the
/// transaction form (D5); it also replaces the transaction form's content
/// in place for "Make this recurring", so it brings its own chrome.
///
/// Flutter's field order and copy: Amount (focused), Description, the
/// Category (a menu row, as on the transaction form), the Recurrence
/// Pattern wheel, the Day of Month wheel
/// (monthly), the Start Date tile, the "Next 3 Occurrences" preview, then
/// Cancel and Save / Update in the type's colour. Save validates all three
/// fields at once (`RecurringForm.validate`) and closes only after the
/// awaited write.
///
/// Differences from Flutter (PARITY_GAPS): the Expense/Income toggle when
/// adding; no Day of Week wheel; the Day of Month wheel follows the picked
/// start day until it is touched; the picker offers only days that pass
/// the one-year rule, which applies only to a start set here, plus an
/// edit's stored start day (so OK on an old template keeps its start); an
/// edit previews from the cursor the edit will leave and keeps the cursor.
struct RecurringFormView: View {
    let template: RecurringTemplate?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var type: TransactionType
    @State private var amountText: String
    @State private var descriptionText: String
    @State private var category: String
    @State private var pattern: RecurrencePattern
    @State private var dayOfMonth: Int
    /// The wheel was moved: the day no longer follows the picked start day.
    @State private var dayOfMonthEdited: Bool
    /// The picked day at midnight; nil keeps the stored start (edit) or the
    /// moment the form opened (add).
    @State private var pickedStart: DartDateTime?
    @State private var openedAt: DartDateTime?
    /// The latest row generated from the edited template, read once.
    @State private var lastGenerated: DartDateTime?
    @State private var amountError: String?
    @State private var descriptionError: String?
    @State private var startDateError: String?
    @State private var options: [TransactionType: [CategoryInfo]] = [:]
    @State private var templateInfo: CategoryInfo?
    @State private var loaded = false
    @State private var saving = false
    @State private var showingDatePicker = false
    @State private var wheelTicks = 0

    /// `initialType` is the new template's type (the transaction form's
    /// "Make this recurring" opens it for the form's type).
    init(template: RecurringTemplate?, initialType: TransactionType = .expense) {
        self.template = template
        _type = State(initialValue: template?.type ?? initialType)
        _amountText = State(initialValue: template.map { DartFixed.toStringAsFixed($0.amount, 2) } ?? "")
        _descriptionText = State(initialValue: template?.description ?? "")
        _category = State(initialValue: template?.category ?? "")
        _pattern = State(initialValue: template?.pattern ?? .monthly)
        // Set in `load()` (`RecurringForm.initialDayOfMonth`).
        _dayOfMonth = State(initialValue: 1)
        _dayOfMonthEdited = State(initialValue: false)
    }

    // MARK: - Derived values

    private var isEditing: Bool { template != nil }

    private var title: String {
        (isEditing ? "Edit Recurring " : "Add Recurring ") + (type == .income ? "Income" : "Expense")
    }

    private var resolvedStart: DartDateTime {
        RecurringForm.resolvedStart(
            picked: pickedStart, stored: template?.startDate, openedAt: openedAt ?? model.now, calendar: model.calendar)
    }

    /// The category rows for the current type; an edit keeps the template's
    /// own category even if the catalog no longer lists it.
    private var categoryRows: [(name: String, info: CategoryInfo?)] {
        var rows: [(name: String, info: CategoryInfo?)] = (options[type] ?? []).map { ($0.name, $0) }
        if let template, template.type == type, !rows.contains(where: { DartString.equal($0.name, template.category) }) {
            rows.append((template.category, templateInfo))
        }
        return rows
    }

    private func edit(amount: Double, description: String) -> RecurringTemplate.Edit {
        RecurringForm.edit(
            type: type, description: description, amount: amount, category: category, pattern: pattern, start: resolvedStart,
            dayOfMonth: dayOfMonth)
    }

    /// Flutter's `_calculatePreviewDates` from the start when adding; from
    /// the cursor the edit will leave when editing (approved divergence).
    private var previewDates: [DartDateTime] {
        let calendar = model.calendar
        guard let template else {
            return RecurringGenerator.previewOccurrences(
                pattern: pattern, start: resolvedStart, dayOfMonth: pattern == .monthly ? dayOfMonth : nil, calendar: calendar)
        }
        let current = model.data?.templates.first { $0.id == template.id } ?? template
        return RecurringGenerator.previewOccurrences(
            editing: current, edit(amount: current.amount, description: current.description), lastGenerated: lastGenerated,
            calendar: calendar)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            FormScrollArea {
                VStack(alignment: .leading, spacing: 0) {
                    FormTitleRow(title: title, type: isEditing ? nil : $type, titleIdentifier: "recurring.form.title")
                    BudgieField(
                        title: "Amount", text: $amountText, prompt: "0.00", keyboard: .decimalPad, error: amountError,
                        autofocus: true, style: .amount, prefix: AmountInput.currencySymbol(model.moneyFormatter)
                    )
                    .padding(.top, 12)
                    BudgieField(
                        title: "Description", text: $descriptionText, prompt: "What is this for?", symbol: "text.alignleft",
                        error: descriptionError, style: .inline
                    )
                    .padding(.top, Metrics.spacingS)
                    CategoryMenuRow(rows: categoryRows, category: $category, identifier: "recurring.form.category")
                        .padding(.top, Metrics.spacingS)
                    fieldLabel("Recurrence Pattern").padding(.top, Metrics.spacingM)
                    patternWheel
                    if pattern == .monthly {
                        fieldLabel("Day of Month").padding(.top, Metrics.spacingS)
                        dayWheel
                    }
                    startDate.padding(.top, Metrics.spacingM)
                    preview.padding(.top, Metrics.spacingM)
                }
                .motion(Motion.easeOut(Motion.fast), value: pattern == .monthly)
            }
            footer
        }
        .budgieSheetChrome()
        .onAppear(perform: load)
        .onChange(of: type) { _, _ in
            if !categoryRows.contains(where: { DartString.equal($0.name, category) }) { category = categoryRows.first?.name ?? "" }
        }
        .onChange(of: amountText) { _, _ in amountError = nil }
        .onChange(of: descriptionText) { _, _ in descriptionError = nil }
        .sheet(isPresented: $showingDatePicker) {
            let range = RecurringForm.startDateRange(now: model.now, calendar: model.calendar, storedStart: template?.startDate)
            DayPickerSheet(initial: resolvedStart, earliest: range.lowerBound, latest: range.upperBound, calendar: model.calendar) {
                picked($0)
            }
        }
        .sensoryFeedback(.selection, trigger: wheelTicks)
        .interactiveDismissDisabled(saving)
    }

    /// The field labels (`caption` w600 in Flutter), hidden from VoiceOver
    /// where the control below carries the same label.
    private func fieldLabel(_ text: String) -> some View {
        FieldCaption(text, hidden: true)
            .padding(.bottom, 6)
    }

    // MARK: Wheels

    /// Flutter's 90pt `CupertinoPicker` box: fill, radius 12, 1.5pt border.
    private func wheelBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous)
        return Group {
            if loaded { content() } else { Color.clear }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .clipShape(shape)
        .background(BudgieColor.chipSurface, in: shape)
        .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderMedium))
    }

    private var patternWheel: some View {
        wheelBox {
            Picker("Recurrence Pattern", selection: patternSelection) {
                ForEach(RecurrencePattern.allCases, id: \.self) { value in
                    Text(value.displayName)
                        .textStyle(.bodyMedium)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .accessibilityLabel("Recurrence Pattern")
            .accessibilityValue(pattern.displayName)
            .accessibilityIdentifier("recurring.form.pattern")
        }
    }

    private var patternSelection: Binding<RecurrencePattern> {
        Binding(
            get: { pattern },
            set: {
                guard $0 != pattern else { return }
                pattern = $0
                wheelTicks += 1
            })
    }

    private var dayWheel: some View {
        wheelBox {
            Picker("Day of Month", selection: daySelection) {
                ForEach(RecurringForm.daysOfMonth, id: \.self) { day in
                    Text("\(day)")
                        .textStyle(.bodyMedium)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .tag(day)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .accessibilityLabel("Day of Month")
            .accessibilityValue("\(dayOfMonth)")
            .accessibilityIdentifier("recurring.form.day")
        }
    }

    private var daySelection: Binding<Int> {
        Binding(
            get: { dayOfMonth },
            set: {
                guard $0 != dayOfMonth else { return }
                dayOfMonth = $0
                dayOfMonthEdited = true
                wheelTicks += 1
            })
    }

    // MARK: Start date and preview

    private var startDate: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            DateTile(label: "Start Date", value: DartDateFormat.MMMddyyyy(resolvedStart), error: startDateError != nil) {
                showingDatePicker = true
            }
            .disabled(saving)
            .accessibilityIdentifier("recurring.form.start")
            if let startDateError {
                FieldErrorLabel(startDateError)
            }
        }
    }

    /// The "Next 3 Occurrences" card (:578-626): header, then one
    /// `EEEE, MMM dd, yyyy` line per date.
    private var preview: some View {
        let lines = previewDates.map(DartDateFormat.EEEEMMMddyyyy)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingS) {
                Image(systemName: "eye")
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
                Text("Next 3 Occurrences").textStyle(.captionStrong)
            }
            .foregroundStyle(BudgieColor.textSecondary)
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .textStyle(.bodySmall)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .accessibilityIdentifier("recurring.form.preview.date")
                }
            }
        }
        .padding(Metrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BudgieColor.chipSurface.opacity(0.5), in: shape)
        .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recurring.form.preview")
    }

    // MARK: Footer

    private var footer: some View {
        FormFooter {
            HStack(spacing: 12) {
                FormButton(title: "Cancel", fill: nil) { dismiss() }
                FormButton(
                    title: isEditing ? "Update" : "Save",
                    fill: type == .income ? BudgieColor.incomeFixed : BudgieColor.expenseFixed, loading: saving
                ) {
                    Task { await save() }
                }
                .accessibilityIdentifier("recurring.form.save")
            }
            .disabled(saving)
        }
    }

    // MARK: - Actions

    private func load() {
        guard !loaded else { return }
        let now = model.now
        openedAt = now
        for kind in TransactionType.allCases {
            options[kind] = model.categories(for: kind)
        }
        if let template {
            templateInfo = model.categoryInfo(named: template.category, type: template.type)
            lastGenerated = model.lastGeneratedDate(forTemplate: template.id)
        }
        let initialDay = RecurringForm.initialDayOfMonth(template: template, openedAt: now)
        dayOfMonth = initialDay.day
        dayOfMonthEdited = !initialDay.followsStart
        if !categoryRows.contains(where: { DartString.equal($0.name, category) }) { category = categoryRows.first?.name ?? "" }
        loaded = true
    }

    /// A picked day (midnight) replaces the start (the stored start's own
    /// day keeps it); the Day of Month wheel follows the resulting start
    /// until the wheel is touched. The rule is re-checked so a valid day
    /// clears the error.
    private func picked(_ day: DartDateTime) {
        pickedStart = day
        if !dayOfMonthEdited { dayOfMonth = resolvedStart.day }
        startDateError = RecurringForm.startDateError(start: resolvedStart, storedStart: template?.startDate, now: model.now)
    }

    private func save() async {
        guard !saving else { return }
        let result = RecurringForm.validate(
            amountText: amountText, description: descriptionText, start: resolvedStart, storedStart: template?.startDate,
            storedAmount: template?.amount, now: model.now)
        amountError = result.amountError
        descriptionError = result.descriptionError
        startDateError = result.startDateError
        guard result.isValid, let amount = result.amount else {
            if let first = result.amountError ?? result.descriptionError ?? result.startDateError {
                AccessibilityNotification.Announcement(first).post()
            }
            return
        }
        // The template went while the form was open (deleted elsewhere):
        // nothing to save and nothing failed.
        if let template, !(model.data?.templates.contains { $0.id == template.id } ?? false) {
            dismiss()
            return
        }
        saving = true
        let edit = edit(amount: amount, description: result.description)
        let saved: Bool
        if let template {
            saved = await model.updateTemplate(id: template.id, edit)
        } else {
            saved = await model.addTemplate(edit)
        }
        dismiss()
        if !saved { model.showToast(.saveFailed) }
    }
}
