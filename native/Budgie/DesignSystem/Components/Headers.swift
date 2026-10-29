import SwiftUI

/// Page header row (`BudgieHeader`): the page title (or the 36pt logo mark
/// on Home) on the left, an optional trailing view, padding (20, 12, 20, 0).
/// With `centerTrailing` the trailing view is centred between the leading
/// item and a 36pt right slot, which holds `accessory` (Home's settings gear,
/// D2) or stays empty.
struct BudgieHeader<Trailing: View, Accessory: View>: View {
    var title: String? = nil
    var showLogo = false
    var centerTrailing = false
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 0) {
            leading
            if centerTrailing {
                trailing().frame(maxWidth: .infinity)
                accessory().frame(width: 36, height: 36)
            } else {
                Spacer(minLength: 12)
                trailing()
            }
        }
        .frame(minHeight: 36)
        .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
    }

    @ViewBuilder private var leading: some View {
        if showLogo {
            Image("logo")
                .resizable().scaledToFill()
                .frame(width: Metrics.logoMark, height: Metrics.logoMark)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.logoMarkRadius, style: .continuous))
                .accessibilityLabel("Budgie")
        } else {
            Text(title ?? "")
                .textStyle(.pageTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .wrapsWords()
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension BudgieHeader where Accessory == EmptyView {
    init(title: String? = nil, showLogo: Bool = false, centerTrailing: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, showLogo: showLogo, centerTrailing: centerTrailing, trailing: trailing, accessory: { EmptyView() })
    }
}

extension BudgieHeader where Trailing == EmptyView, Accessory == EmptyView {
    /// A title alone (the row keeps the 36pt height of the empty slot).
    init(title: String) {
        self.init(title: title, trailing: { EmptyView() }, accessory: { EmptyView() })
    }
}

/// Section header (`SectionHeader`): title plus an optional accent text link
/// ("Edit", "See all"), baseline aligned, inset 4.
struct SectionHeader: View {
    let title: String
    var link: String? = nil
    /// VoiceOver label for the link; defaults to "<link>, <title>".
    var linkAccessibilityLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .textStyle(.sectionHeader)
                .foregroundStyle(BudgieColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let link {
                HapticButton(action: { action?() }) {
                    // The text is about 18pt tall and 30-50pt wide; the tap
                    // area is 44 x 44.
                    Text(link).textStyle(.textLink).foregroundStyle(BudgieColor.accent)
                        .tapArea(horizontal: 8, vertical: 13)
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
                .accessibilityLabel(linkAccessibilityLabel ?? "\(link), \(title)")
            }
        }
        .padding(.horizontal, 4)
    }
}
