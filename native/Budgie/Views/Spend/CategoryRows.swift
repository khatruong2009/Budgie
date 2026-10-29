import BudgieCore
import SwiftUI

/// One child of the Spend list card: a ranked category, the collapsed tail
/// ("N more categories") or the "Show less" row. None of them press-scale
/// (Flutter `GestureDetector`s); the list owner plays the light impact,
/// since "Show less" is gone by the time a haptic here would fire.
struct SpendListRow: View {
    enum Kind {
        case record(CategoryBreakdown.Record, symbol: String, highlighted: Bool)
        case tail(CategoryBreakdown.Tail)
        case collapse
    }

    let kind: Kind
    let formatter: MoneyFormatter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch kind {
            case .record(let record, let symbol, let highlighted):
                CategoryRow(record: record, symbol: symbol, highlighted: highlighted, formatter: formatter)
            case .tail(let tail):
                TailRow(tail: tail, formatter: formatter)
            case .collapse:
                CollapseRow()
            }
        }
        .buttonStyle(PressScaleStyle(scale: 1))
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch kind {
        case .record(let record, _, _): "spend.row.\(record.rank)"
        case .tail: "spend.tail"
        case .collapse: "spend.showLess"
        }
    }
}

/// `_buildCategoryRow` (category_page.dart:286-387) as a list row
/// (REDESIGN_PLAN 4.7): tile in the rank colour, name over "N transactions
/// · P%" (plus the limit note), the whole-unit amount, then a 6pt bar
/// against the largest category, under the text. The selected slice's row
/// (ranks 0...5) takes its colour at 10% (Flutter: 14% dark, 8% light),
/// fading in over 200 ms.
private struct CategoryRow: View {
    let record: CategoryBreakdown.Record
    let symbol: String
    let highlighted: Bool
    let formatter: MoneyFormatter

    var body: some View {
        let color = record.palette.color
        let amount = formatter.format(record.amount, decimalDigits: 0)
        let subtitle = record.subtitle(money: formatter)
        VStack(alignment: .leading, spacing: 10) {
            SpendRowLine(
                tile: IconTile(symbol: symbol, color: color), title: record.name, subtitle: subtitle, amount: amount)
            GlowProgressBar(value: record.barFraction, height: 6, color: color)
                .padding(.leading, SpendRowLine.textInset)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            highlighted ? color.opacity(0.1) : .clear,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .motion(Motion.easeOut(0.2), value: highlighted)
        .padding(Metrics.spacingXXS)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.name), \(amount), \(subtitle)")
        .accessibilityHint("Shows this category's transactions")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// `_buildTailRow` (:389-463): a neutral "more" tile, "N more categories"
/// over the names, their total, and a bar in the remainder colour under the
/// text.
private struct TailRow: View {
    let tail: CategoryBreakdown.Tail
    let formatter: MoneyFormatter

    var body: some View {
        let amount = formatter.format(tail.total, decimalDigits: 0)
        VStack(alignment: .leading, spacing: 10) {
            SpendRowLine(
                tile: IconTile(symbol: "ellipsis", color: BudgieColor.textSecondary, background: BudgieColor.hairline),
                title: tail.title, subtitle: tail.subtitle, amount: amount)
            GlowProgressBar(value: tail.barFraction, height: 6, color: BudgieColor.trackSecondary)
                .padding(.leading, SpendRowLine.textInset)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tail.title), \(amount), \(tail.subtitle)")
        .accessibilityHint("Shows every category")
    }
}

/// `_buildCollapseRow` (:465-497): centred accent "Show less" and a chevron.
private struct CollapseRow: View {
    var body: some View {
        HStack(spacing: Metrics.spacingXS) {
            Text("Show less").textStyle(.monoLink)
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(BudgieColor.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

/// The shared top line (Home's Recent activity rows): the 40pt tile, 12,
/// title over subtitle (one line each), 8, the amount at its full width in
/// `amountSmall`.
private struct SpendRowLine: View {
    let tile: IconTile
    let title: String
    let subtitle: String
    let amount: String

    /// Where the text starts: the tile and its gap (the bars line up with
    /// it, as in the Spend mockup).
    static let textInset: CGFloat = 40 + 12

    var body: some View {
        HStack(spacing: 0) {
            tile
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(title)
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .singleLine()
                Text(subtitle)
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .singleLine()
            }
            .frame(minWidth: 56, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, Metrics.spacingS)
            // First pick of the row's width, so an ordinary amount is never
            // cut; one wider than the row truncates instead of widening the
            // page (Flutter overflows the screen there).
            Text(amount)
                .textStyle(.amountSmall)
                .foregroundStyle(BudgieColor.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }
}
