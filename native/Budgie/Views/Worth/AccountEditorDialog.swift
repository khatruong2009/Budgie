import BudgieCore
import SwiftUI

/// The add / edit account dialog (`_NetWorthEditorDialog`, NW:2140-2513),
/// hosted by `budgieDialog` with no padding so the header banner runs to
/// the border. Banner: the type colour (green for an asset, rose for a
/// liability) at 8% behind the type's arrow tile, "Add account" / "Edit
/// account" in the sheet title style, the balance month and a close
/// button. Body, balance first so the figure stays in view above the
/// number pad: the balance in the big amount field, the account name, then
/// one row with the Asset / Liability arrow toggle and the balance month
/// (an inline month grid, 1970 to this month, instead of Material's date
/// picker); then the outlined Cancel and the Add / Save pill filled in the
/// type colour.
///
/// The balance field formats as Flutter's `_CurrencyInputFormatter`
/// (`NetWorthAmountInput.sanitize`: digits, one ".", two decimals, commas
/// every three digits), and a comma-decimal keyboard's "," typed at the end
/// becomes "." (D6). Editing prefills the month's balance (`#,##0.##`);
/// an untouched field saves the stored value exactly. Save validates like
/// `_save` ("Name is required", then "Enter a valid balance"; 0 is valid),
/// awaits the model, then closes; a failed write shows the save-failed
/// toast (Flutter only shows the banner). While saving, the buttons and the
/// scrim are disabled.
struct AccountEditorDialog: View {
    let request: AccountEditorRequest
    let dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var amountText: String
    @State private var type: NetWorthEntryType
    @State private var entryMonth: DartDateTime
    @State private var nameError: String?
    @State private var amountError: String?
    @State private var saving = false
    @State private var pickingMonth = false
    /// The prefilled balance text and the stored value it rounds.
    @State private var prefill: (text: String, amount: Double?)
    @State private var typeTaps = 0
    @State private var monthTaps = 0

    init(request: AccountEditorRequest, dismiss: @escaping () -> Void) {
        self.request = request
        self.dismiss = dismiss
        let entry = request.entry
        let stored = entry?.amount(forMonth: request.month, calendar: request.calendar)
        // Flutter prefills `amountForMonth(month) ?? 0.0` when editing.
        let text = entry == nil ? "" : NetWorthAmountInput.prefill(stored ?? 0)
        _name = State(initialValue: entry?.name ?? "")
        _amountText = State(initialValue: text)
        _type = State(initialValue: entry?.type ?? request.initialType)
        _entryMonth = State(initialValue: request.calendar.month(of: request.month))
        _prefill = State(initialValue: (text, stored))
    }

    private var isEditing: Bool { request.entry != nil }
    private var accent: Color { type.tint }

    var body: some View {
        VStack(spacing: 0) {
            banner
            // The banner and the buttons stay put; the fields scroll when the
            // keyboard or a large text size leaves too little room. The
            // insets are inside the scroll view so the focused field's 2pt
            // ring is not clipped by it.
            DialogScroll {
                VStack(spacing: 12) {
                    // "Balance" keeps the label short enough for a long
                    // figure on a small phone; the type is in the label
                    // VoiceOver reads.
                    BudgieField(
                        title: "Balance", text: $amountText, prompt: "0.00", keyboard: .decimalPad,
                        error: amountError, style: .amount, prefix: AmountInput.currencySymbol(model.moneyFormatter),
                        accessibilityTitle: type == .asset ? "Asset balance" : "Liability balance")
                    BudgieField(
                        title: "Account name", text: $name, prompt: "Account name", symbol: Self.walletSymbol,
                        capitalization: .words, error: nameError, style: .inline)
                    typeAndMonth
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))
            }
            buttons
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .onChange(of: amountText) { old, new in
            if let replacement = Self.sanitizedAmount(old: old, new: new, prefill: prefill.text) { amountText = replacement }
        }
        .budgieDialogDismissDisabled(saving)
        .sensoryFeedback(.selection, trigger: typeTaps)
        // A container, so the identifier does not replace the fields' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worth.editor")
    }

    /// Material `account_balance_wallet_rounded`: SF's bifold wallet where
    /// the system has it (iOS 18), else the credit card.
    static let walletSymbol = UIImage(systemName: "wallet.bifold") != nil ? "wallet.bifold" : "creditcard"

    /// The balance text after an edit from `old` to `new`, or nil to keep
    /// `new`. Typing goes through Flutter's `_CurrencyInputFormatter`
    /// (`NetWorthAmountInput.sanitize`); the prefill a month pick assigns
    /// (a stored balance, possibly negative, which the formatter would
    /// reject) is kept as set, so Save sees the new month's balance.
    static func sanitizedAmount(old: String, new: String, prefill: String) -> String? {
        if new == prefill { return nil }
        let formatted = NetWorthAmountInput.sanitize(old: old, new: decimalKey(old: old, new: new))
        return formatted == new ? nil : formatted
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 0) {
            IconTile(symbol: type == .asset ? "arrow.up.right" : "arrow.down.left", color: accent, size: 44, iconSize: 22)
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(isEditing ? "Edit account" : "Add account")
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(DartDateFormat.yMMMM(entryMonth))
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(BudgieColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(BudgieColor.dialogCloseFill, in: Circle())
                    // The circle draws 32pt; the tap area is 44.
                    .tapArea(horizontal: 6, vertical: 6)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("worth.editor.close")
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 14, trailing: 20))
        // A flat tint of the type colour (Flutter: a green or red gradient).
        .background(accent.opacity(0.08))
        // Inside the dialog card's 1pt border.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Metrics.cardRadius - Metrics.borderThin,
                topTrailingRadius: Metrics.cardRadius - Metrics.borderThin, style: .continuous)
        )
        .motion(Motion.easeInOut(0.26), value: type)
    }

    // MARK: - Type and balance month

    /// The type toggle beside the balance month, the month grid below them
    /// while picking.
    private var typeAndMonth: some View {
        VStack(spacing: Metrics.spacingS) {
            HStack(spacing: Metrics.spacingS) {
                TypeToggle(type: $type) { typeTaps += 1 }
                monthButton
            }
            if pickingMonth {
                BalanceMonthGrid(selected: entryMonth, now: model.now, calendar: request.calendar, pick: pickMonth)
            }
        }
    }

    /// The balance month on the field fill: a calendar glyph, `yMMMM` and a
    /// chevron, at least 44pt tall (the text wraps at large sizes). Opening
    /// the grid ends editing: the balance keeps its focus otherwise, and the
    /// number pad leaves room for only the grid's first rows.
    private var monthButton: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            monthTaps += 1
            if !pickingMonth { RuleEditorDialog.dismissKeyboard() }
            pickingMonth.toggle()
        } label: {
            HStack(spacing: Metrics.spacingS) {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BudgieColor.textSecondary)
                Text(DartDateFormat.yMMMM(entryMonth))
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BudgieColor.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: Metrics.touchTarget)
            .background(BudgieColor.fieldFill, in: shape)
            .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Balance month")
        .accessibilityValue(DartDateFormat.yMMMM(entryMonth))
        .accessibilityIdentifier("worth.editor.month")
        .sensoryFeedback(.impact(weight: .light), trigger: monthTaps)
    }

    /// `_pickEntryMonth`: editing refills the balance with the new month's
    /// value (empty when it has none); adding leaves it alone.
    private func pickMonth(_ month: DartDateTime) {
        entryMonth = month
        pickingMonth = false
        guard let entry = request.entry else { return }
        let stored = entry.amount(forMonth: month, calendar: request.calendar)
        let text = stored.map(NetWorthAmountInput.prefill) ?? ""
        prefill = (text, stored)
        amountText = text
    }

    // MARK: - Buttons

    /// The dialog pair (REDESIGN_PLAN 4.7): outlined Cancel, and Add / Save
    /// filled in the type colour, spinning while the write is awaited. Both
    /// play the pill's light impact.
    private var buttons: some View {
        DialogButtons(
            cancelId: "worth.editor.cancel", submitTitle: isEditing ? "Save" : "Add", submitId: "worth.editor.save",
            color: accent, busy: saving, cancel: dismiss
        ) {
            Task { await save() }
        }
    }

    // MARK: - Save

    private func save() async {
        guard !saving else { return }
        nameError = nil
        amountError = nil
        let trimmed = DartString.trim(name)
        if trimmed.isEmpty {
            nameError = "Name is required"
            AccessibilityNotification.Announcement("Name is required").post()
            return
        }
        guard var amount = NetWorthAmountInput.parse(amountText) else {
            amountError = "Enter a valid balance"
            AccessibilityNotification.Announcement("Enter a valid balance").post()
            return
        }
        // The prefill is rounded to cents; untouched, keep the stored value.
        if amountText == prefill.text, let stored = prefill.amount { amount = stored }
        let saved: Bool
        if let entry = request.entry {
            // The account went while the dialog was open: nothing to save.
            guard model.netWorthEntry(id: entry.id) != nil else {
                dismiss()
                return
            }
            saving = true
            saved = await model.updateNetWorthEntry(id: entry.id, name: trimmed, type: type, amount: amount, month: entryMonth)
        } else {
            saving = true
            saved = await model.addNetWorthEntry(name: trimmed, type: type, amount: amount, month: entryMonth)
        }
        dismiss()
        if !saved { model.showToast(.saveFailed) }
    }

    /// A decimal-pad key other than "." (a comma-decimal locale) typed at
    /// the end reads as "."; Flutter's formatter drops it (D6).
    static func decimalKey(old: String, new: String) -> String {
        guard let separator = Locale.current.decimalSeparator, separator != ".", new == old + separator,
            !old.contains(".")
        else { return new }
        return old + "."
    }
}

// MARK: - Type toggle

/// `_TypeToggle` as a compact segmented control: Asset (green, north-east
/// arrow) and Liability (rose, south-west arrow), 44pt wide segments on the
/// field fill with a card border. The selected one fills with its colour,
/// arrow on-accent; the names are VoiceOver labels (the banner, the arrow
/// tile and the Save pill also follow the type). Every tap ticks, as
/// Flutter.
private struct TypeToggle: View {
    @Binding var type: NetWorthEntryType
    let onTap: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: Metrics.spacingXXS) {
            segment(.asset, "Asset", symbol: "arrow.up.right", color: BudgieColor.income)
            segment(.liability, "Liability", symbol: "arrow.down.left", color: BudgieColor.danger)
        }
        .padding(3)
        .background(BudgieColor.fieldFill, in: shape)
        .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
    }

    private func segment(_ value: NetWorthEntryType, _ title: String, symbol: String, color: Color) -> some View {
        let selected = type == value
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button {
            onTap()
            type = value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(selected ? BudgieColor.onAccent : BudgieColor.textSecondary)
                .frame(width: Metrics.touchTarget, height: 38)
                .background(selected ? color : Color.clear, in: shape)
                // 38pt tall inside the 3pt inset; the tap area is 44.
                .tapArea(vertical: 3)
        }
        .buttonStyle(.plain)
        .motion(Motion.easeInOut(0.22), value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(value == .asset ? "worth.editor.asset" : "worth.editor.liability")
    }
}

// MARK: - Month grid

/// The balance month picker: a year stepper (1970 to this year) over the
/// twelve months; months after this one are disabled, as Flutter's picker
/// ends on the last day of this month. On the field fill; the selected
/// month in the selection fill. Built from integers and `DartCalendar`,
/// never `Date` or `DatePicker`.
private struct BalanceMonthGrid: View {
    let selected: DartDateTime
    let now: DartDateTime
    let calendar: DartCalendar
    let pick: (DartDateTime) -> Void

    @State private var year: Int

    init(selected: DartDateTime, now: DartDateTime, calendar: DartCalendar, pick: @escaping (DartDateTime) -> Void) {
        self.selected = selected
        self.now = now
        self.calendar = calendar
        self.pick = pick
        _year = State(initialValue: min(max(selected.year, 1970), now.year))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: Metrics.spacingS) {
            HStack(spacing: 0) {
                stepButton("chevron.left", label: "Previous year", enabled: year > 1970) { year -= 1 }
                Text(DartDateFormat.y(calendar.date(year)))
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Year \(year)")
                stepButton("chevron.right", label: "Next year", enabled: year < now.year) { year += 1 }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.spacingS), count: 4), spacing: Metrics.spacingS) {
                ForEach(1...12, id: \.self) { month in
                    monthButton(calendar.date(year, month))
                }
            }
        }
        .padding(10)
        .background(BudgieColor.fieldFill, in: shape)
        .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
    }

    private func monthButton(_ month: DartDateTime) -> some View {
        let isSelected = month.year == selected.year && month.month == selected.month
        let enabled = month.year < now.year || month.month <= now.month
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            pick(month)
        } label: {
            Text(DartDateFormat.MMM(month))
                .textStyle(isSelected ? WorthStyle.chipBold : WorthStyle.chip)
                .foregroundStyle(
                    isSelected ? BudgieColor.selectionText : enabled ? BudgieColor.textPrimary : BudgieColor.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(isSelected ? BudgieColor.selectionFill : Color.clear, in: shape)
                // The cell draws 36pt tall; the tap area is 44.
                .tapArea(vertical: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(DartDateFormat.yMMMM(month))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? BudgieColor.textSecondary : BudgieColor.textTertiary)
                .frame(width: Metrics.touchTarget, height: 32)
                // 32pt tall; the tap area is 44.
                .tapArea(vertical: 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
