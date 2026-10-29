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
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(hasBudgets: !categories.isEmpty))
                    .textStyle(.sheetBlurb)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 12 + the chrome's 19pt handle inset.
            .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 16, trailing: Metrics.pageHorizontal))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChangeCompat { headerHeight = $0.height }
            ScrollView {
                GlowCard(padding: Metrics.listCardPadding) {
                    VStack(spacing: 0) {
                        ForEach(categories) { info in
                            if info.id != categories.first?.id { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                            BudgetCategoryTile(
                                info: info, limit: kind == .edit ? overview.limit(for: info.name) : nil,
                                formatter: formatter
                            ) { onPick(info.name) }
                        }
                        if showsAddRow {
                            if !categories.isEmpty { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                            AddBudgetRow(action: onAdd)
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

/// `_EditBudgetCategoryTile` (spending_page.dart:1876-1946): the category's
/// tile and "$X limit" for a budgeted category, no subtitle in the Add sheet;
/// chevron; light haptic.
private struct BudgetCategoryTile: View {
    let info: CategoryInfo
    let limit: Double?
    let formatter: MoneyFormatter
    let action: () -> Void

    var body: some View {
        let budgeted = (limit ?? 0) > 0
        HapticButton(action: action) {
            HStack(spacing: 12) {
                IconTile(category: info)
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text(info.name).textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary).lineLimit(1)
                    if budgeted, let limit {
                        Text("\(formatter.format(limit, decimalDigits: 0)) limit")
                            .textStyle(.rowSubtitle)
                            .foregroundStyle(BudgieColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                BudgetChevron()
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 1))
        .accessibilityIdentifier("budgets.picker.\(info.name)")
    }
}
