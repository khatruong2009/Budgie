import SwiftUI
import UIKit

/// The first-launch tour (`onboarding_tutorial.dart`): three swipeable pages,
/// left-aligned (redesign 4.4), Skip at the top right, page dots and a
/// full-width Continue / Start budgeting button. Shown once, as `MainView`'s content inside the lock gate
/// (Flutter's `AppPrivacyGate(OnboardingTutorialGate(...))`); Skip and the
/// last page's button call `model.completeOnboarding()`, which writes the
/// flag, swaps in the tabs and lets a queued quick action or link open.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    struct Page: Equatable {
        let symbol: String
        let eyebrow: String
        let title: String
        let body: String
    }

    /// Flutter's copy (`_pages`), except page 1, which adds that voice entries
    /// are sent to OpenAI (owner-approved wording), and page 3, which names
    /// Settings (D2: there is no More tab; Settings opens from the gear on
    /// Home).
    static let pages: [Page] = [
        Page(
            // Material `account_balance_wallet_rounded`: the bifold wallet
            // where the system has it (iOS 18), else the card.
            symbol: UIImage(systemName: "wallet.bifold.fill") != nil ? "wallet.bifold.fill" : "creditcard.fill",
            eyebrow: "WELCOME TO BUDGIE",
            title: "Your money, made clearer.",
            body: "Budgie keeps your budget simple and private. Financial data and insights stay on this device unless you choose to export or share a backup. Voice entries are the one exception: your recording is sent to OpenAI to be turned into an expense."),
        Page(
            symbol: "chart.bar.xaxis.ascending",  // `add_chart_rounded`
            eyebrow: "START HERE",
            title: "Track what comes and goes.",
            body: "On Home, use the add button for income or expenses. Your balance and recent activity update as you go."),
        Page(
            symbol: "chart.xyaxis.line",  // `insights_rounded`
            eyebrow: "EXPLORE WHEN READY",
            title: "Plan ahead, then look back.",
            body: "Worth tracks accounts, Goals keeps savings in view, and Spend, Flow, and Settings (behind the gear on Home) help you understand and manage your budget."),
    ]

    /// The Continue / Start budgeting label: 17 Bold.
    private static let buttonText = TextSpec(face: .gabaritoBold, size: 17, relativeTo: .body)

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                // 15 SemiBold secondary in a 44pt target.
                Button { model.completeOnboarding() } label: {
                    Text("Skip")
                        .textStyle(.textLink)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(minWidth: Metrics.touchTarget, minHeight: Metrics.touchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding.skip")
            }
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    OnboardingPageView(page: Self.pages[index])
                        .accessibilityIdentifier("onboarding.page.\(index + 1)")
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            dots
            Spacer().frame(height: 20)
            Button(action: next) {
                Text(isLast ? "Start budgeting" : "Continue")
                    .textStyle(Self.buttonText)
                    .foregroundStyle(BudgieColor.onAccent)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Metrics.spacingS)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(BudgieColor.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .accessibilityIdentifier("onboarding.next")
        }
        .padding(EdgeInsets(top: Metrics.spacingXS, leading: Metrics.spacingL, bottom: Metrics.spacingL, trailing: Metrics.spacingL))
        .frame(maxWidth: Metrics.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(BudgieColor.background.ignoresSafeArea())
    }

    /// Active 22x8 accent, the others 8x8 on the track colour, 6pt apart,
    /// left-aligned, resized over 150ms linear.
    /// VoiceOver: one adjustable element, "Tutorial page, n of 3".
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Self.pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? BudgieColor.accent : BudgieColor.track)
                    .frame(width: index == page ? 22 : 8, height: 8)
            }
        }
        .motion(.linear(duration: Motion.fast), value: page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tutorial page")
        .accessibilityValue("\(page + 1) of \(Self.pages.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if page < Self.pages.count - 1 { show(page + 1) }
            case .decrement: if page > 0 { show(page - 1) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("onboarding.dots")
    }

    private func next() {
        if isLast {
            model.completeOnboarding()
        } else {
            show(page + 1)
        }
    }

    /// Flutter's `nextPage` (300ms easeInOut); a jump under Reduce Motion.
    /// VoiceOver hears the new page, as its focus stays on the control.
    private func show(_ index: Int) {
        if reduceMotion {
            page = index
        } else {
            withAnimation(Motion.easeInOut(Motion.normal)) { page = index }
        }
        let shown = Self.pages[index]
        AccessibilityNotification.Announcement(
            "Tutorial page \(index + 1) of \(Self.pages.count). \(shown.title) \(shown.body)"
        ).post()
    }
}

/// One page (`_TutorialPage`): the 116pt feature-card block with the
/// symbol, then eyebrow, title and body, left-aligned and centred as a group
/// in the pager. Scrolls when large text makes it taller than the pager.
private struct OnboardingPageView: View {
    let page: OnboardingView.Page

    /// Mono 11, +0.18em, secondary.
    private static let eyebrowText = TextSpec(face: .monoMedium, size: 11, tracking: 1.98, uppercase: true, relativeTo: .caption2)
    /// 40 ExtraBold, -0.035em, line height 1.05.
    private static let titleText = TextSpec(face: .gabaritoExtraBold, size: 40, tracking: -1.4, height: 1.05, relativeTo: .largeTitle)
    /// 16, line height 1.5.
    private static let bodyText = TextSpec(face: .gabaritoRegular, size: 16, height: 1.5, relativeTo: .body)

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    let block = RoundedRectangle(cornerRadius: 34, style: .continuous)
                    Image(systemName: page.symbol)
                        .font(.system(size: 50, weight: .regular))
                        .foregroundStyle(BudgieColor.featureAmount)
                        .frame(width: 116, height: 116)
                        .background(BudgieColor.featureFill, in: block)
                        .overlay(block.strokeBorder(BudgieColor.featureBorder, lineWidth: Metrics.borderThin))
                        .accessibilityHidden(true)
                    Text(page.eyebrow)
                        .textStyle(Self.eyebrowText)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .padding(.top, 34)
                    Text(page.title)
                        .textStyle(Self.titleText)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Metrics.spacingM)
                    Text(page.body)
                        .textStyle(Self.bodyText)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .padding(.top, Metrics.spacingM)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Metrics.spacingM)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
    }
}
