import BudgieCore
import SwiftUI

/// A Settings choice sheet (`_showChoiceSheet`, settings_page.dart:985-1035)
/// in the sheet pattern (REDESIGN_PLAN 4.3): the title in `sheetTitle` at
/// the leading edge, then the choices as rows in a card (hairlines between
/// them) with an accent check on the current value (none when the stored
/// value is not listed). Content-sized up to 75% of the screen, where the
/// list scrolls. No search and no haptics, as in Flutter. Picking a row (the
/// current one included, as Flutter re-fires the setter) awaits the setter,
/// then closes the sheet.
struct SettingsChoiceSheet<Value: Hashable & Sendable>: View {
    let title: String
    let choices: [SettingsChoice<Value>]
    let current: Value
    let onPick: (Value) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetHostHeight) private var hostHeight
    @State private var picking = false
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChangeCompat { headerHeight = $0.height }
            ScrollView {
                GlowCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(choices.indices, id: \.self) { index in
                            if index > 0 { Hairline() }
                            row(choices[index])
                        }
                    }
                    .padding(.horizontal, Metrics.spacingM)
                    .padding(.vertical, Metrics.spacingXXS)
                }
                .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: Metrics.spacingM, trailing: Metrics.pageHorizontal))
                .onGeometryChangeCompat { listHeight = $0.height }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .budgieSheetChrome()
        .presentationDetents([detent])
    }

    /// Handle, title and list, at most 75% of the screen; the system adds
    /// the bottom safe area (Flutter's `SafeArea`). Until measured, the
    /// default-size title (12 + 29 + 16) and 48pt rows stand in, so the
    /// sheet opens at its final height.
    private var detent: PresentationDetent {
        let header = headerHeight > 0 ? headerHeight : 12 + 29 + 16
        let list = listHeight > 0 ? listHeight : CGFloat(choices.count) * 49 + 6 + Metrics.spacingM
        return .height(min(BudgetSheetLayout.handleHeight + header + list, hostHeight * 0.75))
    }

    /// A row: the label (15 w600) and the 24pt check box, at least 48 tall.
    private func row(_ choice: SettingsChoice<Value>) -> some View {
        let isCurrent = choice.value == current
        return Button {
            guard !picking else { return }
            picking = true
            Task {
                await onPick(choice.value)
                dismiss()
            }
        } label: {
            HStack(spacing: 14) {
                Text(choice.label)
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
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
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
