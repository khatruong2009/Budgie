import BudgieCore
import os
import SwiftUI

/// Every transaction, filterable: the page Flow's "SEE ALL" pushes (Flutter
/// `_TransactionsDetailPage`, history_page.dart:1248-2119). The title and
/// the shared-month pill sit in the navigation bar beside the native back
/// button (D2), then the filters card, the results summary, and the matches
/// newest first, 50 at a time.
///
/// Differences from Flutter (PARITY_GAPS): rows open the edit form and swipe
/// to delete (D7), and picking a month also sets the From/To filters to that
/// month (D6; Flutter's pill changes only the shared month). The pill is
/// dimmed, and the month is not ticked, while From/To are not exactly that
/// month (D6).
///
/// The filtered rows and their summary are cached and recomputed only when
/// the filter or `model.ledgerRevision` changes, never per body pass.
struct FlowTransactionsView: View {
    @Environment(AppModel.self) private var model

    @State private var filter = TransactionFilter()
    @State private var pagination = FilterPagination()
    /// The amount fields' text, kept as typed (`_minAmountController`).
    @State private var minText = ""
    @State private var maxText = ""
    /// nil until the first filter pass, so no empty state flashes.
    @State private var results: FilterResults?
    @State private var sheet: FilterSheet?
    @State private var editing: TransactionRecord?
    @State private var pendingDelete: TransactionRecord?
    @State private var rowTaps = 0
    @State private var selections = 0

    /// `rowSubtitle` at 13 ("Showing ... matches").
    private static let smallText = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)
    /// Material `TextButton` label (14/w500).
    private static let loadMoreText = TextSpec(face: .gabaritoMedium, size: 14, relativeTo: .subheadline)

    var body: some View {
        let ledger = model.ledger
        let formatter = model.moneyFormatter

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FiltersCard(
                    filter: $filter, minText: $minText, maxText: $maxText, tags: model.tags,
                    currencySymbol: AmountInput.currencySymbol(formatter)
                ) { sheet = $0 }
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, 12)

                if let results {
                    resultsHeader(results, total: ledger.newestFirst.count, formatter: formatter)
                        .padding(.horizontal, Metrics.pageHorizontal)
                        .padding(.top, Metrics.spacingM)
                    resultRows(results, formatter: formatter)
                }
            }
            .padding(.bottom, Metrics.spacingL)
            .frame(maxWidth: Metrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        // A decimal pad has no return key; Flutter offers no way out either.
        .scrollDismissesKeyboard(.interactively)
        .background(BudgieColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(BudgieColor.background, for: .navigationBar)
        .toolbar {
            // Beside the back button, as Flutter lays out its header row; a
            // centred title would slide aside whenever the month is long.
            BarItem(placement: .topBarLeading) {
                Text("Transactions")
                    .textStyle(.sectionHeader)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            if !ledger.availableMonths.isEmpty {
                let month = model.selectedMonth
                let applied = filter.isLimited(toMonth: month, calendar: model.calendar)
                BarItem(placement: .topBarTrailing) {
                    MonthPill(label: DartDateFormat.MMMM(month), dimmed: !applied) { sheet = .month }
                        .accessibilityLabel("Month")
                        .accessibilityValue(DartDateFormat.yMMMM(month) + (applied ? "" : ", not filtering the list"))
                        .accessibilityIdentifier("flow.all.month")
                }
            }
        }
        .onChange(of: FilterKey(filter: filter, revision: model.ledgerRevision), initial: true) { _, _ in refilter() }
        .onChange(of: minText) { _, text in filter.minAmount = AmountInput.parse(text, formatter: model.moneyFormatter) }
        .onChange(of: maxText) { _, text in filter.maxAmount = AmountInput.parse(text, formatter: model.moneyFormatter) }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .sheet(item: $editing) { record in
            TransactionFormView(mode: .edit(record))
        }
        .deleteTransactionAlert(pending: $pendingDelete)
        .sensoryFeedback(.impact(weight: .light), trigger: rowTaps)
        .sensoryFeedback(.selection, trigger: selections)
    }

    // MARK: - State

    /// `_getFilteredTransactions` + `_buildFilteredSummary`, and the visible
    /// count's reset when the filter signature changed (`hp:1285-1298`).
    private func refilter() {
        pagination.sync(filter)
        let state = Signpost.ui.beginInterval("flow.refilter")
        let rows = filter.apply(model.ledger)
        results = FilterResults(rows: rows, summary: TransactionFilter.summary(rows))
        Signpost.ui.endInterval("flow.refilter", state, "matches=\(rows.count, privacy: .public)")
    }

    /// The 'SELECT MONTH' choice: the shared month (Flutter) and, fixing the
    /// Flutter page that never filtered by it (D6), From/To set to the
    /// month's first and last day.
    private func pickMonth(_ month: DartDateTime) {
        filter.limit(toMonth: month, calendar: model.calendar)
        model.selectMonth(month)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: FilterSheet) -> some View {
        switch sheet {
        case .category:
            let names = model.ledger.categoryNames
            let current = filter.category
            PickerSheet(
                title: "SELECT CATEGORY",
                options: [PickerOption(title: "All categories", selected: current == nil)]
                    + names.map { name in
                        PickerOption(title: name, selected: current.map { $0.utf16.elementsEqual(name.utf16) } ?? false)
                    },
                maxListHeight: nil
            ) { index in
                selections += 1
                filter.category = index == 0 ? nil : names[index - 1]
            }
        case .month:
            let months = model.ledger.availableMonths
            let calendar = model.calendar
            // Ticked only while the list is limited to that month (D6).
            PickerSheet(
                title: "SELECT MONTH",
                options: months.map {
                    PickerOption(title: DartDateFormat.yMMMM($0), selected: filter.isLimited(toMonth: $0, calendar: calendar))
                },
                maxListHeight: 320
            ) { index in
                selections += 1
                pickMonth(months[index])
            }
        case .from, .to:
            let isStart = sheet == .from
            let now = model.now
            let range = TransactionFilter.pickerRange(now: now, calendar: model.calendar)
            DayPickerSheet(
                initial: filter.pickerInitialDate(isStart: isStart, now: now), earliest: range.lowerBound,
                latest: range.upperBound, calendar: model.calendar
            ) { day in
                if isStart { filter.setFrom(day) } else { filter.setTo(day) }
            }
        }
    }

    // MARK: - Results

    /// 'Results' with "{matches} of {all}", then the three summary pills
    /// over every match (`hp:2036-2076`).
    private func resultsHeader(_ results: FilterResults, total: Int, formatter: MoneyFormatter) -> some View {
        let summary = results.summary
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingS) {
                Text("Results")
                    .textStyle(.sectionHeader)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TransactionFilter.countText(matches: summary.count, total: total))
                    .textStyle(.monoLabel)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .accessibilityIdentifier("flow.all.count")
            }
            .padding(.horizontal, Metrics.spacingXS)
            ChipWrap(spacing: Metrics.spacingS) {
                PillChip(label: summary.incomeText(formatter), color: BudgieColor.income)
                PillChip(label: summary.expensesText(formatter), color: BudgieColor.danger)
                PillChip(label: summary.netText(formatter), color: summary.netIsPositive ? BudgieColor.income : BudgieColor.danger)
            }
        }
    }

    /// The matches as one list card built lazily (each row draws its slice
    /// of the card), or the empty card, then 'Load more' while more match.
    /// The empty card is the shared dashed one (REDESIGN_PLAN 4.5) with
    /// Flutter's message: "No Results Found" while a filter is active, else
    /// "No Transactions Yet" (Flutter shows only the message).
    @ViewBuilder
    private func resultRows(_ results: FilterResults, formatter: MoneyFormatter) -> some View {
        let count = results.rows.count
        if count == 0 {
            Group {
                if filter.isActive {
                    EmptyStateView(kind: .noResults, message: filter.emptyMessage)
                } else {
                    EmptyStateView(
                        kind: .noData, symbol: "tray", title: MonthListCopy.noTransactionsTitle, message: filter.emptyMessage)
                }
            }
            .accessibilityIdentifier("flow.all.empty")
            .padding(.top, Metrics.spacingM)
        } else {
            let visible = Array(results.rows.prefix(pagination.visible(of: count)))
            let lastID = visible.last?.id
            // Keyed by transaction id, like Home's list and the Spend
            // drill-in (ids are unique: loading gives duplicates fresh ones),
            // so a row keeps its own swipe state when the matches change.
            ForEach(visible) { row in
                let isFirst = row.id == visible[0].id
                ResultCell(
                    row: row, isFirst: isFirst, isLast: row.id == lastID, formatter: formatter,
                    info: model.categoryInfo(named: row.record.category, type: row.record.type)
                ) {
                    rowTaps += 1
                    editing = row.record
                } onDelete: {
                    pendingDelete = row.record
                }
                .padding(.top, isFirst ? Metrics.spacingM : 0)
            }
            if pagination.hasMore(count) {
                VStack(spacing: Metrics.spacingS) {
                    Text(TransactionFilter.showingText(visible: visible.count, matches: count))
                        .textStyle(Self.smallText)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .accessibilityIdentifier("flow.all.showing")
                    Button("Load more transactions") { pagination.loadMore() }
                        .textStyle(Self.loadMoreText)
                        .foregroundStyle(BudgieColor.accent)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 64, minHeight: 40)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flow.all.loadMore")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
        }
    }
}

// MARK: - State types

private struct FilterResults {
    let rows: [LedgerRow]
    let summary: TransactionFilter.Summary
}

private struct FilterKey: Equatable {
    let filter: TransactionFilter
    let revision: Int
}

private enum FilterSheet: String, Identifiable {
    case category, month, from, to
    var id: String { rawValue }
}

// MARK: - Navigation bar

/// A navigation bar item without the bar's own glass capsule around it
/// (iOS 26), for the title and the month pill, which draw their own.
private struct BarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement, content: content)
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement, content: content)
        }
    }
}

// MARK: - Filters card

/// `_buildFiltersCard` (`hp:1521-1652`): 'Filters' (+ 'RESET' while any
/// filter is active), search, type, category, tags, From/To, Min/Max.
private struct FiltersCard: View {
    @Binding var filter: TransactionFilter
    @Binding var minText: String
    @Binding var maxText: String
    let tags: [TransactionTagRecord]
    let currencySymbol: String
    let open: (FilterSheet) -> Void

    @State private var resets = 0

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Metrics.spacingS) {
                    Text("Filters")
                        .textStyle(.cardTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if filter.isActive {
                        Button {
                            resets += 1
                            minText = ""
                            maxText = ""
                            filter.reset()
                        } label: {
                            // The text is about 14pt tall; the tap area is 44.
                            Text("RESET").textStyle(.monoLink).foregroundStyle(BudgieColor.accent)
                                .tapArea(horizontal: 6, vertical: 15)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reset filters")
                        .accessibilityIdentifier("flow.all.reset")
                    }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: resets)

                SearchField(text: $filter.searchText, showsClear: !filter.query.isEmpty)
                    .padding(.top, 14)

                SegmentedPills(items: TransactionFilter.Kind.allCases.map(\.label), selection: kindIndex)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Type")
                    .accessibilityIdentifier("flow.all.type")
                    .padding(.top, 12)

                FilterButton(label: "Category", value: filter.categoryButtonValue, symbol: "square.grid.2x2") { open(.category) }
                    .accessibilityIdentifier("flow.all.category")
                    .padding(.top, 12)

                if !tags.isEmpty {
                    tagChips.padding(.top, 12)
                }

                // Flutter leads these with the chevron as well as trailing it.
                HStack(spacing: 12) {
                    FilterButton(label: "From", value: TransactionFilter.dateButtonValue(filter.from), symbol: "chevron.down") {
                        open(.from)
                    }
                    .accessibilityIdentifier("flow.all.from")
                    FilterButton(label: "To", value: TransactionFilter.dateButtonValue(filter.to), symbol: "chevron.down") {
                        open(.to)
                    }
                    .accessibilityIdentifier("flow.all.to")
                }
                .padding(.top, 12)

                HStack(spacing: 12) {
                    AmountField(label: "Min amount", identifier: "flow.all.min", text: $minText, currencySymbol: currencySymbol)
                    AmountField(label: "Max amount", identifier: "flow.all.max", text: $maxText, currencySymbol: currencySymbol)
                }
                .padding(.top, 12)
            }
        }
    }

    private var kindIndex: Binding<Int> {
        Binding(
            get: { TransactionFilter.Kind.allCases.firstIndex(of: filter.kind) ?? 0 },
            set: { filter.kind = TransactionFilter.Kind.allCases[$0] })
    }

    /// 'All tags' then one chip per tag in provider order; a selected tag's
    /// chip clears the filter when tapped again. No haptic (Flutter).
    private var tagChips: some View {
        ChipWrap(spacing: Metrics.spacingS) {
            tagChip("All tags", selected: filter.tagId == nil) { filter.tagId = nil }
            ForEach(tags) { tag in
                let selected = filter.tagId.map { $0.utf16.elementsEqual(tag.id.utf16) } ?? false
                tagChip(tag.name, selected: selected) { filter.tagId = selected ? nil : tag.id }
            }
        }
    }

    /// A filter chip (REDESIGN_PLAN 4.7): selected in the selection fill
    /// with a check, otherwise outlined in the card border.
    private func tagChip(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
                }
                Text(name).textStyle(.labelSmall)
            }
            .foregroundStyle(selected ? BudgieColor.selectionText : BudgieColor.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, Metrics.spacingS)
            .background(selected ? BudgieColor.selectionFill : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? BudgieColor.selectionBorder : BudgieColor.cardBorder, lineWidth: 1))
            // The chip draws about 34pt tall; the tap area is 44.
            .tapArea(vertical: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The search field (`hp:1654-1695`) in the field style (REDESIGN_PLAN
/// 4.1): field fill, radius 16, 1pt card border (2pt accent while focused),
/// the grid glyph Flutter uses as its prefix, and a minus button that
/// clears it while the query is non-blank.
private struct SearchField: View {
    @Binding var text: String
    let showsClear: Bool

    @FocusState private var focused: Bool

    /// `rowTitle` at w400 for the hint.
    private static let hint = TextSpec(face: .gabaritoRegular, size: 15, height: 1.25, relativeTo: .body)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
        HStack(spacing: 0) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BudgieColor.textSecondary)
                .frame(width: 48)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            TextField(
                "Search descriptions", text: $text,
                prompt: Text("Search descriptions").font(Self.hint.font()).foregroundStyle(BudgieColor.textSecondary)
            )
            .textStyle(.rowTitle)
            .foregroundStyle(BudgieColor.textPrimary)
            .submitLabel(.search)
            .focused($focused)
            // The whole 56pt field, so the text field's own element is not
            // a 19pt target; the text stays centred.
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Search descriptions")
            .accessibilityIdentifier("flow.all.search")
            if showsClear {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(BudgieColor.textSecondary)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
        }
        .frame(minHeight: 56)
        // The rest of the field focuses it; the text field keeps its own
        // touches (caret, selection menu).
        .background(FocusArea(shape: shape) { focused = true })
        .overlay(
            shape.strokeBorder(
                focused ? BudgieColor.accent : BudgieColor.cardBorder,
                lineWidth: focused ? Metrics.borderThick : Metrics.borderThin))
    }
}

/// A field's fill, which focuses the field when tapped outside its text
/// field (the padding, the icon or the label); placed behind the text field
/// so the text field's own touches never reach it.
private struct FocusArea<S: Shape>: View {
    let shape: S
    let focus: () -> Void

    var body: some View {
        shape.fill(BudgieColor.fieldFill)
            .contentShape(shape)
            .onTapGesture(perform: focus)
            .accessibilityHidden(true)
    }
}

/// `_buildFilterButton` (`hp:1749-1812`): min height 56, field fill,
/// radius 16, leading glyph, small label over the value, trailing chevron.
/// Light haptic.
private struct FilterButton: View {
    let label: String
    let value: String
    let symbol: String
    let action: () -> Void

    /// `rowSubtitle` at 11.
    private static let labelText = TextSpec(face: .gabaritoRegular, size: 11, height: 1.25, relativeTo: .caption2)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
        HapticButton(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BudgieColor.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text(label).textStyle(Self.labelText).foregroundStyle(BudgieColor.textSecondary)
                    Text(value)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .singleLine()
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Metrics.spacingS)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BudgieColor.textSecondary)
                    .padding(.leading, Metrics.spacingXS)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(BudgieColor.fieldFill, in: shape)
            .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        // On the Button itself, so VoiceOver keeps its activation.
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// `_buildAmountField` (`hp:1720-1747`): a decimal field whose label sits
/// inside until it floats (focused or non-empty), when the currency prefix
/// appears, as Material shows `prefixText`. The prefix is the base
/// currency's symbol (D6; Flutter hard-codes "$ ").
private struct AmountField: View {
    let label: String
    let identifier: String
    @Binding var text: String
    let currencySymbol: String

    @FocusState private var focused: Bool

    /// `rowSubtitle` (the resting label) and its floated size.
    private static let restingLabel = TextSpec(face: .gabaritoRegular, size: 12, height: 1.25, relativeTo: .caption)
    private static let floatingLabel = TextSpec(face: .gabaritoRegular, size: 11, height: 1.25, relativeTo: .caption2)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
        let floated = focused || !text.isEmpty
        VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
            if floated {
                Text(label)
                    .textStyle(Self.floatingLabel)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .singleLine()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                if floated {
                    Text(currencySymbol + " ")
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField(
                    label, text: $text,
                    // Floated, no hint: a nil prompt would show the label
                    // again inside the field, beside the currency prefix.
                    prompt: floated
                        ? Text("") : Text(label).font(Self.restingLabel.font()).foregroundStyle(BudgieColor.textSecondary)
                )
                .textStyle(.rowTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .focused($focused)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Metrics.spacingS)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(FocusArea(shape: shape) { focused = true })
        .overlay(
            shape.strokeBorder(
                focused ? BudgieColor.accent : BudgieColor.cardBorder,
                lineWidth: focused ? Metrics.borderThick : Metrics.borderThin))
        .motion(Motion.easeOut(Motion.fast), value: floated)
    }
}

// MARK: - Result rows

/// One row of the results list card: its slice of the card (top corners on
/// the first row, bottom corners on the last, a hairline inset 12 between
/// rows) around the swipe-to-delete row, which slides within the row's own
/// rounded shape so it never leaves the card. The card's padding includes
/// its 1pt border, as `GlowListCard`'s does.
private struct ResultCell: View {
    let row: LedgerRow
    let isFirst: Bool
    let isLast: Bool
    let formatter: MoneyFormatter
    let info: CategoryInfo?
    let onTap: () -> Void
    let onDelete: () -> Void

    private static let inset = Metrics.listCardPadding + Metrics.borderThin

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Hairline().padding(.horizontal, Metrics.hairlineInset) }
            SwipeToDeleteRow(onDelete: onDelete) {
                ResultRow(row: row, formatter: formatter, info: info, action: onTap)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, isFirst ? Self.inset : 0)
        .padding(.bottom, isLast ? Self.inset : 0)
        .background { CardSlice(isFirst: isFirst, isLast: isLast) }
        .padding(.horizontal, Metrics.pageHorizontal)
    }
}

/// The part of a `GlowListCard` (radius 22, card fill, 1pt border) behind
/// one row: the whole card shape stretched past the row's open edges and
/// clipped to it, so the slices join into one card. It takes no touches:
/// the clip does not limit hit testing, so the stretched shape would
/// otherwise catch touches meant for the neighbouring rows wherever the
/// lazy stack drew it above them (dead taps and swipes).
private struct CardSlice: View {
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        let overhang = Metrics.cardRadius * 2
        shape
            .fill(BudgieColor.card)
            .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
            .padding(.top, isFirst ? 0 : -overhang)
            .padding(.bottom, isLast ? 0 : -overhang)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `_TransactionRow` (`hp:1057-1129`) as a SEE ALL row: the category's tile
/// (`FlowCategoryTile`), description over "{category} · {MMM d}", the
/// signed amount (income green, expense in the text colour). Tapping opens
/// the edit form (D7).
private struct ResultRow: View {
    let row: LedgerRow
    let formatter: MoneyFormatter
    let info: CategoryInfo?
    let action: () -> Void

    var body: some View {
        let record = row.record
        let isIncome = record.type == .income
        let amount = row.flowAmountText(formatter)
        Button(action: action) {
            TransactionRowLayout(
                // A blank description keeps its line, as in Flutter.
                title: record.description.isEmpty ? " " : record.description, isRecurring: record.isRecurring,
                subtitle: row.flowSubtitle, amount: amount,
                amountColor: isIncome ? BudgieColor.income : BudgieColor.textPrimary
            ) {
                FlowCategoryTile(info: info, isIncome: isIncome)
            }
            // Covers the swipe's delete backdrop while the row is at rest.
            .background(BudgieColor.card, in: RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the Button itself, so VoiceOver keeps its activation.
        .accessibilityLabel(
            "\(record.description.isEmpty ? "Transaction" : record.description), \(record.category), \(DartDateFormat.yMMMMd(record.date)), \(amount)"
                + (record.isRecurring ? ", recurring" : "")
        )
        .accessibilityHint("Double tap to edit, swipe left to delete")
        .accessibilityIdentifier("flow.all.row")
    }
}

// MARK: - Picker sheet

private struct PickerOption {
    let title: String
    let selected: Bool
}

/// The 'SELECT CATEGORY' / 'SELECT MONTH' sheets (`hp:1847-2017`) in the
/// sheet pattern (REDESIGN_PLAN 4.3): the eyebrow, then the options as rows
/// in a card with hairlines between them (selected: bold, accent check). A
/// pick calls `onPick` and closes the sheet. Sized to its content, at most
/// 9/16 of the screen (Material's default); `maxListHeight` caps the list
/// (months: 320).
private struct PickerSheet: View {
    let title: String
    let options: [PickerOption]
    let maxListHeight: CGFloat?
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetHostHeight) private var hostHeight
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.eyebrow)
                .foregroundStyle(BudgieColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal + 4, bottom: 12, trailing: Metrics.pageHorizontal))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChangeCompat { headerHeight = $0.height }
            GlowCard(padding: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options.indices, id: \.self) { index in
                            if index > 0 { Hairline() }
                            OptionRow(
                                title: options[index].title, selected: options[index].selected, boldWhenSelected: true,
                                hidesCheckFromVoiceOver: false, fillsWidth: true, explicitLabel: true,
                                identifier: "flow.all.option"
                            ) {
                                onPick(index)
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.spacingM)
                    .padding(.vertical, Metrics.spacingXXS)
                    .onGeometryChangeCompat { listHeight = $0.height }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxListHeight)
            }
            .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .budgieSheetChrome()
        .presentationDetents([detent])
    }

    /// Handle, header, the card (list plus its border) and 16, at most 9/16
    /// of the screen; the system adds the bottom safe area. Until measured,
    /// the default-size header (12 + eyebrow + 12) and the rows (48pt, 1pt
    /// hairlines, 2 + 2) stand in, so the sheet opens at its final height.
    private var detent: PresentationDetent {
        let header = headerHeight > 0 ? headerHeight : 12 + 14 + 12
        let rows = listHeight > 0 ? listHeight : CGFloat(options.count) * 49 - 1 + 4
        let natural = BudgetSheetLayout.handleHeight + header + min(rows, maxListHeight ?? .infinity) + 2 + Metrics.spacingM
        return .height(min(natural, hostHeight * 9 / 16))
    }
}

// MARK: - Wrap layout

/// Flutter `Wrap(spacing:, runSpacing:)` with equal spacings: children left
/// to right, a new run when the next one does not fit, runs top-aligned.
private struct ChipWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, runHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += runHeight + spacing
                runHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            runHeight = max(runHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + runHeight))
    }
}
