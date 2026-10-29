> Archived; paths refer to the `flutter-final` tag.

# F. Native iOS surface of the Flutter app (research for SwiftUI migration)

Scope: everything the Flutter app exposes to iOS that a native replacement, installed OVER it with the same bundle ID, must preserve or consciously drop. All paths relative to `budget_app/` unless noted. Tags: VERIFIED = read directly in the cited file/line; INFERRED = deduced from code/plugin behavior, not directly observed.

---

## 1. Identifiers

| Item | Value | Source | Status |
|---|---|---|---|
| App bundle ID (Debug, Release, Profile) | `com.khatruong.budgetbuddy` | `ios/Runner.xcodeproj/project.pbxproj:532` (Profile), `:724` (Release), `:757` (Debug) | VERIFIED - identical in all three configs |
| Widget extension bundle ID (Debug, Release, Profile) | `com.khatruong.budgetbuddy.BudgetWidgetsExtension` | pbxproj `:449` (Profile), `:786`, `:813` | VERIFIED |
| Widget target name / product | target `BudgetWidgetsExtension`, product `BudgetWidgetsExtension.appex`, `productType = app-extension` | pbxproj `:198-215` | VERIFIED |
| DEVELOPMENT_TEAM | `TJ37GFZKW2` (Runner: `:521 :713 :746`; widget: `:440 :777 :804`) | pbxproj | VERIFIED |
| CODE_SIGN_STYLE | Widget: `Automatic` (`:438 :775 :802`). Runner: not set in target (project default, Xcode default = Automatic) | pbxproj | VERIFIED (widget) / INFERRED (Runner) |
| App Group | `group.com.khatruong.budgetbuddy` in BOTH `ios/Runner/Runner.entitlements:5-7` and `ios/BudgetWidgets/BudgetWidgets.entitlements:5-7` | entitlements | VERIFIED |
| Other entitlements | None. Both files contain ONLY `com.apple.security.application-groups`. | entitlements (10 lines each) | VERIFIED |
| Keychain access groups | None declared (no `keychain-access-groups` key). No keychain/secure-storage package in `pubspec.yaml` (grep for keychain/secure_storage in pubspec, lib, ios/Runner, ios/BudgetWidgets: no hits). Financial data is NOT in keychain. | grep | VERIFIED |
| URL scheme | `budgetapp` (`CFBundleURLSchemes`), role Editor, `CFBundleURLName` = `com.khatruong.budgetbuddy` | `ios/Runner/Info.plist:27-39` | VERIFIED |
| Deployment target | iOS 15.0 everywhere: Runner `:526 :718 :751`, widget `:442 :779 :806`, project-level `:501 :640 :692` | pbxproj | VERIFIED |
| Device family | Runner `TARGETED_DEVICE_FAMILY = 1` (iPhone only; `:539 :732 :764`); widget `"1,2"`; project-level `"1,2"`. Also `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`, `SUPPORTS_MACCATALYST = NO` (`:535`) | pbxproj | VERIFIED |
| Orientation | Portrait only (`UISupportedInterfaceOrientations` = Portrait) | `Info.plist:69-72` | VERIFIED |
| CFBundleShortVersionString | `$(FLUTTER_BUILD_NAME)` in Info.plist (`Info.plist:21-22`); target build setting `MARKETING_VERSION = "$(FLUTTER_BUILD_NAME)"` (`:531 :723 :756`). Widget Info.plist uses `$(MARKETING_VERSION)` -> same `$(FLUTTER_BUILD_NAME)` (`BudgetWidgets/Info.plist:19-20`; pbxproj `:448 :785 :812`) | VERIFIED |
| CFBundleVersion | `$(FLUTTER_BUILD_NUMBER)` (`Info.plist:25-26`); `CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)"` for both app and widget | VERIFIED |
| Where FLUTTER_BUILD_* come from | `ios/Flutter/Generated.xcconfig` (gitignored: `ios/.gitignore:21`), included by `Flutter/Debug.xcconfig`, `Release.xcconfig`, `BudgetWidgets/BudgetWidgets.xcconfig` (each is one line `#include ".../Generated.xcconfig"`). Generated from `pubspec.yaml:19` `version: 3.4.0+1`. Current generated values: `FLUTTER_BUILD_NAME=3.4.0`, `FLUTTER_BUILD_NUMBER=1` (`Generated.xcconfig`, local worktree copy). `ios/scripts/sync_flutter_version.sh` bumps the build number and runs `flutter build ios --config-only`. | VERIFIED |
| Display name | `CFBundleDisplayName` = `Budgie` (`Info.plist:9-10`). Note pbxproj also has `INFOPLIST_KEY_CFBundleDisplayName = "Budgie Budget"` (`:524 :716 :749`) but `GENERATE_INFOPLIST_FILE` is NOT set for the Runner target (only for RunnerTests, `:550 :567 :582`), so INFOPLIST_KEY_* is ignored and the shipped name is `Budgie`. `CFBundleName` = `budget_app`. Widget display name `Budget Widgets` (`BudgetWidgets/Info.plist:7-8`). | VERIFIED (plist) / INFERRED (INFOPLIST_KEY ignored) |
| Other targets | `RunnerTests` (unit test bundle), bundle ID `com.example.budgetApp.RunnerTests` (`:552 :569 :584`) - a placeholder ID, irrelevant to shipping. Only one extension exists: the widget. No Watch, Share, Intents, Notification Service extensions. | pbxproj `:197-258` | VERIFIED |
| App category | `public.app-category.finance` (`Info.plist:40-41`) | VERIFIED |
| Plugins with native iOS code | file_picker, local_auth_darwin, package_info_plus, path_provider_foundation, quick_actions_ios (1.2.3), record_ios, share_plus, shared_preferences_foundation | `.flutter-plugins-dependencies` | VERIFIED |

Bundle IDs, App Group, and scheme all MATCH the expected list. No mismatches. Only surprises: display name is `Budgie` (not "Budgie Budget"); RunnerTests uses a `com.example` ID; no keychain group exists.

Hazards for install-over:
- Native app must carry team `TJ37GFZKW2`, same bundle ID, same App Group entitlement, and CFBundleVersion strictly greater than whatever was last uploaded/installed. The current pubspec build number is `1` (`3.4.0+1`); the App Store Connect history is UNVERIFIED (not in repo).
- Widget extension bundle ID must remain `com.khatruong.budgetbuddy.BudgetWidgetsExtension` and be a child of the app ID, else the installed widgets vanish/are orphaned. (INFERRED)
- Info.plist has `UIMainStoryboardFile = Main` (`:67-68`) plus a scene manifest; a SwiftUI `App` lifecycle should drop the storyboard key. Launch storyboard `LaunchScreen` is referenced (`:63-64`).

---

## 2. Native Swift in `ios/Runner` (method channels)

Swift files: `AppDelegate.swift` (162 lines), `SceneDelegate.swift` (116 lines). `Runner-Bridging-Header.h` is the only other source. `RunnerTests/RunnerTests.swift` is an empty template. VERIFIED (dir listing).

All channels are `FlutterMethodChannel` (StandardMethodCodec) except the quick-action pigeon message.

| Channel | Method | Direction | Args | Native behavior | Source |
|---|---|---|---|---|---|
| `budget_app/deeplink` | `getInitialLink` | Dart -> native | none | Returns `initialLink` (String?) then sets it nil. Handler installed in `SceneDelegate.setupDeepLinkChannel` on `flutterViewController.binaryMessenger`. | `SceneDelegate.swift:61-76` VERIFIED |
| `budget_app/deeplink` | `deep_link` | native -> Dart | `String` (absolute URL string) | `handleDeepLink(url)`: stores `initialLink = url.absoluteString` AND `invokeMethod("deep_link", arguments:)`. Called for cold-launch `connectionOptions.urlContexts.first` and for `scene(_:openURLContexts:)` (`.first` only). | `SceneDelegate.swift:46-49, 56-59, 78-81` VERIFIED |
| `budget_app/widget_data` | `updateCashFlow` | Dart -> native | `{"amount": Double, "month": String "YYYY-MM"}`; else returns `FlutterError("bad_args", "Expected amount and month")` | Writes `cashFlow` (Double) and `cashFlowMonth` (String) into `UserDefaults(suiteName: "group.com.khatruong.budgetbuddy")`, then `WidgetCenter.shared.reloadAllTimelines()` (iOS 14+), returns nil. Handler is on `flutterEngine.binaryMessenger` (`AppDelegate.setupWidgetDataChannel`). | `AppDelegate.swift:135-161` VERIFIED |
| `budget_app/protected_data` | `isAvailable` | Dart -> native | none | Returns `UIApplication.shared.isProtectedDataAvailable` (Bool). | `AppDelegate.swift:113-119` VERIFIED |
| `budget_app/protected_data` | `protectedDataDidBecomeAvailable` | native -> Dart | nil | Fired from a `NotificationCenter` observer on `UIApplication.protectedDataDidBecomeAvailableNotification` (queue `.main`). | `AppDelegate.swift:121-128` VERIFIED |
| Pigeon `dev.flutter.pigeon.quick_actions_ios.IOSQuickActionsFlutterApi.launchAction` | (basic message) | native -> Dart | `[shortcutType]` (String list) via `FlutterStandardMessageCodec` | `SceneDelegate.sendQuickAction` manually posts the shortcut type because scene-based lifecycle bypasses the plugin's app-delegate hooks. Cold launch: type stashed in `pendingShortcutType` and sent in `sceneDidBecomeActive`. Warm: `windowScene(_:performActionFor:completionHandler:)` sends immediately and completes `true`. | `SceneDelegate.swift:51-53, 83-115` VERIFIED; hook bypass reason INFERRED |

Other AppDelegate facts:
- `@main class AppDelegate: FlutterAppDelegate`, lazy `FlutterEngine(name: "budget_app_engine")`, `flutterEngine.run()` then `GeneratedPluginRegistrant.register(with: flutterEngine)` in `didFinishLaunchingWithOptions` (`AppDelegate.swift:11-21`). Widget-data and protected-data channels are set up right there (`:20-21`), i.e. before any scene exists and before `main` finishes on a prewarmed launch. VERIFIED.
- `configurationForConnecting` returns config named "Default Configuration" with `delegateClass = SceneDelegate` (`:44-55`). VERIFIED.
- The `budget_app/deeplink` channel in AppDelegate (`:76-96`) only wires for iOS < 13 (`#unavailable(iOS 13.0)`), dead code at deployment target 15. VERIFIED.
- SceneDelegate builds a `FlutterViewController` on the shared engine, installs the `LaunchScreen` storyboard view as splash and uses color asset `launch-screen-background` as window background (`SceneDelegate.swift:19-41`). VERIFIED.

Quoted protected-data code (`AppDelegate.swift:98-129`):

```swift
  /// Lets Flutter hold its storage access until the app container is readable.
  /// iOS can prewarm the app (running `main` and this delegate) before the
  /// device has been unlocked after a reboot; in that state the data files are
  /// still encrypted and would read back empty.
  private var protectedDataChannel: FlutterMethodChannel?

  private func setupProtectedDataChannel() {
    let channel = FlutterMethodChannel(
      name: "budget_app/protected_data",
      binaryMessenger: flutterEngine.binaryMessenger
    )
    protectedDataChannel = channel

    channel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) in
      guard call.method == "isAvailable" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(UIApplication.shared.isProtectedDataAvailable)
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.protectedDataChannel?.invokeMethod(
        "protectedDataDidBecomeAvailable", arguments: nil)
    }
  }
```

Prewarm detection: there is NO explicit prewarm check (no `ActivePrewarm` env var, no `applicationState` test). "Prewarm/locked launch" is detected purely by `isProtectedDataAvailable == false`. VERIFIED (grep of ios/Runner for prewarm: only comments).

Native-app implication: the data file lives in Application Support with iOS default file protection (no explicit `NSFileProtection*` attribute set in Swift; Dart writes via `dart:io`). Default protection class for app container files is "until first user authentication" (INFERRED). A SwiftUI app that can be prewarmed must gate its first store read on `UIApplication.shared.isProtectedDataAvailable` / `protectedDataDidBecomeAvailableNotification`, otherwise a locked-device read looks like an empty store and the next write destroys real data.

---

## 3. `lib/storage/protected_data_gate.dart` exact behavior

(`lib/storage/protected_data_gate.dart:16-66`, VERIFIED)
- `ProtectedDataGate.waitUntilAvailable()`:
  1. Returns immediately (no wait) if `kIsWeb` or not iOS (`:27`). So Android/macOS/etc. never block.
  2. Uses a single static `Completer<void>? _available` (created lazily, `:29`). If it's already completed, returns (`:30`). The completer is permanent for the process: once protected data has been seen available, all later calls are instant.
  3. Installs a method-call handler on `budget_app/protected_data`; on `protectedDataDidBecomeAvailable` it completes the completer (`:32-37`).
  4. Calls `isAvailable` (`:41`). `null` result -> treated as available (`?? true`).
  5. `MissingPluginException` -> treated as available (stale binary during development, `:42-45`). `PlatformException` -> logged and treated as available (`:46-49`).
  6. If available: completes and returns (`:51-54`).
  7. Otherwise logs `Protected data unavailable (prewarmed or locked launch); deferring storage access until the device unlocks` and `await completer.future` (`:56-60`).
- NO TIMEOUT anywhere in the file (grep for Duration/timeout: no hits). If data never becomes available the future never resolves: `_initializeApp` (`lib/main.dart:261`) stays blocked, `_initFuture` never completes, and the user sees the `_OpeningScreen` (main.dart:239) indefinitely. Deep links and quick actions also wait on `_initializationCompleter` (main.dart:328, 368) and never fire. There is no error UI for this state (the `_InitializationErrorScreen` at main.dart:411 is only for thrown load errors). VERIFIED.
- Race: `isAvailable` is queried after the handler is installed, so a flip between the two calls is caught by the push message. VERIFIED (ordering in code).
- Called from exactly one place: `lib/main.dart:261`, before `AtomicFinancialStore.instance.read()` and every provider `load()` (`main.dart:263-272`). VERIFIED.
- `lib/storage/atomic_financial_store.dart:640-646` comment also states reads fail when protected data is unavailable and that any read error must never be mistaken for an empty store. VERIFIED.

---

## 4. Home screen widget (`ios/BudgetWidgets/`)

Files: `BudgetWidgets.swift`, `BudgetWidgetsBundle.swift`, `Info.plist`, `BudgetWidgets.entitlements`, `BudgetWidgets.xcconfig`, `Assets.xcassets/BudgieLogo.imageset` (image `budgie_mark.png`). VERIFIED.

- `@main struct BudgetWidgetsBundle: WidgetBundle` contains `BudgetQuickActionsWidget()` and `BudgetVoiceAddWidget()` (`BudgetWidgetsBundle.swift:4-10`). VERIFIED.
- Widget kinds (exact strings, matter for existing installed widgets):
  - `kind = "BudgetQuickActions"` (`BudgetWidgets.swift:150`), display name "Budget Quick Add", description "Add income or expense from your home screen.", `.supportedFamilies([.systemSmall])` (`:156-158`). Two `Link` buttons: "Income" -> `budgetapp://add-income`, "Expense" -> `budgetapp://add-expense` (`:101-102, 107-118`).
  - `kind = "BudgetVoiceAdd"` (`:208`), display name "Voice Add", description "Speak a transaction and review it before saving.", `.supportedFamilies([.systemSmall])`, `.widgetURL(URL(string: "budgetapp://voice-add")!)` (`:210-217`). Shows a `mic.fill` circle.
  - Both are `StaticConfiguration` with `TimelineProvider` (no App Intents, no configuration, no lock screen / medium / large families). VERIFIED.
- Header on both: `BudgieLogo` image + current-month cash flow, formatted with `NumberFormatter` `.currency`, locale hard-coded `en_US`, 0 fraction digits (`:68-74`), i.e. always "$" regardless of the app's base currency setting. Green `(0.55,0.85,0.62)` if >= 0, red `(0.95,0.55,0.50)` if < 0. When `cashFlow == nil` shows the text "Budgie" instead (`:39-66`). VERIFIED.
- Background: gradient (0.10,0.12,0.25) -> (0.07,0.09,0.20); `containerBackground(for: .widget)` on iOS 17+ else `.background` (`:221-247`). VERIFIED.
- App Group UserDefaults suite: `group.com.khatruong.budgetbuddy` (`:6`). Keys read:
  - `cashFlow` : Double (checked via `defaults.object(forKey:) != nil`, read with `.double(forKey:)`)
  - `cashFlowMonth` : String, format `%04d-%02d` e.g. `2026-09` (`:10-17, 27-30`)
  - Logic: no suite / no `cashFlow` / no `cashFlowMonth` -> returns nil (fresh install; header shows "Budgie"). If stored month != current Gregorian month key -> returns 0 (stale month). Else the stored value. Calendar is forced to Gregorian in device time zone (`:19-25`). VERIFIED.
- Writers:
  1. Native `AppDelegate` `updateCashFlow` handler (section 2) is the only native writer. VERIFIED.
  2. Dart caller: `lib/transaction_model.dart:311-337` `_syncWidgetCashFlow()` (iOS only, `PlatformUtils.isIOS`): sums current calendar-month transactions (`transaction.date.year/month == now`), income positive, expense negative, sends `{'amount': cashFlow, 'month': 'YYYY-MM'}`. Errors (PlatformException/MissingPluginException) are swallowed. No `home_widget` plugin is used (grep: none). VERIFIED.
  3. Dart call sites of `_syncWidgetCashFlow`: after every successful `saveTransactions` (`:306`), at the end of `getTransactions()` on load (`:431`), after the combined transactions+budgets save (`:820`), and after `restoreFromBackup` (`:1236`). `saveTransactions` is the funnel for add/edit/delete/import/recurring generation. Not called if the save failed. VERIFIED (call sites); "funnel for add/edit/delete" INFERRED from `:295, 463, 476`.
- Timeline reload policy: `getTimeline` returns a single entry at `Date()` with `policy: .after(startOfNextMonth)` (`:91-95, 176-180`); app-triggered refresh through `WidgetCenter.shared.reloadAllTimelines()` on every write. VERIFIED.
- Deep links emitted: `budgetapp://add-income`, `budgetapp://add-expense`, `budgetapp://voice-add`. VERIFIED.
- Widget Info.plist: only `NSExtensionPointIdentifier = com.apple.widgetkit-extension`, standard bundle keys (`BudgetWidgets/Info.plist`). Entitlements: App Group only. VERIFIED.
- Hazard: values written are `Double` (money is Double in the Flutter app). If the native app later stores money differently, keep writing `cashFlow` as a Double and `cashFlowMonth` as `YYYY-MM` (or update the widget in lock-step). Widget currency is hard-coded USD. Also the widget only reads the two keys; it does NOT read the transaction store.

---

## 5. Quick actions

- Plugin `quick_actions ^1.0.0` (`pubspec.yaml:42`; iOS impl `quick_actions_ios 1.2.3`). Registered in `lib/main.dart:177-195` inside `_MyAppState.initState`. VERIFIED.
- DYNAMIC, not static: `Info.plist` has no `UIApplicationShortcutItems` key (grep on Info.plist: none). Items are set at runtime via `UIApplication.shared.shortcutItems` by the plugin (`QuickActionsPlugin.swift:30-33`, in pub cache). VERIFIED. Consequence: a native app must set shortcut items in code (or add static `UIApplicationShortcutItems`). Whether previously-set dynamic items survive an app update is UNVERIFIED.

| type | localizedTitle | icon string | Action (`lib/main.dart:327-354`) |
|---|---|---|---|
| `action_add_expense` | Add Expense | `minus.circle.fill` | after init completes, post-frame `showTransactionForm(ctx, TransactionTyp.expense, transactionModel.addTransaction)` |
| `action_add_income` | Add Income | `plus.circle.fill` | same with `TransactionTyp.income` |
| `action_voice_add` | Add by Voice | `mic.circle.fill` | post-frame `startVoiceExpenseFlow(ctx)` (voice recording sheet) |

- Icon caveat (INFERRED, important): the plugin converts the string to `UIApplicationShortcutIcon(templateImageName:)` (`QuickActionsPlugin.swift:93-95`), which resolves names from the app's asset catalog, NOT SF Symbols. `Runner/Assets.xcassets` contains imagesets `plus` and `minus` only (plus `logo`, `LaunchImage`, `launch-gradient`, `AppIcon`); there are NO imagesets named `minus.circle.fill`, `plus.circle.fill`, `mic.circle.fill`. So the shortcuts most likely render with no icon today. `QUICK_ACTIONS_ICONS_GUIDE.md` (repo) still describes `icon: 'minus'`/`'plus'`, out of date vs main.dart. A native app should use `UIApplicationShortcutIcon(systemImageName:)` (or bundle those names) - a free improvement.
- Handling is gated: `_handleQuickAction` awaits `_initializationCompleter.future` (`main.dart:328`), so nothing opens before the store has loaded. VERIFIED.
- Delivery path: SceneDelegate posts the pigeon message (section 2). Shortcut item is also re-registered on every launch of Flutter app (initState). VERIFIED.

---

## 6. Deep links (`budgetapp://`)

Parsed in `lib/main.dart:356-394` (`_handleDeepLink`), VERIFIED:
- `Uri.tryParse(link)`; action = `uri.host` if non-empty, else first path segment (`:362-364`). Empty action ignored.
- Recognized actions (both hyphen and underscore spellings): `add-income`/`add_income` -> transaction form (income); `add-expense`/`add_expense` -> transaction form (expense); `voice-add`/`voice_add` -> `startVoiceExpenseFlow`. Anything else is silently ignored (no navigation to tabs, no query parameters read, no amount prefill). (`:384-393`)
- Waits for `_initializationCompleter.future` (`:368`) before acting, so links queue until data is loaded (and never fire if init fails / protected data never arrives).
- Dedup: identical link string within 2 seconds is dropped (`_deepLinkDedupWindow`, `:166, 396-407`), which absorbs the double delivery (initial-link pull + pushed `deep_link`).
- Native side: cold-launch URL from `connectionOptions.urlContexts.first`; warm URLs via `scene(_:openURLContexts:)`; no `application(_:open:)` effect at iOS 13+ (`AppDelegate.swift:65-74`). No universal links, no associated domains entitlement. VERIFIED.
- Emitters: widget (section 4). Any `LSApplicationQueriesSchemes`: none (section 7).

---

## 7. `ios/Runner/Info.plist` notable keys (whole file read, 86 lines)

| Key | Value | Line |
|---|---|---|
| NSFaceIDUsageDescription | "Budgie uses Face ID to protect your financial data when App Lock is enabled." | 81-82 |
| NSMicrophoneUsageDescription | "Budgie uses the microphone so you can add transactions by speaking." | 83-84 |
| NSCameraUsageDescription | "Budgie uses the camera only when you choose to capture a file for importing financial data." (file_picker) | 75-76 |
| NSPhotoLibraryUsageDescription / NSPhotoLibraryAddUsageDescription | "We need access to save exported transaction files" (both) | 77-80 |
| CFBundleURLTypes | scheme `budgetapp` | 27-39 |
| UIApplicationSceneManifest | `UIApplicationSupportsMultipleScenes = false`; one config "Default Configuration" with `UISceneDelegateClassName = $(PRODUCT_MODULE_NAME).SceneDelegate` | 46-62 |
| UIMainStoryboardFile | `Main` | 67-68 |
| UILaunchStoryboardName | `LaunchScreen` | 63-64 |
| UISupportedInterfaceOrientations | Portrait only | 69-72 |
| UIStatusBarStyle / UIViewControllerBasedStatusBarAppearance | LightContent / false | 65-66, 73-74 |
| CADisableMinimumFrameDurationOnPhone | true (ProMotion 120Hz) | 5-6 |
| UIApplicationSupportsIndirectInputEvents | true | 44-45 |
| LSApplicationCategoryType | public.app-category.finance | 40-41 |
| LSRequiresIPhoneOS | true | 42-43 |

ABSENT (VERIFIED by full read + targeted grep): `UIBackgroundModes`, `LSApplicationQueriesSchemes`, `ITSAppUsesNonExemptEncryption` (so App Store Connect asks the export-compliance question each upload unless set elsewhere), `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `UIApplicationShortcutItems`, `NSSpeechRecognitionUsageDescription` (no on-device speech; transcription is via OpenAI), `NSUserNotificationsUsageDescription`, `UIRequiredDeviceCapabilities`, `CFBundleDocumentTypes`/`UTExportedTypeDeclarations` (app does not register to open .json/.csv files; import is via in-app file picker only), `NSAppTransportSecurity` (defaults; OpenAI over HTTPS).

Notes: microphone use is from `record` plugin (`lib/widgets/voice_recording_sheet.dart`); camera and photo strings are legacy for file_picker and likely unneeded by the native app unless it uses `PHPicker`/`UIImagePickerController`/photo saving (INFERRED).

---

## 8. Face ID / privacy gate

Source `lib/widgets/app_privacy_gate.dart` + `lib/app_settings_provider.dart`, VERIFIED unless noted.
- Package `local_auth ^2.3.0` (`pubspec.yaml:37`, iOS impl `local_auth_darwin`). Calls: `isDeviceSupported()` then `authenticate(localizedReason: 'Unlock Budgie to view your financial data', options: AuthenticationOptions(stickyAuth: true, biometricOnly: false, useErrorDialogs: true))` (`app_privacy_gate.dart:100-113`). `biometricOnly: false` means device passcode fallback (LAPolicy `deviceOwnerAuthentication`, INFERRED from plugin semantics). If `!isDeviceSupported()` throws StateError "Set up a device passcode or biometrics to use App Lock." and the lock screen offers a "Disable App Lock" button (`:100-105, 279-285`).
- Setting: `appLockEnabled` (bool, default false) and `autoLockTimeoutSeconds` (int, default 60), plus `hideBalances`. Toggled in Settings > PRIVACY (`lib/settings_page.dart:696-737`); lock delay choices: 0 (Immediately), 30, 60, 300, 900 seconds (`settings_page.dart:963-984`).
- Storage: primary = `AtomicFinancialStore` section `appSettings` (map keys `baseCurrencyCode`, `localeOverride`, `appLockEnabled`, `autoLockTimeoutSeconds`, `hideBalances`) (`app_settings_provider.dart:158-169`). Also mirrored in shared_preferences keys `app_lock_enabled`, `auto_lock_timeout_seconds`, `hide_balances`, `base_currency_code`, `locale_override` (`storage/storage_keys.dart:56-66`), used as load fallback when the store lacks the key (`app_settings_provider.dart:38-52`). So the store wins, prefs are fallback. On iOS shared_preferences keys are `flutter.`-prefixed in NSUserDefaults standard (INFERRED, plugin default prefix).
- When it prompts:
  - App start: `AppPrivacyGate` is only built after `_initializeApp` succeeds (`main.dart:232-237`). In its `initState` post-frame callback, if `appLockEnabled`, sets `_locked = true` and calls `_unlock()` (`:42-49`). So on cold launch the opening screen is visible first, then the lock covers the home UI.
  - On resume: if `appLockEnabled` and background duration >= `autoLockTimeoutSeconds` -> lock + prompt (`:73-88`). `_backgroundedAt` is set on the first of inactive/hidden/paused/detached (`:60-65`).
  - When the user toggles App Lock on while the app is running: locks immediately and prompts (`:137-143`).
  - Turning it off while locked clears the lock (`:144-148`).
- Privacy screen on backgrounding: `_obscured` is set true on inactive/hidden/paused/detached ONLY IF `appLockEnabled` (`:67-71`); it shows `_AppSwitcherPrivacyCover` (dark background, `assets/budgie_mark.png` 72pt, "Budgie", "App preview hidden") replacing the UI (`:160-161, 183-219`). With App Lock off there is no app-switcher cover. Content is also wrapped in `AbsorbPointer` + `ExcludeSemantics` while obscured/locked (`:153-159`).
- `hideBalances` masks amounts through `MoneyFormatter.configure(hideBalances:)` (`app_settings_provider.dart:150-156`). Independent of lock.
- Backups carry `appLockEnabled`/`autoLockTimeoutSeconds`/`hideBalances`, so a restore can turn App Lock on (section 9).
- Test: `test/app_privacy_gate_test.dart` exists (fake `LocalAuthentication`). Not read in detail.
- Note: `inactive` (which fires for the Face ID system sheet and Control Center) also arms the obscure cover and `_backgroundedAt` (INFERRED behavior consequence; stickyAuth mitigates).

---

## 9. Backup / export / import

Source: `lib/backup.dart` (284 lines), `lib/settings_page.dart:279-523`, `test/backup_test.dart`. VERIFIED.

Format: a DIFFERENT envelope from `financial_store_v2` (the store file is a checksummed, revisioned envelope (format tag `budgie-financial-store`, `schemaVersion` 2, `revision`, `sections` map) at `<ApplicationSupport>/financial_store/financial_store_v2.json` + `financial_store_v2.backup.json`; `atomic_financial_store.dart:114-118, 634-635` - envelope details are covered by another research assignment). The user-facing backup is pretty-printed JSON (2-space indent) `JsonEncoder.withIndent('  ')` (`backup.dart:84`):

```
{
  "schemaVersion": 3,            // kBackupSchemaVersion, backup.dart:15
  "app": "budgie",
  "appVersion": "<PackageInfo.version, fallback '2.0.0'>",
  "exportedAt": "<local ISO-8601 from DateTime.now().toIso8601String()>",
  "data": {
    "transactions": [Transaction.toJson...],
    "netWorthEntries": [...],
    "categoryBudgetLimits": {"<category name>": <double>},
    "savingsGoals": [...],
    "recurringTransactions": [...],
    "themeMode": "light"|"dark"|"system"|null,
    "categories": [BudgetCategory...],
    "transactionTags": [...],
    "categorizationRules": [...],
    "baseCurrencyCode": "USD",
    "localeOverride": null|"en_US",
    "appLockEnabled": false,
    "autoLockTimeoutSeconds": 60,
    "hideBalances": false
  }
}
```
(`backup.dart:52-85`.) Not included: `selectedNetWorthMonth` (restore keeps the model's current one, `settings_page.dart:429-430`), onboarding flag, store revision/checksum, tags/rules are included, insights caches n/a.

Versioning / validation on import (`decodeBackup`, `backup.dart:90-170`), strict, throws `FormatException` with user-facing messages:
- Strips leading UTF-8 BOM (U+FEFF). Non-JSON or non-object -> "This is not a valid Budgie backup file". `schemaVersion` must be an `int` (else same error). `schemaVersion > 3` -> "made by a newer version of Budgie". Older versions (1, 2) are accepted; missing sections decode to empty (`_decodeList` null -> `[]`). `data` must be a Map. `app`/`appVersion`/`exportedAt` are NOT validated. Unknown extra keys ignored (test `:458`).
- Per-section strictness: transaction/recurring `type` must be exactly `expense`/`income`; net worth entry `type` `asset`/`liability`; all amounts finite; unique category/tag/rule ids; every rule's `tagIds` must exist; if any categories present, each `BudgetCategoryType` must have >= 1 non-archived category; monthly recurring needs `dayOfMonth` 1..31; currency = 3-char string (uppercased) default `USD`; `autoLockTimeoutSeconds` num >= 0 default 60; unknown/absent `themeMode` -> null (means "do not change theme").
- Schema meaning of versions 2 vs 3: only the constant and a test for v1 legacy are visible; what changed between 1/2/3 is INFERRED (v1 transactions had no identity fields: test `backup_test.dart:302`; v3 added categories/tags/rules/currency/lock settings - INFERRED from field defaults `backup.dart:41-48`).

Restore semantics: FULL REPLACE, not merge (`settings_page.dart:372-523`): pick `.json` via file_picker with `withData: true`, decode with `utf8.decode(allowMalformed: true)`, confirm dialog "Replace all data? ... replacing everything currently in Budgie. This cannot be undone." Then `AtomicFinancialStore.updateSections({...all sections...})` in one atomic write, then each provider's `restoreFromBackup`, then theme set if non-null, then `TransactionGenerator.generateDueTransactions()` to back-fill recurring occurrences. `TransactionModel.restoreFromBackup` regenerates duplicate transaction ids (`transaction_model.dart:1197-1237`), drops budget limits <= 0, and re-syncs the widget. The only merge path is CSV import (dedupes by `date|type|category|description|amount(2dp)` multiset, `transaction_model.dart:1240-1250, ~1100-1195`).

Export: file `budgie_backup_<yyyyMMdd_HHmmss>.json` (local time, `DateFormat`) in `getTemporaryDirectory()`, shared with `Share.shareXFiles([XFile(path)], subject: 'Budgie Backup', sharePositionOrigin: <button rect>)` via share_plus 10 (`settings_page.dart:327-340`). CSV export: `transactions_<timestamp>.csv`, header `Date,Type,Category,Description,Amount` (`Income`/`Expense`, `yyyy-MM-dd`, 2dp) (`transaction_model.dart:1000-1040`).

`test/backup_test.dart` (480 lines) covers: full round-trip of every field of every section (`:214`), themeMode round trip incl. null (`:286`), schema-1 legacy transactions without identity remain importable (`:302`), invalid content rejected with FormatException (`:316`), non-finite numbers rejected in every section (`:337`), unrecognized type strings rejected not coerced (`:369`), monthly `dayOfMonth` validation (`:397`), absent/null sections -> empty + null theme (`:431, :441`), unknown extra keys ignored (`:458`), BOM stripped (`:466`), unknown themeMode -> null (`:476`); asserts `schemaVersion == 3` on encode (`:259`).

Migration implication: a native app that wants Flutter users' data must read `financial_store_v2.json` in place (same container, section 11), and should also be able to read/write this backup envelope so users can round-trip.

---

## 10. Notifications and other permissions

- Notifications: NONE. No `flutter_local_notifications`/UNUserNotificationCenter/`requestPermission` anywhere in `lib/`, `pubspec.yaml`, `ios/Runner`, `ios/BudgetWidgets` (grep VERIFIED; only hit is an icon name `Symbols.notification_important_rounded` at `lib/widgets/local_insights_section.dart:226` and the unrelated `NotificationCenter` observer for protected data). No push entitlement (`aps-environment` absent from entitlements), no `UIBackgroundModes`. Recurring transactions are generated on launch, not by background task (`main.dart:293-297`).
- Microphone: `record ^6.2.1` `AudioRecorder`, `hasPermission()` prompts at first recording (`lib/widgets/voice_recording_sheet.dart:67, 115-117`). AAC-LC, 16 kHz, mono `.m4a` into temp dir named `voice_expense_<ts>.m4a`, max 30 s (`:65, 139-149`). VERIFIED.
- Speech: no Apple Speech framework. Audio is uploaded to OpenAI (`gpt-4o-mini-transcribe`, then `gpt-5.4-nano` chat with JSON response) using key `OPEN_AI_API_KEY` loaded from the bundled `.env` asset (`lib/voice_expense_service.dart:26-40, 60-107`; `pubspec.yaml:85-88`). The `.env` is gitignored and not present in this worktree; the memory index notes the key is a placeholder until replaced. This is the only network use in the app. A native rewrite must decide where the key lives (do NOT hard-code). VERIFIED (code), placeholder state per project memory (not re-verified).
- Face ID / LocalAuthentication: section 8. Camera/photos: usage strings present but no direct lib code (file_picker). Location, contacts, calendar, health: none.

---

## 11. iOS-side files/state written

Native Swift code writes only ONE thing: two keys into the App Group UserDefaults suite (`cashFlow`, `cashFlowMonth`; `AppDelegate.swift:153-155`). It writes NO files. No JSON snapshot in the App Group container. VERIFIED (only two Swift sources in Runner, both read in full).

Data the Flutter side writes that a native install-over must be aware of (Dart-written, INFERRED path resolution from plugins on iOS):
- `<app container>/Library/Application Support/financial_store/financial_store_v2.json` and `financial_store_v2.backup.json` (+ transient `.tmp` during commit) via `getApplicationSupportDirectory()` + `financial_store` (`atomic_financial_store.dart:116-118, 634-635`). This is the source of truth for transactions, net worth, budgets, goals, recurring, categories, tags, rules, appSettings. Lives in the APP's container, NOT the App Group container, so the widget cannot read it (this is why `cashFlow` is pushed through UserDefaults). VERIFIED (code) / INFERRED (iOS directory = Library/Application Support).
- NSUserDefaults standard (shared_preferences_foundation, keys prefixed `flutter.`, INFERRED): `themeMode` ('light'|'dark'|'system', `theme_provider.dart:17-34`), `onboarding_completed` (bool, `onboarding_tutorial.dart:31-45`), plus mirrored settings keys (section 8), plus legacy pre-store keys read once for migration then removed (`atomic_financial_store.dart:128-141`: `financial_store_v1`, `financial_store_v1_backup`, `transactions`, `net_worth_entries`, `category_budget_limits`, `savings_goals`, `recurring_transactions`, `categories_v1`, `transaction_tags_v1`, `categorization_rules_v1`, ...). Theme and onboarding are NOT in the store file and would be lost/reset if the native app ignores `flutter.`-prefixed defaults. INFERRED impact.
- Temp files: `budgie_backup_*.json`, `transactions_*.csv`, `voice_expense_*.m4a` in tmp; not persistent.
- Bundled Flutter assets (`assets/budgie_mark.png`, `assets/icon.png`, `.env`, Gabarito fonts) are in the Flutter framework bundle (`flutter_assets`) and vanish with the Flutter app; native app must ship its own logo/font. VERIFIED (`pubspec.yaml:85-96`).

---

## Summary of hazards / unverified

1. Same-ID upgrade: keep team `TJ37GFZKW2`, bundle IDs, App Group, widget ID; CFBundleVersion must exceed last shipped (current pubspec `3.4.0+1`; ASC history UNVERIFIED).
2. Data location: only the app container file store (`financial_store/financial_store_v2.json`); no App Group file. Prewarm/locked launch reads must wait on `isProtectedDataAvailable` (no timeout in Flutter; never surfaces an error).
3. Widget contract: kinds `BudgetQuickActions`, `BudgetVoiceAdd`; keys `cashFlow` (Double), `cashFlowMonth` ("YYYY-MM"); widget hard-codes USD; deep links `add-income`, `add-expense`, `voice-add`.
4. Quick-action shortcuts are dynamic; icon strings probably do not resolve (asset names missing). Info.plist has no static shortcuts.
5. Theme and onboarding flags live in NSUserDefaults (`flutter.` prefix, INFERRED), not in the store; app lock/currency/locale/hideBalances live in the store (prefs are only fallback).
6. Backup envelope (schemaVersion 3, `app: "budgie"`) differs from the store; restore is full-replace and can toggle App Lock.
7. Absent: notifications, background modes, ITSAppUsesNonExemptEncryption, document types, keychain use.
8. Voice add depends on an OpenAI key from a bundled `.env` (network use; placeholder state not re-verified).
