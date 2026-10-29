import SwiftUI

// MARK: - Sheet chrome

extension View {
    /// The redesign's bottom-sheet chrome (REDESIGN_PLAN 4.3): card fill, 1pt
    /// card border along the rounded top, 30pt top radius, a 38 x 5 grab
    /// handle in `hairline`. A sheet that does not span the window (a form
    /// sheet, on the Duo's inner display) is rounded on all corners and
    /// has no grab handle, which only a bottom sheet is dragged by; its
    /// inset stays, so detent maths is the same.
    /// Apply to the root view inside `.sheet`.
    func budgieSheetChrome(radius: CGFloat = Metrics.sheetRadius) -> some View {
        modifier(SheetChrome(radius: radius))
    }
}

private struct SheetChrome: ViewModifier {
    let radius: CGFloat
    @Environment(\.sheetHostSize) private var host
    @State private var sheetWidth: CGFloat = 0

    /// A bottom sheet is at most a few points narrower than the window (the
    /// floating inset); a form sheet is much narrower.
    private var isFormSheet: Bool { host.width > 0 && sheetWidth > 0 && host.width - sheetWidth > 32 }

    func body(content: Content) -> some View {
        let formSheet = isFormSheet
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Capsule()
                    .fill(BudgieColor.hairline)
                    .frame(width: 38, height: 5)
                    .opacity(formSheet ? 0 : 1)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .onGeometryChangeCompat { sheetWidth = $0.width }
                    .accessibilityHidden(true)
            }
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(radius)
            .presentationBackground {
                let bottom = formSheet ? radius : 0
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: radius, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                    topTrailingRadius: radius, style: .continuous)
                BudgieColor.card
                    .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: 1).padding(.bottom, formSheet ? 0 : -2))
                    .ignoresSafeArea()
            }
    }
}

// MARK: - Sheet sizing

/// Sizes the budget sheets to their content the way Flutter's
/// `MediaQuery` does: against the full window height (`sheetHostHeight`,
/// measured at the app root). A `.height` detent is the grab handle plus the
/// content: the system accounts for the bottom safe area (Flutter's
/// `SafeArea`) and the keyboard itself.
enum BudgetSheetLayout {
    /// `budgieSheetChrome`'s grab-handle inset: 10 + 4 + 6.
    static let handleHeight: CGFloat = 20
}

// MARK: - Pushed page title

extension View {
    /// A pushed page's title: the system title names the screen (VoiceOver,
    /// the back button of pages pushed above it), an inline bar stays visible
    /// on the background colour, and `style` draws the title as a header in
    /// the principal slot. `scales` lets a long title shrink to one line;
    /// `singleLine` keeps it to one line (`singleLine()`), wrapping only at
    /// the accessibility sizes.
    func budgiePushedTitle(
        _ title: String, style: TextSpec = .cardTitle, scales: Bool = false, singleLine: Bool = false
    ) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(BudgieColor.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PushedTitleText(title: title, style: style, scales: scales, singleLine: singleLine)
                }
            }
    }
}

private struct PushedTitleText: View {
    let title: String
    let style: TextSpec
    let scales: Bool
    let singleLine: Bool

    var body: some View {
        if scales {
            Text(title)
                .textStyle(style)
                .foregroundStyle(BudgieColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
        } else if singleLine {
            Text(title)
                .textStyle(style)
                .foregroundStyle(BudgieColor.textPrimary)
                .singleLine()
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(title)
                .textStyle(style)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - Floating action button inset

extension View {
    /// A bottom-trailing floating action button in a bottom safe-area inset
    /// (it follows the tab bar and clears the scroll content), `fabInset`
    /// from the trailing and bottom edges.
    func floatingActionInset<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            content()
                .padding(.trailing, Metrics.fabInset)
                .padding(.bottom, Metrics.fabInset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Sheet host

extension EnvironmentValues {
    /// The window's size, measured at the app root and following a fold
    /// (zero until measured). Sheets size themselves against it.
    @Entry var sheetHostSize: CGSize = .zero

    /// The window's height for capping a sheet, unbounded until measured.
    var sheetHostHeight: CGFloat { sheetHostSize.height > 0 ? sheetHostSize.height : .infinity }
}

extension View {
    /// Measures the window (safe areas included) and publishes it as
    /// `sheetHostSize` to everything below, sheets included.
    func budgieSheetHost() -> some View {
        modifier(SheetHost())
    }
}

private struct SheetHost: ViewModifier {
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .environment(\.sheetHostSize, size)
            .background { Color.clear.ignoresSafeArea().onGeometryChangeCompat { size = $0 } }
    }
}

// MARK: - Centred dialog

/// Where a `budgieDialog` card sits.
enum DialogPlacement: Hashable {
    /// Centred (Flutter `showDialog` with the `_DarkDialog` shell).
    case center
    /// Floating at the bottom, 20pt from the edges above the home indicator
    /// (a Flutter modal bottom sheet with a transparent background holding a
    /// GlowCard, e.g. the Goals actions sheet); drag it down to dismiss.
    case bottom
}

extension View {
    /// A card dialog over a dimmed scrim (Flutter `showDialog` with the
    /// Goals `_DarkDialog` shell: GlowCard padding 20, max width 500, inset
    /// 24/32; or, `.bottom`, a transparent modal bottom sheet). Presented
    /// above everything, including the tab bar. The card hugs its content
    /// and never grows past the space left by the safe area and the
    /// keyboard: a dialog puts the part that may scroll in a `DialogScroll`
    /// (Flutter's `Flexible(SingleChildScrollView)`) so its title and
    /// buttons stay in view. Tapping the scrim dismisses it unless the
    /// content sets `budgieDialogDismissDisabled(true)` (e.g. while saving)
    /// or the keyboard is moving the card (the tap was aimed at the card).
    /// `padding` 0 lets the content run to the border (the Worth editor's
    /// banner).
    func budgieDialog<Dialog: View>(
        isPresented: Binding<Bool>, padding: CGFloat = Metrics.cardPadding, placement: DialogPlacement = .center,
        @ViewBuilder content: @escaping () -> Dialog
    ) -> some View {
        modifier(DialogPresenter(isPresented: isPresented, padding: padding, placement: placement, dialog: content))
    }

    /// `budgieDialog` for a value: shown while `item` is non-nil, with the
    /// content built from that value (and rebuilt, with fresh state, for a
    /// new id). Setting `item` to nil, or tapping the scrim, closes it.
    ///
    /// Prefer this whenever the content depends on state set just before
    /// presenting: the item is read here, in the modifier's body, so the
    /// cover always gets the current value. A content closure that reads
    /// the presenting view's `@State` instead is evaluated outside that
    /// view's body and, unless something else re-rendered the view first,
    /// reads the value from before the tap: the Worth editor opened empty
    /// (a scrim over a zero-height card) that way.
    func budgieDialog<Item: Identifiable, Dialog: View>(
        item: Binding<Item?>, padding: CGFloat = Metrics.cardPadding, placement: DialogPlacement = .center,
        @ViewBuilder content: @escaping (Item) -> Dialog
    ) -> some View {
        modifier(ItemDialogPresenter(item: item, padding: padding, placement: placement, dialog: content))
    }

    /// Keeps a `budgieDialog` open when its scrim is tapped (the dialog's
    /// counterpart of `interactiveDismissDisabled`).
    func budgieDialogDismissDisabled(_ disabled: Bool = true) -> some View {
        preference(key: DialogDismissDisabledKey.self, value: disabled)
    }
}

/// `SwiftUI.` because BudgieCore has its own `PreferenceKey` (stored prefs).
private struct DialogDismissDisabledKey: SwiftUI.PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Every dialog card's drop shadow (blur 24, 12 down; black at .5 dark, .15
/// light), drawn by a card-shaped fill behind it. A
/// shadow applied to the card itself would shadow every field, label and
/// button inside it separately (SwiftUI shadows each layer of a view that
/// is not a compositing group), which haloed the whole form in light mode.
private struct DialogShadow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(BudgieColor.card)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.15), radius: 12, y: 12)
            .accessibilityHidden(true)
    }
}

private struct ItemDialogPresenter<Item: Identifiable, Dialog: View>: ViewModifier {
    @Binding var item: Item?
    let padding: CGFloat
    let placement: DialogPlacement
    let dialog: (Item) -> Dialog

    func body(content: Content) -> some View {
        // Read in this body, so a new item re-renders it and the cover gets
        // a closure holding the current value.
        let current = item
        content.modifier(
            DialogPresenter(
                isPresented: Binding(get: { current != nil }, set: { if !$0 { item = nil } }), padding: padding,
                placement: placement
            ) {
                current.map { dialog($0).id($0.id) }
            })
    }
}

private struct DialogPresenter<Dialog: View>: ViewModifier {
    @Binding var isPresented: Bool
    let padding: CGFloat
    let placement: DialogPlacement
    let dialog: () -> Dialog
    @State private var coverShown = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $coverShown) {
                DialogHost(padding: padding, placement: placement, dismiss: { isPresented = false }, dialog: dialog)
                    // A change of placement (the Goals actions sheet handing
                    // over to a dialog) plays the entrance again.
                    .id(placement)
                    .presentationBackground(.clear)
            }
            .onChange(of: isPresented, initial: true) { _, shown in
                // The cover appears without its slide; DialogHost animates.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { coverShown = shown }
            }
    }
}

private struct DialogHost<Dialog: View>: View {
    let padding: CGFloat
    let placement: DialogPlacement
    let dismiss: () -> Void
    let dialog: () -> Dialog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var dismissDisabled = false
    /// How far the bottom card has been dragged down.
    @State private var drag: CGFloat = 0
    @State private var cardHeight: CGFloat = 0
    /// The keyboard is showing, hiding or changing height, which moves the
    /// card: a scrim tap now was aimed at where the card just was (its
    /// buttons), not at the scrim, so it does not dismiss.
    @State private var keyboardMoving = false

    var body: some View {
        ZStack(alignment: placement == .bottom ? .bottom : .center) {
            BudgieColor.scrim.opacity(visible ? 1 : 0)
                .ignoresSafeArea()
                .onTapGesture { if !dismissDisabled && !keyboardMoving { dismiss() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Dismiss")
                .accessibilityHidden(dismissDisabled)
            // No scroll view and no measured height here: the card is laid
            // out at its content's size within the space offered, so it can
            // never be stuck at a stale (zero) height.
            GlowCard(padding: padding) { dialog() }
                .background { DialogShadow() }
                .frame(maxWidth: 500)
                .modifier(Placed(placement: placement, visible: visible, reduceMotion: reduceMotion, drag: drag))
                .onGeometryChangeCompat { cardHeight = $0.height }
                .gesture(placement == .bottom && !dismissDisabled ? dragToDismiss : nil)
                .accessibilityAddTraits(.isModal)
        }
        .onPreferenceChange(DialogDismissDisabledKey.self) { disabled in
            MainActor.assumeIsolated { dismissDisabled = disabled }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
            keyboardMoving = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
            keyboardMoving = false
        }
        .onAppear {
            let animation = placement == .bottom ? Motion.fastOutSlowIn(0.25) : Motion.easeOut(0.15)
            if reduceMotion { visible = true } else { withAnimation(animation) { visible = true } }
        }
    }

    /// Flutter's modal bottom sheet: follows the finger down and closes past
    /// half its height or on a downward fling (700pt/s).
    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { drag = max(0, $0.translation.height) }
            .onEnded { value in
                let flung = value.velocity.height > 700
                if flung || value.translation.height > cardHeight / 2 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? nil : Motion.easeOut(0.2)) { drag = 0 }
                }
            }
    }
}

/// The card's insets and entrance: centred ones scale up from 0.92 and fade
/// in; the bottom card slides up from below the screen (a fade under
/// Reduce Motion).
private struct Placed: ViewModifier {
    let placement: DialogPlacement
    let visible: Bool
    let reduceMotion: Bool
    let drag: CGFloat

    func body(content: Content) -> some View {
        switch placement {
        case .center:
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .scaleEffect(visible || reduceMotion ? 1 : 0.92)
                .opacity(visible ? 1 : 0)
        case .bottom:
            content
                .padding(EdgeInsets(top: 32, leading: Metrics.pageHorizontal, bottom: Metrics.pageHorizontal, trailing: Metrics.pageHorizontal))
                .offset(y: drag)
                .visualEffect { effect, proxy in
                    effect.offset(y: visible || reduceMotion ? 0 : proxy.size.height + 40)
                }
                .opacity(visible || !reduceMotion ? 1 : 0)
        }
    }
}

/// A dialog's centred title (`sheetTitle`, as the category editor).
struct DialogTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.sheetTitle)
            .foregroundStyle(BudgieColor.textPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A dialog's button pair: outlined Cancel, and the filled submit in
/// `color`, both 44 tall, 24 below the content above.
struct DialogButtons: View {
    let cancelId: String
    let submitTitle: String
    let submitId: String
    var color: Color = BudgieColor.accent
    var symbol: String? = nil
    /// The write is awaited: both buttons are inert and the submit spins.
    var busy = false
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PillButton(title: "Cancel", color: BudgieColor.textPrimary, height: 44, action: cancel)
                .disabled(busy)
                .accessibilityIdentifier(cancelId)
            PillButton(title: submitTitle, symbol: symbol, color: color, filled: true, height: 44, loading: busy, action: submit)
                .disabled(busy)
                .accessibilityIdentifier(submitId)
        }
        .padding(.top, 24)
    }
}

/// A dialog's scrolling section (Flutter's `Flexible(SingleChildScrollView)`):
/// as tall as its content while that fits, and only as tall as the room the
/// title, buttons and keyboard leave otherwise, scrolling. Sized by layout
/// (the scroll view's ideal height is its content's), never by a measured
/// height held in state.
struct DialogScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        FitToContent {
            ScrollView { content() }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Offers its one subview the proposed width and takes the subview's ideal
/// height, capped at the proposed height.
private struct FitToContent: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - Row or column

/// Its subviews in a row (vertically centred) when their ideal widths fit
/// the width offered, else in a leading-aligned column as wide as its
/// widest subview. `spreads` puts the row's leftover width between the
/// subviews (a title on the left, a control on the right). Unlike
/// `ViewThatFits` the same subviews are kept when it switches, so
/// VoiceOver and the accessibility audit follow them across Dynamic Type
/// sizes (ViewThatFits swaps in a new copy, which the audit reported as
/// "Dynamic Type partially unsupported", budgie-ou0.12).
struct RowOrColumn: Layout {
    var rowSpacing: CGFloat = 8
    var columnSpacing: CGFloat = 8
    var spreads = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowWidth = rowWidth(ideals)
        if fitsInRow(rowWidth, width: proposal.width) {
            let width = spreads ? max(proposal.width ?? rowWidth, rowWidth) : rowWidth
            return CGSize(width: width, height: ideals.map(\.height).max() ?? 0)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let height = sizes.map(\.height).reduce(0, +) + columnSpacing * CGFloat(max(sizes.count - 1, 0))
        let widest = sizes.map(\.width).max() ?? 0
        return CGSize(width: min(widest, proposal.width ?? widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowWidth = rowWidth(ideals)
        if fitsInRow(rowWidth, width: bounds.width) {
            let gap = rowSpacing + (spreads && ideals.count > 1 ? (bounds.width - rowWidth) / CGFloat(ideals.count - 1) : 0)
            var x = bounds.minX
            for (subview, size) in zip(subviews, ideals) {
                subview.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
                x += size.width + gap
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
                y += size.height + columnSpacing
            }
        }
    }

    private func rowWidth(_ ideals: [CGSize]) -> CGFloat {
        ideals.map(\.width).reduce(0, +) + rowSpacing * CGFloat(max(ideals.count - 1, 0))
    }

    private func fitsInRow(_ rowWidth: CGFloat, width: CGFloat?) -> Bool {
        guard let width else { return true }
        return rowWidth <= width + 0.5
    }
}

// MARK: - Recurrence glyph

/// The recurring-transaction mark (`RecurrenceIndicator`): two arcs with
/// arrowheads forming an elongated oval, 1.5pt round strokes, 16 x 9.6.
struct RecurrenceGlyph: View {
    var size: CGFloat = 16
    var color: Color = BudgieColor.textSecondary

    var body: some View {
        RecurrenceShape()
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size * 0.6)
            .accessibilityLabel("Recurring")
    }
}

struct RecurrenceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        let centerY = rect.minY + height / 2
        let leftX = rect.minX + width * 0.1, rightX = rect.minX + width * 0.9
        let arrow = width * 0.18
        var path = Path()
        path.move(to: CGPoint(x: leftX + arrow * 0.5, y: centerY))
        path.addCurve(
            to: CGPoint(x: rightX - arrow * 0.5, y: centerY),
            control1: CGPoint(x: leftX + arrow * 0.5, y: rect.minY + height * 0.05),
            control2: CGPoint(x: rightX - arrow * 0.5, y: rect.minY + height * 0.05))
        path.move(to: CGPoint(x: rightX - arrow, y: centerY - arrow * 0.5))
        path.addLine(to: CGPoint(x: rightX, y: centerY))
        path.addLine(to: CGPoint(x: rightX - arrow, y: centerY + arrow * 0.5))
        path.move(to: CGPoint(x: rightX - arrow * 0.5, y: centerY))
        path.addCurve(
            to: CGPoint(x: leftX + arrow * 0.5, y: centerY),
            control1: CGPoint(x: rightX - arrow * 0.5, y: rect.minY + height * 0.95),
            control2: CGPoint(x: leftX + arrow * 0.5, y: rect.minY + height * 0.95))
        path.move(to: CGPoint(x: leftX + arrow, y: centerY - arrow * 0.5))
        path.addLine(to: CGPoint(x: leftX, y: centerY))
        path.addLine(to: CGPoint(x: leftX + arrow, y: centerY + arrow * 0.5))
        return path
    }
}

// MARK: - Swipe to delete

/// A card row that reveals a delete action when swiped left (Flutter
/// `Dismissible` on the transaction list): past 40% of the width (at most
/// 163pt, see `maxArmDistance`) a medium haptic marks the threshold, and
/// releasing there (or a leftward fling faster than 700pt/s, Flutter's
/// minimum fling velocity) calls `onDelete`
/// (which confirms) while the row springs back. Also offered as an
/// accessibility action, since the gesture is not discoverable with
/// VoiceOver.
///
/// On iOS 18+ the drag is a UIKit pan that only begins for a leftward,
/// mostly horizontal movement and that the enclosing scroll view waits for,
/// so a vertical drag still scrolls and, once the pan begins, the touch is
/// cancelled for the row's own button (no tap fires). A SwiftUI drag inside
/// a scroll view does neither there. iOS 17 keeps the SwiftUI drag, which
/// coexists with scrolling on that release.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var armed = false
    @State private var flings = 0

    /// 40% of the widest iPhone row (a 440pt screen less 16pt gutters), so
    /// a wide row (the Duo's open display) arms at a phone's distance.
    private static var maxArmDistance: CGFloat { 163.2 }

    var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
                    .fill(BudgieColor.danger)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "trash")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.trailing, 24)
                    }
                    .accessibilityHidden(true)
            }
            content()
                .offset(x: offset)
                // On the row's own element (the stack is not one), so
                // VoiceOver offers "Delete" there.
                .accessibilityAction(named: "Delete", onDelete)
        }
        .onGeometryChangeCompat { width = max($0.width, 1) }
        .modifier(SwipeGesture(onChanged: dragChanged, onEnded: dragEnded))
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new }
        .sensoryFeedback(.impact(weight: .medium), trigger: flings)
    }

    private func dragChanged(_ translation: CGFloat) {
        offset = min(0, translation)
        let past = -offset > min(width * 0.4, Self.maxArmDistance)
        if past != armed { armed = past }
    }

    /// `cancelled` (the system took the touch) never deletes.
    private func dragEnded(cancelled: Bool, velocity: CGSize) {
        let flung = velocity.width < -700 && abs(velocity.width) > abs(velocity.height)
        let delete = !cancelled && (armed || flung)
        if delete && !armed { flings += 1 }
        armed = false
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { offset = 0 }
        if delete { onDelete() }
    }
}

/// Attaches the row's horizontal drag (see `SwipeToDeleteRow`).
private struct SwipeGesture: ViewModifier {
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ cancelled: Bool, _ velocity: CGSize) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(LeftwardPan(onChanged: onChanged, onEnded: onEnded))
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        onChanged(value.translation.width)
                    }
                    .onEnded { value in onEnded(false, value.velocity) }
            )
        }
    }
}

/// A pan that begins only for a leftward, mostly horizontal movement and
/// that any scroll view pan must wait for.
@available(iOS 18.0, *)
private struct LeftwardPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ cancelled: Bool, _ velocity: CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            onEnded(false, CGSize(width: velocity.x, height: velocity.y))
        case .cancelled, .failed: onEnded(true, .zero)
        default: break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            var motion = pan.translation(in: pan.view)
            if motion == .zero { motion = pan.velocity(in: pan.view) }
            return motion.x < 0 && abs(motion.x) > abs(motion.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView && other is UIPanGestureRecognizer
        }
    }
}

extension View {
    /// Reports this view's size (a PreferenceKey reader; `onGeometryChange`
    /// needs iOS 18).
    func onGeometryChangeCompat(_ action: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size) }
                    .onChange(of: proxy.size) { _, size in action(size) }
            })
    }
}

// MARK: - Presence binding and row keys

extension Binding where Value == Bool {
    /// True while `item` holds a value; setting it false clears the item.
    init<Item: Sendable>(isPresent item: Binding<Item?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension Collection {
    /// Row keys: each element's id, with its occurrence appended for a
    /// repeated id (foreign data can repeat one): the first keeps `id`, the
    /// next are `id#1`, `id#2`, and so on.
    func uniqueKeys(id: (Element) -> String) -> [(key: String, element: Element)] {
        var seen: [String: Int] = [:]
        return map { element in
            let raw = id(element)
            let n = seen[raw, default: 0]
            seen[raw] = n + 1
            return (n == 0 ? raw : "\(raw)#\(n)", element)
        }
    }
}
