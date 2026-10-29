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
                VStack(spacing: 4) {
                    Text("CASH FLOW")
                        .textStyle(.eyebrow)
                        .foregroundStyle(BudgieColor.textSecondary)
                    Group {
                        if formatter.hideBalances {
                            // Dots have no digits to roll.
                            Text(amount)
                                .textStyle(Self.amountText)
                                .foregroundStyle(isNegative ? BudgieColor.danger : BudgieColor.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        } else {
                            RollingAmount(
                                text: amount, color: isNegative ? BudgieColor.danger : BudgieColor.textPrimary,
                                style: Self.amountText)
                        }
                    }
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

// MARK: - Rolling odometer

/// The hero amount as an odometer (`AnimatedDigitWidget`, animated_digit
/// 3.3.2): one cell per character of the formatted label, so the currency
/// prefix/suffix and separators come from the formatter. Each digit is a
/// clipped vertical reel that only rolls forward (upward), taking
/// `c > n ? 10 - c + n : n - c` steps, all cells together over 900ms
/// easeInOut; an unchanged digit stays still. On first appearance every
/// digit rolls up from 0, and when the label's shape (length or any
/// non-digit character) changes the cells are rebuilt and roll from 0 while
/// the row eases to its new width. Rolls the rounded label (Flutter's
/// widget truncates the fraction, so its digits can be 0.01 off the
/// semantics). Scales down as a whole when it is wider than the space.
/// Reduce Motion shows the digits without rolling. `style` defaults to
/// Home's hero; the Worth hero passes `heroMedium`.
struct RollingAmount: View {
    let text: String
    let color: Color
    let style: TextSpec

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var fontSize: CGFloat
    @State private var natural: CGSize = .zero
    @State private var available: CGFloat = 0
    @State private var rowWidth: CGFloat?

    init(text: String, color: Color, style: TextSpec = .hero) {
        self.text = text
        self.color = color
        self.style = style
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        let rowHeight = style.lineHeight(scaledSize: fontSize)
        let skeleton = Self.skeleton(of: text)
        let animation: Animation? = reduceMotion ? nil : Motion.easeInOut(0.9)
        let measured = natural.width > 0 && available > 0
        let scale = measured ? min(1, available / natural.width) : 1

        VStack(spacing: 0) {
            // The width on offer is read from a view that only fills what it is
            // proposed. Reading it from the frame below, whose width follows its
            // content, froze the amount at whatever scale the first (transient)
            // layout gave it: a third of its size at accessibility text sizes.
            Color.clear.frame(height: 0).onGeometryChangeCompat { available = $0.width }
            ZStack {
                HStack(spacing: 0) {
                    ForEach(Self.cells(of: text, skeleton: skeleton), id: \.id) { cell in
                        Group {
                            if let digit = cell.digit {
                                DigitReel(digit: digit, style: style, rowHeight: rowHeight, animation: animation)
                            } else {
                                Text(String(cell.character))
                                    .textStyle(style)
                                    .fixedSize()
                                    .frame(height: rowHeight)
                            }
                        }
                        .transition(.identity)
                    }
                }
                .foregroundStyle(color)
                .fixedSize()
                .onGeometryChangeCompat { size in
                    // Flutter's `AnimatedSize`: a rebuilt row eases to its new
                    // width, clipped, over the same 900ms.
                    if rowWidth == nil || animation == nil {
                        rowWidth = size.width
                    } else if rowWidth != size.width {
                        withAnimation(animation) { rowWidth = size.width }
                    }
                }
                .frame(width: rowWidth)
                // Clips sideways only: a "$" may reach past the 1.0 line box.
                .mask { Rectangle().padding(.vertical, -rowHeight / 2) }
            }
            .fixedSize()
            .onGeometryChangeCompat { natural = $0 }
            .scaleEffect(scale)
            .frame(width: measured ? natural.width * scale : nil, height: measured ? natural.height * scale : nil)
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        // Each reel is an 11-row strip that `clipped()` hides but does not
        // stop from hit-testing: offset by its digit, a strip reaches up over
        // the month pill and wheel and swallows their touches.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Cell {
        let id: String
        let character: Character
        let digit: Int?
    }

    /// The label with every ASCII digit replaced by "0": cells are rebuilt
    /// (and roll from 0) only when this changes.
    static func skeleton(of text: String) -> String {
        String(text.map { $0.isASCII && $0.isNumber ? "0" : $0 })
    }

    private static func cells(of text: String, skeleton: String) -> [Cell] {
        text.enumerated().map { index, character in
            let digit = character.isASCII ? character.wholeNumberValue : nil
            return Cell(id: "\(skeleton)#\(index)", character: character, digit: digit)
        }
    }
}

/// One odometer digit: a strip of 0-9 plus a trailing 0, clipped to one
/// row and offset by a monotonic `position` (mod 10), so rolling past 9
/// wraps seamlessly. Only the strip's transform animates.
private struct DigitReel: View {
    let digit: Int
    let style: TextSpec
    let rowHeight: CGFloat
    let animation: Animation?

    @State private var position: Double

    init(digit: Int, style: TextSpec, rowHeight: CGFloat, animation: Animation?) {
        self.digit = digit
        self.style = style
        self.rowHeight = rowHeight
        self.animation = animation
        // A new reel starts at 0 and rolls up on appear; without animation
        // it starts at its digit so nothing flashes.
        _position = State(initialValue: animation == nil ? Double(digit) : 0)
    }

    var body: some View {
        Text(verbatim: "0")
            .textStyle(style)
            .fixedSize()
            .hidden()
            .frame(height: rowHeight)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(0..<11, id: \.self) { row in
                        Text(verbatim: String(row % 10))
                            .textStyle(style)
                            .fixedSize()
                            .frame(height: rowHeight)
                    }
                }
                .modifier(ReelOffset(position: position, rowHeight: rowHeight))
            }
            .clipped()
            .onAppear { roll(to: digit) }
            .onChange(of: digit) { _, new in roll(to: new) }
    }

    /// Forward only: `c > n ? 10 - c + n : n - c` steps.
    private func roll(to new: Int) {
        let current = Int(position.rounded()) % 10
        let steps = (new - current + 10) % 10
        guard steps > 0 else { return }
        withAnimation(animation) { position += Double(steps) }
    }
}

/// Moves the digit strip up by `position` rows (mod 10); animatable, so a
/// roll interpolates only this transform.
private struct ReelOffset: GeometryEffect {
    var position: Double
    let rowHeight: CGFloat

    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        let rows = position.truncatingRemainder(dividingBy: 10)
        return ProjectionTransform(CGAffineTransform(translationX: 0, y: -rows * rowHeight))
    }
}
