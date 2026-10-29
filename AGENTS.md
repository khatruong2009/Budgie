# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before
making changes.

## What this repo is

A personal budget tracking app ("Budgie"): a SwiftUI iOS app in
[`native/`](native). The current version is 4.1.0 (`MARKETING_VERSION` in
`native/project.yml`).

It replaced a Flutter app (3.4.0) with the same bundle ID, App Group and
store file, so users upgraded in place. The Flutter code (`budget_app/`) was
removed from the tree after 4.0.0 shipped; it lives at the **`flutter-final`
git tag**. Paths under `budget_app/` in docs and code comments refer to that
tag. Users can still upgrade straight from 3.4.0, so the native app must keep
reading Flutter-written stores and preferences (`native/docs/MIGRATION_SPEC.md`).

All persistence is **local**. Financial data (transactions, net worth,
budgets, goals, recurring templates, categories, tags, rules, app settings)
lives in one checksummed JSON file with a last-known-good backup under the
app's Application Support directory, byte-compatible with Flutter's
`AtomicFinancialStore`.
`UserDefaults` is only used for real preferences (theme, onboarding flag,
small settings). There is no backend, no auth, no network sync.

## Native app (`native/`)

SwiftUI, iOS 17+, Swift 6, `@Observable`, no third-party dependencies. The
Xcode project is generated: `cd native && xcodegen generate` after adding or
removing files (commit `project.pbxproj`).

| Path | What |
|---|---|
| `native/BudgieCore/` | Swift package: store (byte-compatible with Flutter's `AtomicFinancialStore`), migration, Dart-exact dates/strings/numbers, domain logic. `cd native/BudgieCore && swift test` |
| `native/Budgie/` | The app: `App/AppModel.swift` (single `@Observable` model; mutations `await persist(...)` and return the verified `Bool`), `Views/`, `DesignSystem/` (tokens, Gabarito / Spline Sans Mono, components) |
| `native/BudgetWidgets/` | Home screen widgets (same `kind`s as Flutter) |
| `native/BudgieUITests/`, `native/BudgieAppTests/` | XCUITests per tab, accessibility audit, app unit tests |
| `native/ParityHarness/`, `native/Fixtures/` | Dart tests that run the real Flutter code (exported from the `flutter-final` tag) to produce the committed fixtures, and verify Swift-written stores load in Flutter |
| `native/docs/` | `FULL_APP_PLAN.md` (decisions, cross-cutting rules), `MIGRATION_SPEC.md` (store format, migration), `UI_SPEC.md`, `PARITY_GAPS.md` (every difference from Flutter), `PERFORMANCE.md`, `REAL_DEVICE_CHECKLISTS.md`, `archive/` (archived per-area specs in `archive/full-app/`, research notes, redesign plan) |

Shell: a native `TabView` with five tabs — **Home, Worth, Goals, Spend,
Flow** — each in its own `NavigationStack`. Settings is pushed from a gear in
the Home header; Recurring, Categories, Tags & rules, backup and CSV import
live under Settings. SEE ALL lists are pushed pages.

Rules every native change follows, in short (full text and the reasons:
[`FULL_APP_PLAN.md` section 3](native/docs/FULL_APP_PLAN.md)):
- Persistence: mutate memory, then `await persist([sections])`; patch stored
  records' raw JSON in place and keep Dart number lexemes; handle keys missing
  from old data.
- Dates only through `DartDateTime` / `DartCalendar` and the net-worth month
  helpers; the clock is `AppModel.now`.
- Strings compare as UTF-16 where Dart does; money goes through `model.moneyFormatter`.
- Every ported calculation has a Dart-oracle fixture, and store-format changes
  pass `native/scripts/verify-swift-output-in-dart.sh <dir>` (New York,
  Santiago, Beirut); any difference
  from Flutter goes in `PARITY_GAPS.md`.
- Every animation has a Reduce Motion path, VoiceOver labels, Dynamic Type via
  the design system's text styles.

## Doc owners

Each topic lives in one doc; put changes there, not in a copy.

| Topic | Owner |
|---|---|
| Cross-cutting rules, decisions | [`FULL_APP_PLAN.md`](native/docs/FULL_APP_PLAN.md) section 3 |
| Store format (v2 file, checksum, backup) | [`MIGRATION_SPEC.md`](native/docs/MIGRATION_SPEC.md) section 4 |
| Preferences and legacy keys | [`MIGRATION_SPEC.md`](native/docs/MIGRATION_SPEC.md) sections 3 and 8 |
| Differences from Flutter | [`PARITY_GAPS.md`](native/docs/PARITY_GAPS.md) |
| Screens | [`UI_SPEC.md`](native/docs/UI_SPEC.md) |
| Upgrade verification and audit | [`UPGRADE_VERIFICATION.md`](native/docs/UPGRADE_VERIFICATION.md) |
| Tasks that need a physical device | [`REAL_DEVICE_CHECKLISTS.md`](native/docs/REAL_DEVICE_CHECKLISTS.md) |

## Read first

1. This file.
2. `FULL_APP_PLAN.md` section 3 (the rules).
3. The `MIGRATION_SPEC.md` section for the data you touch (store format s4,
   dates s7, legacy migration s8).
4. The `UI_SPEC.md` section for the screen you change.
5. `PARITY_GAPS.md` before changing anything Flutter also does.

Before calling native work done:

```bash
cd native/BudgieCore && swift test
cd native && xcodegen generate   # then build for a simulator with zero warnings
```

plus the UI tests for what changed (`native/scripts/ui_flow.sh`, and
`native/scripts/system_flow.sh <Flutter Runner.app>` when quick actions,
deep links, the widget or the scene delegate change). `ui_flow.sh` does not
run `BackupUITests` or `CSVImportUITests`: they pick files from the
simulator's "On My iPhone", so on an erased, booted simulator run
`native/scripts/stage_import_fixtures.sh <UDID>` first, then those classes
with `xcodebuild test -only-testing:BudgieUITests/BackupUITests` (or
`CSVImportUITests`). They replace the app's data and skip themselves on a
store UI tests did not make. Build the Flutter `Runner.app` for
`system_flow.sh` with `native/scripts/upgrade_rehearsal.py --build-only`.
The Dart tooling
(`ParityHarness/run.sh`, `verify-swift-output-in-dart.sh`, `ui_flow.sh`'s
store check, `upgrade_rehearsal.py`) needs the Flutter SDK and builds from
the `flutter-final` tag.

## Things to avoid

- Don't introduce a backend / network layer without an explicit ask. This app
  is offline-first by design.
  - One deliberate exception: voice entry sends the recording and its
    transcript to OpenAI (plan D11, `native/docs/FULL_APP_PLAN.md` section 6).
    The key comes from the gitignored `native/Config/Secrets.xcconfig`, never
    committed files.
- Don't break reading of Flutter-written stores or `flutter.`-prefixed
  preferences; 3.4.0 users can still upgrade directly.
