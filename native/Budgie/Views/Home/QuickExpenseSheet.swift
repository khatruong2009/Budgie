import BudgieCore
import SwiftUI

/// The category list opened by long-pressing Home's add button
/// (`_showQuickCategoryPicker`, spending_page.dart:314-335, 689-803):
/// "Add expense", then one row per expense category. Choosing one hands
/// its name to `onChoose`; the caller opens the expense form with it once
/// this sheet has gone.
struct QuickExpenseSheet: View {
    let onChoose: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choices = 0

    /// The sheet blurb (REDESIGN_PLAN 4.3: 14 secondary).
    private static let blurb = TextSpec(face: .gabaritoRegular, size: 14, height: 1.35, relativeTo: .subheadline)

    var body: some View {
        let categories = model.categories(for: .expense)
        VStack(alignment: .leading, spacing: 0) {
            Text("Add expense")
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(EdgeInsets(top: 8, leading: Metrics.pageHorizontal, bottom: 4, trailing: Metrics.pageHorizontal))
            Text("Choose a category, then enter the amount and description.")
                .textStyle(Self.blurb)
                .foregroundStyle(BudgieColor.textSecondary)
                .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: 14, trailing: Metrics.pageHorizontal))
            ScrollView {
                // The rows in one field-style group (`fieldFill`, radius 16,
                // 1pt card border), hairlines between them.
                let shape = RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                LazyVStack(spacing: 0) {
                    ForEach(categories.indices, id: \.self) { index in
                        if index > 0 {
                            Hairline().padding(.leading, 64)
                        }
                        row(categories[index])
                    }
                }
                .background(BudgieColor.fieldFill, in: shape)
                .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
                .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .budgieSheetChrome()
        .presentationDetents([.fraction(0.66), .fraction(0.9)])
        .sensoryFeedback(.selection, trigger: choices)
    }

    private func row(_ category: CategoryInfo) -> some View {
        Button {
            choices += 1
            onChoose(category.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                IconTile(category: category)
                Text(category.name)
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .singleLine()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BudgieColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Choose \(category.name)")
        .accessibilityAddTraits(.isButton)
    }
}
