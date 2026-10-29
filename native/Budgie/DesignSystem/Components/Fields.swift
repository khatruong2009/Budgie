import SwiftUI

/// Text field in the redesign's field style (REDESIGN_PLAN 4.1): `fieldFill`,
/// radius 16, a 1pt card-border stroke that turns 2pt accent while focused
/// (2pt danger with an error), optional 20pt leading symbol, input in
/// rowTitle, error text in danger below.
///
/// - `.labeled`: the caption w600 title above a 52pt field (dialogs).
/// - `.inline`: no visible title, a 46pt field (the add form's Description);
///   the title is still the accessibility label.
/// - `.amount`: a 64pt field, radius 18, with the title inside at the top
///   left and the figure right-aligned at 36pt after `prefix` (the currency
///   symbol) at 24pt (the add form's Amount).
struct BudgieField: View {
    enum Style { case labeled, inline, amount }

    let title: String
    @Binding var text: String
    var prompt: String = ""
    var symbol: String? = nil
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .sentences
    var error: String? = nil
    /// Focuses the field when it appears (the transaction form's amount).
    var autofocus = false
    var style: Style = .labeled
    /// `.amount` only: the text before the figure (the currency symbol).
    var prefix: String? = nil
    /// The text field's own accessibility identifier (an identifier on the
    /// whole `BudgieField` lands on its container, not the field).
    var identifier: String? = nil

    @FocusState private var focused: Bool

    private static let amountLabel = TextSpec(face: .gabaritoSemiBold, size: 13, relativeTo: .footnote)
    private static let amountPrefix = TextSpec(face: .gabaritoBold, size: 24, relativeTo: .title2)
    private static let amountValue = TextSpec(
        face: .gabaritoExtraBold, size: 36, tracking: -1.08, tabular: true, relativeTo: .largeTitle)

    var body: some View {
        let hasError = error != nil
        VStack(alignment: .leading, spacing: 6) {
            if style == .labeled {
                Text(title)
                    .textStyle(.captionStrong)
                    .foregroundStyle(hasError ? BudgieColor.danger : focused ? BudgieColor.accent : BudgieColor.textSecondary)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
            Group {
                if style == .amount { amountBox } else { textBox }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if let error {
                FieldErrorLabel(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(error.map { Text("Error: \($0)") } ?? Text(""))
    }

    private var textBox: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(BudgieColor.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            input.textStyle(.rowTitle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: style == .inline ? 46 : 52)
        .modifier(FieldBox(radius: Metrics.fieldRadius, focused: focused, error: error != nil))
    }

    private var amountBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .textStyle(Self.amountLabel)
                .foregroundStyle(error != nil ? BudgieColor.danger : BudgieColor.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            AmountValueLayout(spacing: prefix == nil ? 0 : 6) {
                if let prefix {
                    Text(prefix)
                        .textStyle(Self.amountPrefix)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .accessibilityHidden(true)
                }
                input
                    .textStyle(Self.amountValue)
                    .multilineTextAlignment(.trailing)
            }
            .lineLimit(1)
            .frame(minHeight: 64)
        }
        .padding(.horizontal, 16)
        .modifier(FieldBox(radius: 18, focused: focused, error: error != nil))
    }

    private var input: some View {
        TextField(title, text: $text, prompt: Text(prompt).foregroundStyle(BudgieColor.textTertiary))
            .foregroundStyle(BudgieColor.textPrimary)
            .tint(BudgieColor.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled(keyboard == .decimalPad || keyboard == .numberPad)
            .focused($focused)
            // A prompt replaces the title as the field's label.
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier ?? "")
            .onAppear { if autofocus { focused = true } }
    }
}

/// Hugs short amounts, but reserves the currency symbol's full width when
/// a long amount or Dynamic Type fills the field. Only the input compresses;
/// TextField then scrolls its value without squeezing the label or prefix.
private struct AmountValueLayout: Layout {
    let spacing: CGFloat

    private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [ViewDimensions] {
        guard let input = subviews.last else { return [] }
        let prefix = subviews.count > 1 ? subviews[0].dimensions(in: .unspecified) : nil
        let reserved = prefix.map { $0.width + spacing } ?? 0
        let idealWidth = input.sizeThatFits(.unspecified).width
        let width = min(idealWidth, max(0, (proposal.width ?? (reserved + idealWidth)) - reserved))
        let value = input.dimensions(in: ProposedViewSize(width: width, height: proposal.height))
        return prefix.map { [$0, value] } ?? [value]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = dimensions(proposal, subviews)
        let baseline = sizes.map { $0[.firstTextBaseline] }.max() ?? 0
        let descent = sizes.map { $0.height - $0[.firstTextBaseline] }.max() ?? 0
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + (sizes.count > 1 ? spacing : 0),
                      height: baseline + descent)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = dimensions(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        let baseline = sizes.map { $0[.firstTextBaseline] }.max() ?? 0
        var x = bounds.minX
        for (view, size) in zip(subviews, sizes) {
            view.place(at: CGPoint(x: x, y: bounds.minY + baseline - size[.firstTextBaseline]),
                       anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
        }
    }
}

/// The field box: `fieldFill` and a 1pt card border, 2pt accent while
/// focused, 2pt danger with an error.
private struct FieldBox: ViewModifier {
    let radius: CGFloat
    let focused: Bool
    let error: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let stroke = error ? BudgieColor.danger : focused ? BudgieColor.accent : BudgieColor.cardBorder
        content
            .background(BudgieColor.fieldFill, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: focused || error ? Metrics.borderThick : Metrics.borderThin))
    }
}

/// A form's one-line row (REDESIGN_PLAN 4.1: the add form's Category, Date
/// and Tags): at least 48pt tall, radius 16, `fieldFill`, 1pt card border
/// (2pt danger with `error`); a label column at least 64pt wide (13 w600
/// secondary, with an optional 11pt `note` such as "Optional" beneath),
/// the content, and an optional trailing symbol. With `action` it is a
/// button with a light haptic; without one it is plain (a `Menu` label).
/// Callers set the accessibility (one element, label and value).
struct FormRow<Content: View>: View {
    let label: String
    var note: String? = nil
    var trailingSymbol: String? = nil
    var error = false
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @ScaledMetric(relativeTo: .footnote) private var labelWidth = Metrics.formLabelWidth
    var body: some View {
        if let action {
            HapticButton(action: action) {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .textStyle(FormRowText.label)
                    .foregroundStyle(error ? BudgieColor.danger : BudgieColor.textSecondary)
                if let note {
                    Text(note).textStyle(FormRowText.note).foregroundStyle(BudgieColor.textSecondary)
                }
            }
            .fixedSize()
            .frame(minWidth: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(error ? BudgieColor.danger : BudgieColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.formRowHeight)
        .background(BudgieColor.fieldFill, in: shape)
        .overlay(shape.strokeBorder(error ? BudgieColor.danger : BudgieColor.cardBorder, lineWidth: error ? Metrics.borderThick : Metrics.borderThin))
        .contentShape(shape)
    }
}

private enum FormRowText {
    static let label = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.15, relativeTo: .footnote)
    static let note = TextSpec(face: .gabaritoRegular, size: 11, height: 1.15, relativeTo: .caption2)
}

/// Date row (`_DatePickerTile`) as a `FormRow`: the label in the label
/// column, the value 15 w600, a trailing calendar symbol (or the Worth
/// editor's `chevron.down`). With `error` the label and border turn danger
/// (the recurring form's start date). One accessibility element, a button
/// named by the label with the date as its value.
struct DateTile: View {
    let label: String
    let value: String
    var trailingSymbol = "calendar"
    var error = false
    let action: () -> Void

    var body: some View {
        FormRow(label: label, trailingSymbol: trailingSymbol, error: error, action: action) {
            Text(value).textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }
}

/// Empty state (REDESIGN_PLAN 4.5): a card with a 1.5pt dashed border
/// (`textTertiary` at 60%), radius 22, padding 36 / 24, centred: a 72pt
/// tile (accent at 12%, `danger` for `.error`) with a 32pt symbol, the
/// title 21 w800, the message 15 secondary (at most 280 wide), and an
/// optional 48pt filled pill. `horizontalInset` is the space outside the
/// card on each side (the page margin by default; 0 inside a padded page).
struct EmptyStateView: View {
    enum Kind { case noData, noResults, error }

    var kind: Kind = .noData
    var symbol: String? = nil
    var title: String? = nil
    var message: String? = nil
    var actionTitle: String? = nil
    var actionSymbol: String? = "plus"
    var actionIdentifier: String? = nil
    var horizontalInset: CGFloat = Metrics.pageHorizontal
    var action: (() -> Void)? = nil

    private static let titleText = TextSpec(face: .gabaritoExtraBold, size: 21, tracking: -0.2, relativeTo: .title3)
    private static let messageText = TextSpec(face: .gabaritoRegular, size: 15, height: 1.45, relativeTo: .subheadline)

    var body: some View {
        let tint = kind == .error ? BudgieColor.danger : BudgieColor.accent
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        VStack(spacing: 12) {
            Image(systemName: symbol ?? defaultSymbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text(title ?? defaultTitle)
                .textStyle(Self.titleText)
                .foregroundStyle(BudgieColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            Text(message ?? defaultMessage)
                .textStyle(Self.messageText)
                .foregroundStyle(BudgieColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if let actionTitle, let action {
                PillButton(title: actionTitle, symbol: actionSymbol, filled: true, height: 48, action: action)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(actionIdentifier ?? "")
                    .padding(.top, 8)
            }
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay(shape.strokeBorder(BudgieColor.textTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .padding(.horizontal, horizontalInset)
        .accessibilityElement(children: .contain)
    }

    private var defaultSymbol: String {
        switch kind {
        case .noData: "tray"
        case .noResults: "magnifyingglass"
        case .error: "exclamationmark.triangle"
        }
    }

    private var defaultTitle: String {
        switch kind {
        case .noData: "No Data Yet"
        case .noResults: "No Results Found"
        case .error: "Something Went Wrong"
        }
    }

    private var defaultMessage: String {
        switch kind {
        case .noData: "Get started by adding your first item"
        case .noResults: "Try adjusting your search or filters"
        case .error: "We encountered an error. Please try again"
        }
    }
}

/// The error line under a field: a danger exclamation and the message in
/// `caption`, inset 4.
struct FieldErrorLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13)).accessibilityHidden(true)
            Text(text).textStyle(.caption)
        }
        .foregroundStyle(BudgieColor.danger)
        .padding(.leading, 4)
    }
}

/// A field's caption above it (`captionStrong`, secondary, inset 4).
struct FieldCaption: View {
    let text: String
    var isHeader = false
    var hidden = false

    init(_ text: String, isHeader: Bool = false, hidden: Bool = false) {
        self.text = text
        self.isHeader = isHeader
        self.hidden = hidden
    }

    var body: some View {
        Text(text)
            .textStyle(.captionStrong)
            .foregroundStyle(BudgieColor.textSecondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(isHeader ? .isHeader : [])
            .accessibilityHidden(hidden)
    }
}
