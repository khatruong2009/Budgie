import BudgieCore
import SwiftUI

/// The Spend month picker (`_showMonthPicker`, category_page.dart:500-588)
/// in the sheet pattern (REDESIGN_PLAN 4.3): "Select month" in the sheet
/// title style, then one row per month with transactions (newest first,
/// `yMMMM`) in a card with hairlines between them, the card at most 320pt
/// tall before it scrolls. The selected month has an accent check. Picking
/// a month closes the sheet at once. Sized to the content; the system adds
/// the bottom safe area (Flutter's `SafeArea`).
struct SpendMonthSheet: View {
    let months: [DartDateTime]
    let selected: DartDateTime?
    let onPick: (DartDateTime) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select month")
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, 12)
            GlowCard(padding: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(months.indices, id: \.self) { index in
                            if index > 0 { Hairline() }
                            row(months[index])
                        }
                    }
                    .padding(.horizontal, Metrics.spacingM)
                    .padding(.vertical, Metrics.spacingXXS)
                    .onGeometryChangeCompat { listHeight = $0.height }
                }
                // The default-size rows until measured, so the sheet never
                // measures an empty list.
                .frame(height: min(listHeight > 0 ? listHeight : estimatedListHeight, Self.maxListHeight))
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(EdgeInsets(top: Metrics.spacingM, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChangeCompat { contentHeight = $0.height }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .budgieSheetChrome()
        .presentationDetents([.height(BudgetSheetLayout.handleHeight + (contentHeight > 0 ? contentHeight : estimatedHeight))])
        .accessibilityIdentifier("spend.monthSheet")
    }

    /// The rows at the default text size: 48pt each, 1pt hairlines, 2 + 2.
    private var estimatedListHeight: CGFloat {
        CGFloat(months.count) * 48 + CGFloat(max(months.count - 1, 0)) + 4
    }

    /// The content's height at the default text size (12, the title, 16,
    /// the list card and its border, 16), so the sheet opens at its final height instead
    /// of resizing once measured.
    private var estimatedHeight: CGFloat {
        12 + 29 + 16 + min(estimatedListHeight, Self.maxListHeight) + 2 + 16
    }

    /// A row: the month (15 w600) and the accent check on the selected one,
    /// at least 48 tall.
    private func row(_ month: DartDateTime) -> some View {
        let isSelected = selected.map { DartCalendar.isSameMonth($0, month) } ?? false
        return Button {
            onPick(month)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(DartDateFormat.yMMMM(month))
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BudgieColor.accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .frame(minHeight: Metrics.formRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("spend.month.\(DartDateFormat.yyyyMM(month))")
    }
}
