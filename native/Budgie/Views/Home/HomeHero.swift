import BudgieCore
import SwiftUI

/// Home's cash-flow hero: a ring of the month's income split into what was
/// spent and what was kept (the whole ring in danger when spending passed
/// income), the cash flow in whole units in the middle (never a sign;
/// danger when negative) over the share kept, then a legend with the exact
/// spent and kept (or short) amounts. The ring grows from 0 on first
/// appearance (instant under Reduce Motion) and scales with Dynamic Type.
struct HomeHero: View {
    let income: Double
    let expenses: Double
    let formatter: MoneyFormatter

    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 236

    /// The ring's figure.
    static let amountText = TextSpec(face: .gabaritoExtraBold, size: 44, tracking: -1.6, height: 1.0, tabular: true, relativeTo: .largeTitle)
    private static let legendAmount = TextSpec(face: .monoMedium, size: 13, height: 1.25, tabular: true, relativeTo: .footnote)

    var body: some View {
        let hero = HomeSummary.hero(income: income, expenses: expenses, formatter: formatter)
        let cashFlow = income - expenses
        let isNegative = hero.isNegative
        let size = min(ringSize, 320)
        let amount = formatter.format(abs(cashFlow), decimalDigits: 0)
        let kept = formatter.format(abs(cashFlow))
        let spent = formatter.format(expenses)

        VStack(spacing: 18) {
            ZStack {
                CashFlowRing(income: income, expenses: expenses, thickness: 16)
                    .frame(width: size, height: size)
                VStack(spacing: Metrics.spacingXS) {
                    Text("CASH FLOW")
                        .textStyle(.eyebrow)
                        .foregroundStyle(BudgieColor.textSecondary)
                    RollingAmount(
                        text: amount, color: isNegative ? BudgieColor.danger : BudgieColor.textPrimary,
                        style: Self.amountText, hidden: formatter.hideBalances)
                        // A fresh odometer each time balances are shown (it was a separate branch).
                        .id(formatter.hideBalances)
                    Text(status(cashFlow: cashFlow))
                        .textStyle(.noteStrong)
                        .foregroundStyle(
                            isNegative ? BudgieColor.danger : cashFlow > 0 ? BudgieColor.income : BudgieColor.textSecondary)
                        .singleLine()
                }
                // Inside the ring's hole.
                .frame(width: (size - 32) * 0.82)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hero.accessibilityLabel)

            RowOrColumn(rowSpacing: 18, columnSpacing: 6) {
                legend(spent: spent, kept: kept, isNegative: isNegative)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 0, trailing: 24))
    }

    /// "34% kept", "Short this month" or "Breaking even".
    private func status(cashFlow: Double) -> String {
        if cashFlow < 0 { return "Short this month" }
        if cashFlow == 0 || income <= 0 { return "Breaking even" }
        return "\(Int((cashFlow / income * 100).rounded()))% kept"
    }

    @ViewBuilder
    private func legend(spent: String, kept: String, isNegative: Bool) -> some View {
        legendItem("Spent", spent, dot: isNegative ? BudgieColor.danger : BudgieColor.spent)
        legendItem(isNegative ? "Short" : "Kept", kept, dot: isNegative ? BudgieColor.danger : BudgieColor.income)
    }

    private func legendItem(_ label: String, _ amount: String, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label).textStyle(.note).foregroundStyle(BudgieColor.textSecondary)
            Text(amount).textStyle(Self.legendAmount).foregroundStyle(BudgieColor.textPrimary)
        }
        .fixedSize()
    }
}

/// The hero's ring: a track, then the spent arc from 12 o'clock and the kept
/// arc after it, with round caps and a small gap at each join. Only one arc
/// (the whole ring) when nothing was spent, or when spending reached income
/// (in danger when it passed it); the bare track with no income.
private struct CashFlowRing: View {
    let income: Double
    let expenses: Double
    let thickness: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height) - thickness
            // Each join's visible gap is 6pt once the round caps are added.
            let gap = (6 + thickness) / (2 * .pi * diameter)
            let spentShare = income > 0 ? min(max(expenses / income, 0), 1) : (expenses > 0 ? 1 : 0)
            let t = appeared ? 1.0 : 0
            ZStack {
                Circle().stroke(BudgieColor.track, lineWidth: thickness)
                if income > 0 || expenses > 0 {
                    if spentShare <= gap * 2 {
                        arc(0, t, BudgieColor.income)
                    } else if spentShare >= 1 - gap * 2 {
                        arc(0, t, expenses > income ? BudgieColor.danger : BudgieColor.spent)
                    } else {
                        arc(gap, (spentShare - gap) * t, BudgieColor.spent)
                        arc(spentShare + gap, spentShare + gap + (1 - gap - spentShare - gap) * t, BudgieColor.income)
                    }
                }
            }
            .padding(thickness / 2)
        }
        .motion(Motion.ring, value: appeared)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true } else { withAnimation(Motion.ring) { appeared = true } }
        }
        .accessibilityHidden(true)
    }

    private func arc(_ from: Double, _ to: Double, _ color: Color) -> some View {
        Circle()
            .trim(from: from, to: max(from, to))
            .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}
