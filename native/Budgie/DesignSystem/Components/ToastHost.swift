import SwiftUI
import UIKit

extension View {
    /// Reports the safe-area insets this screen keeps clear (the home
    /// indicator, plus the tab bar on the tabs, on whichever edge it sits) so
    /// `ToastWindow` keeps toasts inside them. Only the screen on show should
    /// be active.
    func toastClearance(isActive: Bool = true) -> some View {
        modifier(ToastClearanceReporter(isActive: isActive))
    }
}

/// The safe-area insets the screen under the toast keeps clear, in points
/// from the window's edges.
@MainActor
@Observable
final class ToastLayout {
    var clearance = EdgeInsets()
}

private struct ToastClearanceReporter: ViewModifier {
    @Environment(ToastLayout.self) private var layout: ToastLayout?
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.safeAreaInsets) }
                    .onChange(of: proxy.safeAreaInsets) { _, insets in report(insets) }
                    .onChange(of: isActive) { _, _ in report(proxy.safeAreaInsets) }
            }
        }
    }

    private func report(_ insets: EdgeInsets) {
        if isActive { layout?.clearance = insets }
    }
}

/// Hosts `model.toast` along the bottom edge (floating, radius 12, success,
/// danger or neutral fill) in a passthrough window of the scene above the
/// app's own, so a toast posted while a sheet, dialog or `AddFormHost` is up
/// shows over it instead of under it: presentations live inside the app
/// window, and an overlay on its content sits below them. Below
/// `AppLockWindow` (`.alert + 1`), so the privacy cover and lock screen still
/// hide it. The window is shown only while there is a toast, takes touches
/// only on the toast itself, and never becomes key (a focused field keeps
/// its keyboard). The toast keeps inside the larger of this window's safe
/// area (the keyboard included) and the insets the screen underneath reports
/// (`toastClearance`, which include the tab bar on any edge), and is
/// dismissed after its duration. VoiceOver announces it.
@MainActor
final class ToastWindow {
    private let model: AppModel
    private let window: PassthroughWindow
    private var hide: Task<Void, Never>?

    init(windowScene: UIWindowScene, model: AppModel, layout: ToastLayout) {
        self.model = model
        window = PassthroughWindow(windowScene: windowScene)
        window.windowLevel = .normal + 1
        let controller = UIHostingController(
            rootView: ToastWindowRoot(model: model, layout: layout) { [weak window] frame in window?.touchFrame = frame })
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        window.isHidden = true
        track()
    }

    /// The app window's interface style (the theme preference).
    func applyInterfaceStyle(_ style: UIUserInterfaceStyle) { window.overrideUserInterfaceStyle = style }

    /// Shown with a toast; hidden once its exit transition has played.
    private func sync() {
        hide?.cancel()
        if model.toast != nil {
            window.isHidden = false
            return
        }
        // The leaving toast takes no taps.
        window.touchFrame = .null
        hide = Task {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil, model.toast == nil else { return }
            window.isHidden = true
        }
    }

    private func track() {
        withObservationTracking {
            _ = model.toast
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
    }
}

/// A window that takes touches only inside `touchFrame` (the toast), so
/// everything else reaches the app window beneath.
final class PassthroughWindow: UIWindow {
    var touchFrame: CGRect = .null

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        touchFrame.contains(point) ? super.hitTest(point, with: event) : nil
    }
}

private struct ToastWindowRoot: View {
    let model: AppModel
    let layout: ToastLayout
    let onTouchFrame: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .overlay(alignment: .bottom) {
                    if let toast = model.toast {
                        ToastView(toast: toast)
                            .background {
                                GeometryReader { toastProxy in
                                    let frame = toastProxy.frame(in: .global)
                                    Color.clear
                                        .onAppear { onTouchFrame(frame) }
                                        .onChange(of: frame) { _, frame in onTouchFrame(frame) }
                                }
                            }
                            .padding(.leading, Metrics.spacingM + extra(\.leading, proxy))
                            .padding(.trailing, Metrics.spacingM + extra(\.trailing, proxy))
                            .padding(.bottom, Metrics.spacingS + extra(\.bottom, proxy))
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                            .id(toast.id)
                            .task(id: toast.id) {
                                AccessibilityNotification.Announcement(toast.message).post()
                                // A cancelled wait (the view went away) must not
                                // cut the toast short.
                                guard (try? await Task.sleep(for: .seconds(toast.duration))) != nil else { return }
                                model.dismissToast(toast.id)
                            }
                    }
                }
        }
        .motion(Motion.easeOut(0.25), value: model.toast?.id)
        .font(TextSpec.bodyLarge.font())
        .environment(model)
    }

    /// How far the reported clearance reaches past this window's own safe area.
    private func extra(_ edge: KeyPath<EdgeInsets, CGFloat>, _ proxy: GeometryProxy) -> CGFloat {
        max(0, layout.clearance[keyPath: edge] - proxy.safeAreaInsets[keyPath: edge])
    }
}

/// Flutter's SnackBar text is M3 `onInverseSurface` (a dark neutral in dark
/// mode, near-white in light), not white: `onAccent` (#0A0A12 / #FFFFFF)
/// keeps it legible on the bright dark-mode green and rose. The neutral
/// style stands in for M3 `inverseSurface` / `onInverseSurface` with the
/// primary text colour as the fill and the page background as the text
/// (text on fill: #F9FAFB on #111827 light, #0A0A12 on #F2F2FA dark).
private struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        let foreground = toast.style == .neutral ? BudgieColor.background : BudgieColor.onAccent
        HStack(spacing: 12) {
            Text(toast.message)
                .textStyle(.bodySmall)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            if toast.action == .retrySaves {
                Button {
                    model.dismissToast(toast.id)
                    Task { await model.retrySaves() }
                } label: {
                    // The text is about 17pt tall; the tap area is 44.
                    Text("Retry")
                        .textStyle(.labelSmall)
                        .foregroundStyle(foreground)
                        .tapArea(horizontal: 6, vertical: 14)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(fill, in: RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        // A toast with Retry keeps its button as its own element: combined,
        // VoiceOver would read it as text with nothing to activate.
        .accessibilityElement(children: toast.action == nil ? .combine : .contain)
    }

    private var fill: Color {
        switch toast.style {
        case .success: BudgieColor.income
        case .danger: BudgieColor.danger
        case .neutral: BudgieColor.textPrimary
        }
    }
}
