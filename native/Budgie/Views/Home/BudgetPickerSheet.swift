import BudgieCore
import SwiftUI

// MARK: - Picker sheets

/// The EDIT and Add a budget pickers (`_showBudgetCategorySheet`,
/// spending_page.dart:221-312) in the sheet pattern (REDESIGN_PLAN 4.3): the
/// title, the blurb, then the categories as list rows in one card.
/// Content-sized up to 75% of the screen height; the system adds the bottom
/// safe area outside the cap, as Flutter's `SafeArea` does.
struct BudgetPickerSheet: View {
    enum Kind { case edit, add }

    let kind: Kind
    /// The section's overview for this render (kept live while open).
    let overview: FinancialData.BudgetOverview
    let onPick: (String) -> Void
    let onAdd: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.sheetHostHeight) private var hostHeight
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let categories = kind == .edit ? overview.budgeted : overview.unbudgeted
        // `showAddRow: budgeted.length < expenseCategories.length` (EDIT only).
        let showsAddRow = kind == .edit && !overview.unbudgeted.isEmpty
        let formatter = model.moneyFormatter
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .sheetTitleStyle()
                Text(subtitle(hasBudgets: !categories.isEmpty))
                    .textStyle(.sheetBlurb)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 16, trailing: Metrics.pageHorizontal))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChangeCompat { headerHeight = $0.height }
            ScrollView {
                GlowCard(padding: Metrics.listCardPadding) {
                    VStack(spacing: 0) {
                        ForEach(categories) { info in
                            if info.id != categories.first?.id { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                            categoryRow(info, formatter: formatter)
                        }
                        if showsAddRow {
                            if !categories.isEmpty { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                            BudgetPickerRow(
                                tile: IconTile(symbol: "plus", color: BudgieColor.accent), title: "Add a budget",
                                titleColor: BudgieColor.accent, lineLimit: nil, action: onAdd)
                        }
                    }
                }
                .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: 16, trailing: Metrics.pageHorizontal))
                .onGeometryChangeCompat { listHeight = $0.height }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .budgieSheetChrome()
        .presentationDetents([detent(rows: categories.count + (showsAddRow ? 1 : 0))])
    }

    /// Handle, header and list, at most 75% of the screen. Until measured,
    /// the default-size header (12 + title + 6 + blurb + 16) and the card
    /// (8 + 64pt rows with 1pt hairlines + 8, border 2, then 16) stand in,
    /// so the sheet opens at its final height.
    private func detent(rows: Int) -> PresentationDetent {
        let header = headerHeight > 0 ? headerHeight : 12 + 29 + 6 + 17 + 16
        let list = listHeight > 0 ? listHeight : 8 + CGFloat(rows) * 64 + CGFloat(max(rows - 1, 0)) + 8 + 2 + 16
        return .height(min(BudgetSheetLayout.handleHeight + header + list, hostHeight * 0.75))
    }

    /// The category's tile and "$X limit" when budgeted (the Add sheet has no subtitle).
    private func categoryRow(_ info: CategoryInfo, formatter: MoneyFormatter) -> some View {
        let limit = kind == .edit ? overview.limit(for: info.name) : nil
        return BudgetPickerRow(
            tile: IconTile(category: info), title: info.name,
            subtitle: limit.flatMap { $0 > 0 ? "\(formatter.format($0, decimalDigits: 0)) limit" : nil }
        ) { onPick(info.name) }
        .accessibilityIdentifier("budgets.picker.\(info.name)")
    }

    private var title: String { kind == .edit ? "Edit budgets" : "Add a budget" }

    private func subtitle(hasBudgets: Bool) -> String {
        switch kind {
        case .edit:
            hasBudgets
                ? "Tap a budget to change or remove its monthly limit."
                : "No monthly limits yet. Add one to start tracking a category."
        case .add: "Choose a category to set a monthly limit."
        }
    }
}

/// A picker row: `_EditBudgetCategoryTile` (spending_page.dart:1876-1946) or
/// `_AddBudgetRow` (:1819-1873); tile, title, optional subtitle, chevron;
/// light haptic.
private struct BudgetPickerRow: View {
    let tile: IconTile
    let title: String
    var titleColor = BudgieColor.textPrimary
    var subtitle: String?
    var lineLimit: Int? = 1
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text(title).textStyle(.rowTitle).foregroundStyle(titleColor).lineLimit(lineLimit)
                    if let subtitle {
                        Text(subtitle).textStyle(.rowSubtitle).foregroundStyle(BudgieColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // `Symbols.chevron_right_rounded` 20, weight 500, tertiary.
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BudgieColor.textTertiary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 1))
    }
}
