import Foundation

/// Values the app and the widget extension must agree on byte for byte: the
/// App Group the app writes and the widget reads, the keys in it, and the
/// month key format. Existing users' home screens and the Flutter-written
/// App Group data depend on every one of these.
enum WidgetShared {
    static let appGroup = "group.com.khatruong.budgetbuddy"

    static let cashFlowKey = "cashFlow"
    static let cashFlowMonthKey = "cashFlowMonth"
    /// Hide balances (D12). Swift-only: Flutter's widget reads just `cashFlow` / `cashFlowMonth`.
    static let hideBalancesKey = "budgieHideBalances"

    /// `yyyy-MM`, matching what the Dart side writes from `DateTime.now()`.
    static let monthKeyFormat = "%04d-%02d"
}
