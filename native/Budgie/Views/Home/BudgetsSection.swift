import BudgieCore
import SwiftUI
import UIKit

/// Home's Budgets section (spending_page.dart:597-627): the section header
/// with its Edit link, then a tile per budget in two columns (one at
/// accessibility text sizes) and, while a category has no budget, the
/// dashed Add button. Owns the budget sheets: the Edit and Add pickers and
/// the limit sheet.
struct BudgetsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: BudgetSheet?
    /// Opens once `sheet` has finished dismissing: Flutter awaits the
    /// picker's pop, then pushes the next sheet (never stacked).
    @State private var nextSheet: BudgetSheet?

    var body: some View {
        // One pass per render for the card and both pickers.
        let overview =
            model.budgetOverview(forMonth: model.selectedMonth)
        // Dart `budgets.length < expenseCategories.length`: the rows are the
        // budgeted expense categories, so this holds iff one is unbudgeted.
        let showsAddRow = !overview.unbudgeted.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Budgets", link: "Edit") { sheet = .edit }
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(overview.progress, id: \.category) { item in
                    BudgetTile(
                        item: item, info: model.categoryInfo(named: item.category, type: .expense),
                        formatter: model.moneyFormatter
                    ) {
                        sheet = .limit(category: item.category, current: model.budgetLimit(for: item.category))
                    }
                }
            }
            if showsAddRow {
                AddBudgetButton(hint: HomeSummary.addBudgetSubtitle(hasBudgets: !overview.progress.isEmpty)) { sheet = .add }
                    .accessibilityIdentifier("home.budgets.add")
            }
        }
        .padding(.horizontal, Metrics.pageHorizontal)
        .sheet(item: $sheet, onDismiss: presentNextSheet) { item in
            switch item {
            case .edit:
                BudgetPickerSheet(kind: .edit, overview: overview, onPick: openLimit(after:), onAdd: { chain(.add) })
            case .add:
                BudgetPickerSheet(kind: .add, overview: overview, onPick: openLimit(after:), onAdd: {})
            case .limit(let category, let current):
                BudgetLimitSheet(category: category, currentLimit: current, formatter: model.moneyFormatter)
            }
        }
    }

    /// A picker's category pick: close the picker, then the limit sheet.
    private func openLimit(after category: String) {
        chain(.limit(category: category, current: model.budgetLimit(for: category)))
    }

    private func chain(_ next: BudgetSheet) {
        nextSheet = next
        sheet = nil
    }

    private func presentNextSheet() {
        guard let next = nextSheet else { return }
        nextSheet = nil
        sheet = next
    }
}

private enum BudgetSheet: Identifiable {
    case edit, add
    /// The limit is captured when the sheet opens (`currentLimit`).
    case limit(category: String, current: Double?)

    var id: String {
        switch self {
        case .edit: "edit"
        case .add: "add"
        case .limit(let category, _): "limit-\(category)"
        }
    }
}

// MARK: - Tiles

/// One budget (`_BudgetRow`, spending_page.dart:1587-1701): a status-coloured
/// ring around the category symbol with the share used, then the name, the
/// left/over amount and "spent of limit". Tap opens the limit sheet with a
/// light haptic; no press scale.
private struct BudgetTile: View {
    let item: BudgetProgress
    let info: CategoryInfo?
    let formatter: MoneyFormatter
    let action: () -> Void

    private static let percentText = TextSpec(face: .monoMedium, size: 12, tabular: true, relativeTo: .caption)
    private static let chipText = TextSpec(face: .monoSemiBold, size: 13, tabular: true, relativeTo: .footnote)
    private static let subtitleText = TextSpec(face: .monoRegular, size: 11, tabular: true, relativeTo: .caption)

    var body: some View {
        let color = statusColor
        let (subtitle, chip) = HomeSummary.budgetRow(item, formatter: formatter)
        let shape = RoundedRectangle(cornerRadius: Metrics.statCardRadius, style: .continuous)
        HapticButton(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ProgressRing(value: item.progress, size: 46, thickness: 5, color: color) {
                        Image(systemName: CategoryCatalog.symbol(for: info?.iconIdentifier ?? ""))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(color)
                    }
                    .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .textStyle(Self.percentText)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .singleLine()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.category)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .singleLine()
                    Text(chip)
                        .textStyle(Self.chipText)
                        .foregroundStyle(item.status == .over ? BudgieColor.danger : BudgieColor.textPrimary)
                        .singleLine()
                    Text(subtitle)
                        .textStyle(Self.subtitleText)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .singleLine()
                }
            }
            .padding(Metrics.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BudgieColor.card, in: shape)
            .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle(scale: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.category), \(subtitle), \(chip)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the monthly limit")
        .accessibilityIdentifier("home.budgets.row.\(item.category)")
    }

    /// `_statusColor`: over is danger, from 85% warning, else income green.
    private var statusColor: Color {
        switch item.status {
        case .over: BudgieColor.danger
        case .warning: BudgieColor.warning
        case .ok: BudgieColor.income
        }
    }
}

/// The dashed "Add a budget" button under the tiles; `hint` is the
/// subtitle Flutter shows under the row.
private struct AddBudgetButton: View {
    let hint: String
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HapticButton(action: action) {
            HStack(spacing: Metrics.spacingS) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(BudgieColor.accent)
                Text("Add a budget").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(shape.strokeBorder(BudgieColor.textTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityHint(hint)
    }
}

/// `_AddBudgetRow` (spending_page.dart:1819-1873) in the Edit picker:
/// accent plus tile, "Add a budget" and a chevron.
struct AddBudgetRow: View {
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: "plus", color: BudgieColor.accent)
                Text("Add a budget")
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BudgetChevron()
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 1))
    }
}

/// `Symbols.chevron_right_rounded` 20, weight 500, tertiary.
struct BudgetChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(BudgieColor.textTertiary)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}
