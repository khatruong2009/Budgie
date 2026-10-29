import BudgieCore
import Foundation
import os

extension AppModel {
    // MARK: - Settings (store section + mirrored preference, like Dart)

    private static let settingsLog = Logger(subsystem: AppIdentifiers.bundleID, category: "settings")

    /// Dart `setBaseCurrencyCode`: trimmed and uppercased; a code that is
    /// not 3 characters long, or the current one, writes nothing. Amounts
    /// are not converted.
    @discardableResult
    func setBaseCurrency(_ code: String) async -> Bool {
        await updateSettings("baseCurrencyCode") { $0.setBaseCurrencyCode(code) }
    }

    /// Dart `setLocaleOverride`: nil or blank is "Match device" (the mirror
    /// is removed). Written even when unchanged, as Dart does.
    @discardableResult
    func setLocaleOverride(_ locale: String?) async -> Bool {
        await updateSettings("localeOverride") { $0.setLocaleOverride(locale) }
    }

    /// Dart `setAppLockEnabled`.
    @discardableResult
    func setAppLockEnabled(_ enabled: Bool) async -> Bool {
        await updateSettings("appLockEnabled") { $0.setAppLockEnabled(enabled) }
    }

    /// Dart `setAutoLockTimeoutSeconds`: a negative value writes nothing.
    @discardableResult
    func setAutoLockTimeoutSeconds(_ seconds: Int) async -> Bool {
        await updateSettings("autoLockTimeoutSeconds") { $0.setAutoLockTimeoutSeconds(seconds) }
    }

    /// Dart `setHideBalances`: `moneyFormatter` masks every amount at once,
    /// and the Home Screen widget too (D12; Flutter's widget ignores it).
    @discardableResult
    func setHideBalances(_ hidden: Bool) async -> Bool {
        let saved = await updateSettings("hideBalances") { $0.setHideBalances(hidden) }
        syncWidgetPrivacy()
        return saved
    }

    /// One `AppSettingsProvider` setter: memory, the preference mirror, then
    /// the whole `appSettings` section, awaited. True when the write verified
    /// or the value was already current; false for a rejected value or a
    /// failed write, which stays in memory behind the unsaved banner (Flutter
    /// has no failure handling: its change reverts on relaunch).
    private func updateSettings(_ field: String, _ change: (inout AppSettings) -> SettingsUpdate) async -> Bool {
        guard data != nil else { return false }
        switch change(&data!.appSettings) {
        case .rejected:
            return false
        case .unchanged:
            return true
        case .write(let key, let value):
            preferences.set(value, forKey: key)
            let saved = await persist([Section.appSettings])
            if !saved { Self.settingsLog.error("appSettings.\(field, privacy: .public) not saved; kept in memory") }
            return saved
        }
    }

    /// Dart `ThemeProvider.setThemeMode`: the preference only, no store
    /// section; the current mode writes nothing.
    func setThemeMode(_ mode: ThemeMode) {
        guard mode != themeMode else { return }
        themeMode = mode
        preferences.set(.string(mode.rawValue), forKey: PreferenceKey.themeMode)
    }

    var moneyFormatter: MoneyFormatter {
        let settings = data?.appSettings
        return MoneyFormatter(
            currencyCode: settings?.baseCurrencyCode ?? "USD", locale: settings?.localeOverride,
            hideBalances: settings?.hideBalances ?? false)
    }
}
