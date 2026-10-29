import BudgieCore
import SwiftUI

/// Add / edit sheet (`transaction_form.dart`, spec 02 section 1.8), as a
/// card-styled sheet with an Expense/Income toggle (D5).
///
/// Date semantics follow the Flutter form: a new transaction is stamped with
/// `model.now` unless the user picks a day, which is stored as that day at
/// midnight (`calendar.date(y, m, d)`); an edit keeps the stored value unless
/// a day is picked. The `DatePicker` only ever carries a calendar day; stored
/// values stay `DartDateTime`.
///
/// `.prefill` is the voice entry's confirmation (Flutter's `prefill`): an
/// add opened with what was said. Its date is kept exactly, time of day
/// included, unless a day is picked; the rules run once on it as the form
/// opens; there is no "Make this recurring", and the sheet cannot be swiped
/// away (Flutter's dialog has `barrierDismissible: false`).
///
/// "Make this recurring" swaps this sheet's content for the recurring form
/// in place (Flutter pops the dialog and opens the recurring one), so every
/// presenter gets it without a second, stacked sheet.
struct TransactionFormView: View {
    enum Mode: Hashable {
        case add(TransactionType)
        case edit(TransactionRecord)
        case prefill(VoiceDraft)
    }

    let mode: Mode
    /// Preselected category for a new entry (the quick-expense sheet); used
    /// only if it is in the picker list.
    var initialCategory: String? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var type: TransactionType
    @State private var amountText: String
    @State private var descriptionText: String
    @State private var category: String
    /// Tag ids in insertion order; an edit keeps ids whose tag is gone.
    @State private var selectedTagIds: [String]
    /// The ids the last rule suggestion put in `selectedTagIds` and the user
    /// has not toggled since; a type switch drops them.
    @State private var ruleTagIds: Set<String> = []
    /// The picked day at midnight, or a voice draft's exact date; nil keeps
    /// now (add) or the stored date.
    @State private var pickedDate: DartDateTime?
    @State private var amountError: String?
    /// The category menu's lists. Rows are identified by index and names
    /// compared as UTF-16 (Dart), so canonically-equivalent spellings (NFC
    /// and NFD "Café") stay two rows with their own icons.
    @State private var options: [TransactionType: [CategoryInfo]] = [:]
    /// The edited record's (or voice draft's) own category info when the list
    /// lacks its name.
    @State private var recordInfo: CategoryInfo?
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var deleteConfirms = 0
    @State private var showingDatePicker = false
    @State private var showingRecurring = false

    init(mode: Mode, initialCategory: String? = nil) {
        self.mode = mode
        self.initialCategory = initialCategory
        switch mode {
        case .add(let type):
            _type = State(initialValue: type)
            _amountText = State(initialValue: "")
            _descriptionText = State(initialValue: "")
            _category = State(initialValue: "")
            _selectedTagIds = State(initialValue: [])
        case .edit(let record):
            _type = State(initialValue: record.type)
            _amountText = State(initialValue: DartFixed.toStringAsFixed(record.amount, 2))
            _descriptionText = State(initialValue: record.description)
            _category = State(initialValue: record.category)
            _selectedTagIds = State(initialValue: record.tagIds)
        case .prefill(let draft):
            _type = State(initialValue: draft.type)
            _amountText = State(initialValue: Self.prefillAmountText(draft.amount))
            _descriptionText = State(initialValue: draft.description)
            _category = State(initialValue: draft.category)
            _selectedTagIds = State(initialValue: [])
            _pickedDate = State(initialValue: draft.date)
        }
    }

    private var editing: TransactionRecord? {
        if case .edit(let record) = mode { return record }
        return nil
    }

    private var prefill: VoiceDraft? {
        if case .prefill(let draft) = mode { return draft }
        return nil
    }

    var body: some View {
        Group {
            if showingRecurring {
                RecurringFormView(template: nil, initialType: type)
                    .transition(.opacity)
            } else {
                form
                    .budgieSheetChrome()
                    .transition(.opacity)
            }
        }
        .motion(Motion.easeOut(Motion.fast), value: showingRecurring)
    }

    // MARK: - Derived values

    /// The category rows for the current type; in edit mode the record's own
    /// category, and for a voice draft the draft's, is kept even if the
    /// catalog no longer lists it (Flutter keeps and saves a prefill's).
    private var categoryRows: [(name: String, info: CategoryInfo?)] {
        var rows: [(name: String, info: CategoryInfo?)] = (options[type] ?? []).map { ($0.name, $0) }
        if let record = editing, record.type == type, !rows.contains(where: { DartString.equal($0.name, record.category) }) {
            rows.append((record.category, recordInfo))
        }
        if let draft = prefill, draft.type == type, !rows.contains(where: { DartString.equal($0.name, draft.category) }) {
            rows.append((draft.category, recordInfo))
        }
        return rows
    }

    private func hasCategory(_ name: String) -> Bool {
        categoryRows.contains { DartString.equal($0.name, name) }
    }

    /// The stored date for this save (see the type comment).
    private func resolvedDate() -> DartDateTime {
        pickedDate ?? editing?.date ?? model.now
    }

    private var title: String {
        (editing == nil ? "Add " : "Edit ") + (type == .income ? "Income" : "Expense")
    }

    // MARK: - Form

    private var form: some View {
        // Flutter's Column(Flexible(scroll), footer): the footer sits below
        // the scroll area (and above the keyboard) rather than over it.
        // REDESIGN_PLAN 4.1: on an 874pt phone at the default text size
        // every row fits above the decimal pad, so nothing scrolls; shorter
        // phones and large text scroll, with a fade cueing more below.
        VStack(spacing: 0) {
            FormScrollArea {
                VStack(alignment: .leading, spacing: Metrics.spacingS) {
                    FormTitleRow(title: title, type: $type)
                    BudgieField(
                        title: "Amount", text: $amountText, prompt: "0.00", keyboard: .decimalPad, error: amountError,
                        autofocus: true, style: .amount, prefix: AmountInput.currencySymbol(model.moneyFormatter)
                    )
                    .padding(.top, Metrics.spacingXS)
                    BudgieField(
                        title: "Description", text: $descriptionText, prompt: "What was this for?", symbol: "text.alignleft",
                        style: .inline)
                    CategoryMenuRow(rows: categoryRows, category: $category, identifier: "form.category")
                    DateTile(label: "Date", value: DartDateFormat.MMMddyyyy(resolvedDate())) { showingDatePicker = true }
                    if !model.tags.isEmpty {
                        tagsRow
                    }
                    if editing != nil {
                        PillButton(title: "Delete Transaction", symbol: "trash", color: BudgieColor.danger) { confirmingDelete = true }
                            .disabled(saving)
                            .opacity(saving ? Metrics.opacityDisabled : 1)
                            .padding(.top, Metrics.spacingS)
                    }
                }
            }
            footer
        }
        .onAppear(perform: loadCategories)
        .onChange(of: type) { _, _ in typeChanged() }
        .onChange(of: amountText) { _, _ in
            amountError = nil
            applySuggestion()
        }
        .onChange(of: descriptionText) { _, _ in applySuggestion() }
        .sheet(isPresented: $showingDatePicker) {
            DayPickerSheet(
                initial: resolvedDate(), earliest: earliestDay, latest: latestDay, calendar: model.calendar
            ) { day in
                pickedDate = day
            }
        }
        .alert("Delete Transaction", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteConfirms += 1
                Task { await delete() }
            }
        } message: {
            Text("Are you sure you want to delete this transaction?")
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteConfirms)
        .interactiveDismissDisabled(saving || prefill != nil)
    }

    // MARK: Tags

    /// The Tags row: "Tags" over "Optional" in the label column, then the
    /// tag chips wrapping inside the row (it grows with them).
    private var tagsRow: some View {
        FormRow(label: "Tags", note: "Optional") {
            FlowLayout(spacing: Metrics.spacingS) {
                // By position: foreign data can repeat a tag id.
                ForEach(Array(model.tags.enumerated()), id: \.offset) { _, tag in
                    let selected = selectedTagIds.contains(tag.id)
                    Button {
                        if selected { selectedTagIds.removeAll { $0 == tag.id } } else { selectedTagIds.append(tag.id) }
                        ruleTagIds.remove(tag.id)
                    } label: {
                        TagChip(name: tag.name, selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
    }

    // MARK: Footer

    private var footer: some View {
        FormFooter {
            HStack(spacing: 12) {
                FormButton(title: "Cancel", fill: nil) { dismiss() }
                FormButton(
                    title: editing == nil ? "Add" : "Update",
                    fill: type == .income ? BudgieColor.incomeFixed : BudgieColor.expenseFixed, loading: saving
                ) {
                    Task { await save() }
                }
            }
            .disabled(saving)
            if prefill == nil {
                Button {
                    showingRecurring = true
                } label: {
                    HStack(spacing: Metrics.spacingS) {
                        Image(systemName: "repeat")
                            .font(.system(size: 14, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Make this recurring")
                            .textStyle(Self.recurringLink)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(BudgieColor.accent)
                    .padding(.horizontal, Metrics.spacingM)
                    .frame(minHeight: 40)
                    // The link is 40pt tall; the tap area is 44.
                    .tapArea(vertical: 2)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(saving)
                .opacity(saving ? Metrics.opacityDisabled : 1)
            }
        }
    }

    private static let recurringLink = TextSpec(face: .gabaritoSemiBold, size: 14, relativeTo: .subheadline)

    // MARK: - Actions

    private func loadCategories() {
        guard !loaded else { return }
        for kind in TransactionType.allCases {
            options[kind] = model.categories(for: kind)
        }
        if let record = editing {
            recordInfo = model.categoryInfo(named: record.category, type: record.type)
        }
        if let draft = prefill {
            recordInfo = model.categoryInfo(named: draft.category, type: draft.type)
        }
        if editing == nil, prefill == nil, let initialCategory, let row = categoryRows.first(where: { DartString.equal($0.name, initialCategory) }) {
            category = row.name
        }
        if !hasCategory(category) { category = categoryRows.first?.name ?? "" }
        // The rules run once on the draft (Flutter: `onChanged` does not fire
        // for programmatic text), on its raw amount rather than the rounded
        // text; the same gate as `applySuggestion`.
        if let draft = prefill, let rule = model.suggestion(type: draft.type, description: draft.description, amount: draft.amount) {
            category = (options[draft.type] ?? []).first { DartString.equal($0.name, rule.category) }?.name ?? rule.category
            selectedTagIds = Self.distinctTagIds(rule.tagIds)
            ruleTagIds = Set(selectedTagIds)
        }
        loaded = true
    }

    /// The Expense/Income toggle (D5; Flutter's form has none). Back on the
    /// record's own type an edit gets its stored category again; otherwise a
    /// category the new type lacks becomes its first. Tags the last rule
    /// applied go (the record's stored ids and manual picks stay), then the
    /// new type's rules run on the current description and amount.
    private func typeChanged() {
        if let record = editing, record.type == type {
            category = record.category
        } else if let draft = prefill, draft.type == type {
            category = draft.category
        } else if !hasCategory(category) {
            category = categoryRows.first?.name ?? ""
        }
        let stored = editing?.tagIds ?? []
        selectedTagIds.removeAll { ruleTagIds.contains($0) && !stored.contains($0) }
        ruleTagIds = []
        applySuggestion()
    }

    /// `applySuggestion` (transaction_form.dart:106-121): on every Amount or
    /// Description edit, a matching rule whose category is in the current
    /// list sets the category and replaces the selected tags.
    private func applySuggestion() {
        guard
            let rule = model.suggestion(
                type: type, description: descriptionText,
                amountText: RecurringForm.normalizedAmount(amountText, locale: .current)),
            let name = (options[type] ?? []).first(where: { DartString.equal($0.name, rule.category) })?.name
        else { return }
        category = name
        selectedTagIds = Self.distinctTagIds(rule.tagIds)
        ruleTagIds = Set(selectedTagIds)
    }

    /// The rule's tag ids in order, each once (Flutter puts them in a Set).
    nonisolated static func distinctTagIds(_ ids: [String]) -> [String] {
        var tags: [String] = []
        for id in ids where !tags.contains(id) { tags.append(id) }
        return tags
    }

    /// The prefilled Amount text (transaction_form.dart:68-70): two
    /// decimals when the draft has an amount, empty otherwise (a zero,
    /// negative or `-0.0` amount leaves the field empty for "Amount is
    /// required").
    nonisolated static func prefillAmountText(_ amount: Double) -> String {
        amount > 0 ? DartFixed.toStringAsFixed(amount, 2) : ""
    }

    private func save() async {
        guard !saving else { return }
        let parsed: Double
        switch Self.validateAmount(amountText) {
        case .failure(let error):
            amountError = error.message
            AccessibilityNotification.Announcement(error.message).post()
            return
        case .success(let value):
            parsed = value
        }
        let trimmed = DartString.trim(descriptionText)
        let description = trimmed.isEmpty ? "Transaction" : trimmed
        let date = resolvedDate()
        saving = true
        let saved: Bool
        if let record = editing {
            // An untouched amount field keeps the stored value exactly (the
            // prefill is rounded to cents).
            let amount = amountText == DartFixed.toStringAsFixed(record.amount, 2) ? record.amount : parsed
            let outcome = await model.updateTransaction(
                id: record.id,
                TransactionRecord.Edit(
                    type: type, description: description, amount: amount, category: category, date: date,
                    tagIds: selectedTagIds))
            // The row went while the form was open (deleted elsewhere):
            // nothing to save and nothing failed.
            if outcome == .rejected {
                dismiss()
                return
            }
            saved = outcome == .saved
        } else {
            saved = await model.addTransaction(
                type: type, description: description, amount: parsed, category: category, date: date,
                tagIds: selectedTagIds)
        }
        dismiss()
        if !saved {
            model.showToast(.saveFailed)
        } else if editing == nil,
            date.year != model.selectedMonth.year || date.month != model.selectedMonth.month
        {
            model.showToast(.addedTo(month: date, now: model.now))
        }
    }

    private func delete() async {
        guard let record = editing, !saving else { return }
        saving = true
        let outcome = await model.deleteTransaction(id: record.id)
        dismiss()
        // Rejected: the row is already gone, nothing failed.
        if outcome != .rejected { model.showToast(outcome == .saved ? .transactionDeleted : .saveFailed) }
    }

    // MARK: - Date range

    /// 2000-01-01, or the stored day when it is earlier (Flutter asserts).
    private var earliestDay: DartDateTime {
        let floor = model.calendar.date(2000, 1, 1)
        guard let stored = editing?.date, stored.isBefore(floor) else { return floor }
        return stored
    }

    /// Today, or the stored day when it is later (Flutter asserts).
    private var latestDay: DartDateTime {
        let now = model.now
        guard let stored = editing?.date, stored.isAfter(now) else { return now }
        return stored
    }

    // MARK: - Amount validation

    enum AmountError: Error, Equatable {
        case required, invalid, notPositive

        var message: String {
            switch self {
            case .required: "Amount is required"
            case .invalid: "Please enter a valid number"
            case .notPositive: "Amount must be greater than 0"
            }
        }
    }

    /// `validateForm` (transaction_form.dart:152-165): empty is required;
    /// Dart `double.tryParse` (after mapping the locale's decimal separator
    /// to '.') nil or non-finite is invalid; `<= 0` is not positive.
    nonisolated static func validateAmount(_ text: String, locale: Locale = .current) -> Result<Double, AmountError> {
        if text.isEmpty { return .failure(.required) }
        guard let value = DartDouble.tryParse(RecurringForm.normalizedAmount(text, locale: locale)), value.isFinite else {
            return .failure(.invalid)
        }
        guard value > 0 else { return .failure(.notPositive) }
        return .success(value)
    }
}

// MARK: - Pieces

/// The add forms' scroll area (REDESIGN_PLAN 4.1): content padded 8 / 20
/// / 16 under the sheet's grab handle; it scrolls only when the content is
/// taller than the space (`basedOnSize`), and then a 44pt fade from the
/// sheet's card colour at the bottom cues that more is below (gone once
/// the end is in view).
struct FormScrollArea<Content: View>: View {
    @ViewBuilder var content: () -> Content

    /// The content's bottom edge in the scroll area's own space.
    @State private var contentBottom: CGFloat = 0
    @State private var height: CGFloat = 0

    private static var space: String { "formScrollArea" }

    var body: some View {
        ScrollView {
            content()
                .padding(EdgeInsets(top: Metrics.spacingS, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
                .background(
                    GeometryReader { proxy in
                        let bottom = proxy.frame(in: .named(Self.space)).maxY
                        Color.clear.onChange(of: bottom, initial: true) { _, value in contentBottom = value }
                    })
        }
        .coordinateSpace(.named(Self.space))
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChangeCompat { height = $0.height }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [BudgieColor.card.opacity(0), BudgieColor.card], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .opacity(contentBottom > height + 1 ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The add forms' title row: the title at 22 ExtraBold on the left and, with
/// a `type`, the Expense / Income pills on the right. When both do not fit
/// on one line (a long title, large text) the pills go under the title.
struct FormTitleRow: View {
    let title: String
    /// nil hides the pills (the recurring form when editing).
    var type: Binding<TransactionType>?
    var titleIdentifier: String? = nil

    private static let titleText = TextSpec(face: .gabaritoExtraBold, size: 22, tracking: -0.44, relativeTo: .title2)

    var body: some View {
        RowOrColumn(rowSpacing: 12, columnSpacing: 12, spreads: true) {
            titleLabel
            pills
        }
    }

    private var titleLabel: some View {
        Text(title)
            .textStyle(Self.titleText)
            .foregroundStyle(BudgieColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(titleIdentifier ?? "")
    }

    @ViewBuilder
    private var pills: some View {
        if let type {
            SegmentedPills(
                items: ["Expense", "Income"],
                selection: Binding(get: { type.wrappedValue == .income ? 1 : 0 }, set: { type.wrappedValue = $0 == 1 ? .income : .expense }),
                fillWidth: true
            )
            .frame(width: 176, height: 32)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Transaction type")
        }
    }
}

/// The Category row (REDESIGN_PLAN 4.1): a `FormRow` with the selected
/// category's tile and name, opening a menu whose inline picker lists
/// `rows` in order and checks the selection. One accessibility element: a
/// button named "Category" with the category as its value.
struct CategoryMenuRow: View {
    let rows: [(name: String, info: CategoryInfo?)]
    @Binding var category: String
    let identifier: String

    @State private var picks = 0

    var body: some View {
        let selected = rows.first { DartString.equal($0.name, category) }
        Menu {
            Picker("Category", selection: selection) {
                ForEach(rows.indices, id: \.self) { index in
                    Label(rows[index].name, systemImage: CategoryCatalog.symbol(for: rows[index].info?.iconIdentifier ?? ""))
                        .tag(index)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FormRow(label: "Category", trailingSymbol: "chevron.down") {
                HStack(spacing: 10) {
                    IconTile(category: selected?.info, size: 28, radius: 9, iconSize: 15)
                    Text(category)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .singleLine()
                }
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Category")
        .accessibilityValue(category)
        .accessibilityIdentifier(identifier)
        .sensoryFeedback(.selection, trigger: picks)
    }

    /// The menu's own picks (a rule's change moves it without a tick); -1
    /// (no checkmark) while the category is not in the list.
    private var selection: Binding<Int> {
        Binding(
            get: { rows.firstIndex { DartString.equal($0.name, category) } ?? -1 },
            set: {
                guard rows.indices.contains($0), !DartString.equal(rows[$0].name, category) else { return }
                category = rows[$0].name
                picks += 1
            })
    }
}

/// A tag chip in the form's Tags row: 34pt capsule; selected is accent at
/// 13% with the name in accent 13 Bold, unselected a 1pt card border with
/// the name in secondary 13 SemiBold. One line, truncated when wider than
/// the row (Flutter's chip label: maxLines 1).
struct TagChip: View {
    let name: String
    let selected: Bool

    private static let selectedText = TextSpec(face: .gabaritoBold, size: 13, relativeTo: .footnote)
    private static let text = TextSpec(face: .gabaritoSemiBold, size: 13, relativeTo: .footnote)

    var body: some View {
        Text(name)
            .textStyle(selected ? Self.selectedText : Self.text)
            .foregroundStyle(selected ? BudgieColor.accent : BudgieColor.textSecondary)
            .singleLine()
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(selected ? BudgieColor.accent.opacity(0.13) : Color.clear, in: Capsule())
            .overlay { if !selected { Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin) } }
            // The chip draws 34pt tall; the tap area is 44.
            .tapArea(vertical: 5)
    }
}

/// The add forms' footer, pinned under the scroll area (so above the
/// keyboard): a 1pt hairline on top, padding 10 / 20 / 6, rows 2 apart.
struct FormFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: Metrics.spacingXXS) {
            content()
        }
        .padding(EdgeInsets(top: 10, leading: Metrics.pageHorizontal, bottom: 6, trailing: Metrics.pageHorizontal))
        .overlay(alignment: .top) {
            BudgieColor.hairline.frame(height: Metrics.borderThin).accessibilityHidden(true)
        }
    }
}

/// The footer buttons: 50pt capsules; primary is filled (the type's fixed
/// red or green) with a white 16 Bold label and a spinner while saving,
/// secondary is outlined (1.5pt card border). Presses to 0.95 with a light
/// haptic; 0.38 opacity when disabled.
struct FormButton: View {
    let title: String
    /// nil is the outlined secondary button.
    let fill: Color?
    var loading = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var taps = 0

    private static let label = TextSpec(face: .gabaritoBold, size: 16, relativeTo: .body)

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: Metrics.spacingS) {
                if loading {
                    // White on `expenseFixed` / `incomeFixed` (their token pairs).
                    ProgressView().tint(.white).accessibilityHidden(true)
                }
                Text(title).textStyle(Self.label).multilineTextAlignment(.center)
            }
            .foregroundStyle(fill == nil ? BudgieColor.textPrimary : .white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background { if let fill { Capsule().fill(fill) } }
            .overlay { if fill == nil { Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderMedium) } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .opacity(isEnabled ? 1 : Metrics.opacityDisabled)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

/// Wrapping rows of chips (Flutter `Wrap`), leading-aligned (also the Add
/// money dialog's quick amounts). A chip wider than the row gets the row's
/// width, so a long tag pill truncates inside the card (Flutter's `Wrap`
/// constrains a chip to its width) instead of running past it.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        // Whole points up: the parent places the layout at this width
        // snapped to the pixel grid, and a width rounded below the
        // fractional sum made `placeSubviews` wrap a row that was measured
        // as one (its last chip then overlapped the view below).
        return CGSize(width: rows.width.rounded(.up), height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, item) in rows.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y), proposal: item.proposal)
        }
    }

    /// Each subview at its ideal size, except one wider than the row: that
    /// one is measured (and later placed) at the row's width, on a row of
    /// its own.
    private func arrange(
        width: CGFloat, subviews: Subviews
    ) -> (items: [(origin: CGPoint, proposal: ProposedViewSize)], width: CGFloat, height: CGFloat) {
        var items: [(origin: CGPoint, proposal: ProposedViewSize)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var proposal = ProposedViewSize.unspecified
            var size = subview.sizeThatFits(proposal)
            if size.width > width {
                proposal = ProposedViewSize(width: width, height: nil)
                size = subview.sizeThatFits(proposal)
            }
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append((CGPoint(x: x, y: y), proposal))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (items, widest, y + rowHeight)
    }
}

/// The date picker (Flutter `showDatePicker`): a graphical calendar in a
/// fitted sheet, Cancel / OK. The picker only carries a calendar day, read
/// back as Gregorian year / month / day in the app's time zone.
struct DayPickerSheet: View {
    let calendar: DartCalendar
    let range: ClosedRange<Date>
    let onPick: (DartDateTime) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    @State private var height: CGFloat = 480

    init(initial: DartDateTime, earliest: DartDateTime, latest: DartDateTime, calendar: DartCalendar, onPick: @escaping (DartDateTime) -> Void) {
        self.calendar = calendar
        self.onPick = onPick
        let gregorian = Self.gregorian(calendar)
        // The whole of the earliest and latest days stay pickable.
        let lower = gregorian.startOfDay(for: Self.pickerDate(for: earliest, in: gregorian))
        let upper =
            gregorian.date(from: DateComponents(year: latest.year, month: latest.month, day: latest.day, hour: 23, minute: 59))
            ?? latest.date
        let range = lower...max(lower, upper)
        self.range = range
        _day = State(initialValue: min(max(Self.pickerDate(for: initial, in: gregorian), range.lowerBound), range.upperBound))
    }

    /// Gregorian in the app's zone, weeks starting on the user's first
    /// weekday (Flutter's picker follows the locale's).
    nonisolated static func gregorian(
        _ calendar: DartCalendar, firstWeekday: Int = Calendar.autoupdatingCurrent.firstWeekday
    ) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.firstWeekday = firstWeekday
        return gregorian
    }

    /// The picker's value for a day: 12:00 local on it, so a DST gap at
    /// midnight can never move it to a neighbouring day.
    nonisolated static func pickerDate(for day: DartDateTime, in gregorian: Calendar) -> Date {
        gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? day.date
    }

    /// The stored value for the picker's day: `DateTime(y, m, d)`.
    nonisolated static func storedDay(from date: Date, in gregorian: Calendar, calendar: DartCalendar) -> DartDateTime? {
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return calendar.date(year, month, day)
    }

    var body: some View {
        ScrollView {
            content
                .onGeometryChangeCompat { height = $0.height + 20 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .budgieSheetChrome()
        .presentationDetents([.height(height)])
    }

    private var content: some View {
        VStack(spacing: Metrics.spacingM) {
            Text("Select date")
                .textStyle(.headingSmall)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            DatePicker("Date", selection: $day, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(BudgieColor.accent)
                .environment(\.calendar, Self.gregorian(calendar))
                .environment(\.timeZone, calendar.timeZone)
            // The app's dialog buttons (Goals, Worth): an outlined Cancel and
            // an accent-filled OK, as Material's date picker actions are both
            // in the accent colour.
            HStack(spacing: 12) {
                PillButton(title: "Cancel", color: BudgieColor.textSecondary, height: 44) { dismiss() }
                    .accessibilityIdentifier("datePicker.cancel")
                PillButton(title: "OK", filled: true, height: 44) {
                    if let picked = Self.storedDay(from: day, in: Self.gregorian(calendar), calendar: calendar) { onPick(picked) }
                    dismiss()
                }
                .accessibilityIdentifier("datePicker.ok")
            }
        }
        .padding(.horizontal, Metrics.spacingM)
        .padding(.bottom, Metrics.spacingM)
    }
}
