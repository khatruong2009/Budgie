import SwiftUI

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
/// Home's hero; the Worth hero passes `heroMedium`. `hidden` (hidden
/// balances) shows `text` as plain, single-line text instead: dots have no
/// digits to roll.
struct RollingAmount: View {
    let text: String
    let color: Color
    let style: TextSpec
    let hidden: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var fontSize: CGFloat
    @State private var natural: CGSize = .zero
    @State private var available: CGFloat = 0
    @State private var rowWidth: CGFloat?

    init(text: String, color: Color, style: TextSpec = .hero, hidden: Bool = false) {
        self.text = text
        self.color = color
        self.style = style
        self.hidden = hidden
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        if hidden {
            Text(text)
                .textStyle(style)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            rolling
        }
    }

    @ViewBuilder private var rolling: some View {
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
