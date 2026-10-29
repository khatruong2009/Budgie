> Archived; paths refer to the `flutter-final` tag.

# Design system, typography, shell, shared components: analysis for the Swift replacement

All paths relative to W = `.../swiftui-mvp-migration-71aa05`. Flutter paths are under `budget_app/lib` unless noted. Nothing was edited. `native/docs/research/G_ui_inventory.md` already covers much of this; I re-verified it against source and add the SwiftUI plan. The screenshots in `native/docs/research/screenshots/` (05_home_data_dark, 10_more_dark) confirm the look.

---

## 1. Token inventory

### 1.1 Colours (`theme/app_colors.dart`)

"Swift" column = what `native/Budgie/Views/Theme.swift` already has. Theme.swift has only six tokens plus a category-token switch:
- Light/dark tokens: accent, income, expense, warning, background, card.
- Category token colours: blue, purple, cyan and pink.

| Token | Light | Dark | Src line | Swift |
|---|---|---|---|---|
| background (scaffold/canvas) | F9FAFB | 0A0A12 | 113, 118 | yes |
| card (card/dialog/sheet fill) | FFFFFF | 13131F | 114, 119 | yes |
| surface (dark input fill) | FFFFFF | 15151F | 112, 117 | no |
| chipSurface (pills, month pill) | F1F1F7 | 15151F | 25, 33 | no |
| cardBorder | ink 101020 @8% | white @7% | 22, 31 | no |
| hairline (list dividers) | 101020 @6% | white @6% | 23, 32 | no |
| border (generic) | E5E7EB | white @7% | 134-135 | no |
| track (progress inset) | E9E9F1 | 1B1B2C | 17, 28 | no |
| trackSecondary | D9D9E6 | 2A2A3E | 18, 29 | no |
| donutRemainder | C9C9DA | 3A3A52 | 19, 30 | no |
| textPrimary | 111827 | F2F2FA | 122, 128 | no |
| textSecondary | 6B7280 (Swift 626977, WCAG AA) | 9A9AB5 | 123, 129 | no |
| textTertiary | 9CA3AF (Swift 686F7A, WCAG AA) | 5C5C78 (Swift 81829F, WCAG AA) | 124, 130 | no |
| onAccent | FFFFFF | 0A0A12 | 14, 42 | no |
| accent | 6366F1 (Swift 5453DD, WCAG AA) | 818CF8 | 7, 13, 35 | yes |
| income/success | 10B981 (Swift 07744F, WCAG AA) | 34D399 | 88, 103 | yes |
| expense/danger/error | EF4444 (Swift C60D21, WCAG AA) | FB7185 | 15, 92, 108 | yes (as `expense`) |
| warning | F59E0B (Swift 8F5B05, WCAG AA) | FBBF24 | 98, 107 | yes |
| info/neutral | 3B82F6 | 60A5FA | 96, 105 | only as the "blue" token |
| pink | F0ABFC | F0ABFC | 16 | not dynamic |
| dockInactiveIcon | 6B7280 (Swift 636A78, WCAG AA on the track) | 8A8AA8 | 20; `floating_dock.dart:243` | no |
| dockBackground | white @88% | 13131F @88% | 21; `floating_dock.dart:155` | no |
| dockBorder | black @8% | white @10% | `floating_dock.dart:158` | no |
| gauge thumb | white + 2pt accent@60% border | F2F2FA | `glow_progress_bar.dart:104-111` | no |
| split-bar gradient | 2AB98A to 34D399 | same | `glow_progress_bar.dart:159,169` | no |
| primary dark/light | 4F46E5 / 818CF8 (Swift `primary` itself: 5453DD in both modes, was 6366F1) | | 8-9 | no |

- **Gradients (135 degrees, topLeft to bottomRight)** (137-197):

| Gradient | Light | Dark |
|---|---|---|
| primary | 6366F1 to 8B5CF6 (Swift 5F61EC to 8757F1) | 4F46E5 to 7C3AED |
| income | 10B981 to 34D399 (Swift 006E4B to 05875E) | 059669 to 10B981 (Swift 056647 to 04875D) |
| expense | EF4444 to F87171 (Swift C2021D to CC4A4D) | DC2626 to EF4444 (Swift CC0716 to DF3337) |
| amber | F59E0B to F97316 | FBBF24 to FB923C |
| blue | 3B82F6 to 60A5FA | 2563EB to 3B82F6 |

  - Swift (2026-09-30, owner-approved): the gradients sit behind white labels, so both stops of the primary, income and expense gradients were darkened until white reaches 4.5:1 (the Flutter stops are given above in brackets); see UI_SPEC "Accessibility audit".
  - They are only used by the legacy `AppButton.primary`, the Add Expense/Income buttons and `ModernAppBar`.
  - `MonthSelector` chips use a primary-to-primary@80% gradient.
- **Chart/category palette:** 14 colours per mode (200-241). Light is 6366F1, 8B5CF6, 10B981, 34D399, EF4444, F87171, F59E0B, FBBF24, 3B82F6, 60A5FA, EC4899, F472B6, 14B8A6, 2DD4BF. Dark is the lighter set at 224-237. The Spend donut ranks accent, income, danger, warning, info, pink first (per G).
- **Opening screen (dark only):** vertical gradient 0A0A12 to 0F0F18 (`main.dart:495-496`).
- **Glow helpers:**
  - `glow(color, blur=24, alpha=.55)` (58-72): dark is a pure halo with no offset. Light replaces it with colour@25%, blur x0.6, offset (0,4).
  - `textGlow(blur=48, alpha=.45)` (76-85): light alpha x0.4.

### 1.2 Spacing, radii, sizes (`design_system.dart`)

| Group | Values | Lines |
|---|---|---|
| spacing | 2, 4, 8, 16, 24, 32, 48, 64 | 31-38 |
| radius | 4, 8, 12, 16, 20, 24, 999 | 41-47 |
| icon | 16, 20, 24, 32, 48, 64 | 50-55 |
| touch | 44, 44, 48, 56 | 58-61 |
| border widths | 1, 1.5, 2 | 123-125 |
| opacity | disabled .38, muted .60, subtle .87 | 128-131 |
| max content width | 600 | 146 |

Legacy shadows (64-102) are black at alpha/blur/dy of .05/2/1, .08/4/2, .10/8/4, .12/16/8 and .15/24/12.

Redesign literals (not tokenised in Dart, so define them in Swift):
- Page horizontal padding is 20. Header row padding is (20,12,20,0) (`budgie_header.dart:55,67`). Section gap is about 28.
- `GlowCard`: padding 20, radius 26 (22 for stat chips), 1pt border (`glow_card.dart:34-35`). Press scale is 0.98 over 120ms.
- `GlowListCard`: padding 8, hairline inset 12 (121, 129).
- `IconTile`: 40 with radius 14, or 44 with radius 16. Icon 20, weight 500. Fill is colour@13% (156-169).
- `GlowFab`: 54 (mic FAB 44). Right 20, bottom `dockBottom+72`. Icon = 0.48 of size.
- Sheets: top radius 28 (`spending_page.dart:241`), card fill plus card border. Flow sheets use 24.
- Logo mark: 36 with radius 12.
- Progress bars: height 8 (budgets), 6 (categories), 12-16 (comparisons), 14 (Home gauge with inset 2 and thumb).
- `ProgressRing`: 72/84 with thickness 8/9.
- Split bar: height 16, gap 3.
- `PillChip`: padding (10,5). `PillButton`: height 52 (44 compact).
- `MonthPill`: padding (16,9), text 14/600, chevron 16.
- Dock: padding 8, inter-button gap 2, button height 44, horizontal padding 12 inactive / 16 active, icon 20, label gap 7.

### 1.3 Shadows, glows, blur

| Element | Value | Source |
|---|---|---|
| Dock | blur sigma 20 plus fill; shadow black 60% (light 15%), blur 40, dy 16 | `floating_dock.dart:180-193` |
| Dock active button | glow(accent, α.6) | 257-259 |
| FAB | glow(blur 32+14·flare, α.55+.25·flare) plus black@50% blur 28 dy 12 | `glow_fab.dart:133-145` |
| Progress fill | glow blur 12 α.6 | `glow_progress_bar.dart:85` |
| Gauge thumb | glow blur 12 α.8 | `glow_progress_bar.dart:112` |
| Split bar | blur 14 α.5 | `glow_progress_bar.dart:150` |
| Progress ring | blur 28, α = glowAlpha(.4)·t | `progress_ring.dart:61` |
| Filled PillButton | blur 20 α.45 | `pill_chip.dart:131` |
| Hero number | text glow blur 48 α.45 | per G |
| Legacy ElevatedCard | Material elevation 2, black@10% | `design_system.dart:306+` |

- `ModernAppBar` uses sigma 10 (legacy, one screen).
- Flutter `BoxShadow.blurRadius` is 2x sigma, and CALayer/SwiftUI `.shadow(radius:)` is also 2x sigma, so values should carry over 1:1. Verify by eye.

### 1.4 Typography (`theme/app_typography.dart`)

Both fonts have a natural line height of exactly 1.2 x size:
- Gabarito: hhea 940/-260, upm 1000.
- Spline Sans Mono: 1927/-473, upm 2000.

To port a Flutter `height: h`:
- Multi-line text: `.lineSpacing(size*(h-1.2))`.
- Single line: pin the frame height to `size*h`. Hero 58 at h=1.0 is 11.6pt tighter than SwiftUI's default. Verify how negative `lineSpacing` behaves on iOS 17.

Redesign styles (lines 14-216). Family G = Gabarito, M = Spline Sans Mono. Tabular = OpenType `tnum`; Gabarito has `tnum` and `pnum`. Spline has no `tnum`, but it is monospaced anyway.

| Style | Fam | Size/weight | Tracking | h | tab. | Line |
|---|---|---|---|---|---|---|
| hero | G | 58/800 | -2 | 1.0 | y | 14 |
| heroDecimals | G | 32/700 | 0 | 1.0 | y | 24 |
| heroMedium | G | 48/800 | -1.8 | 1.0 | y | 33 |
| heroSmall | G | 34/800 | -1 | 1.1 | y | 43 |
| pageTitle | G | 26/800 | -0.6 | 1.2 | | 53 |
| sectionHeader | G | 20/700 | -0.3 | 1.2 | | 62 |
| cardTitle | G | 17/700 | 0 | 1.25 | | 71 |
| goalTitle | G | 18/700 | -0.3 | 1.25 | | 79 |
| rowTitle | G | 15/600 | 0 | 1.25 | | 88 |
| rowSubtitle | G | 12/400 | 0 | 1.25 | | 96 |
| amount | G | 16/700 | 0 | 1.2 | y | 104 |
| amountSmall | G | 15/700 | 0 | 1.2 | y | 113 |
| chipAmount | G | 24/700 | -0.5 | 1.15 | y | 122 |
| metricAmount | G | 24/800 | -0.5 | 1.15 | y | 132 |
| badge | G | 12/700 | 0 | 1.2 | | 142 |
| badgeSmall | G | 11/700 | 0 | 1.2 | | 150 |
| eyebrow (UPPERCASE) | M | 11/600 | 2.4 | 1.2 | | 158 |
| eyebrowTight | M | 11/600 | 2 | 1.2 | | 167 |
| monoLabel | M | 11/500 | 1 | 1.2 | | 176 |
| monoLink | M | 11/600 | 1.5 | 1.2 | | 185 |
| monoMetricLabel | M | 10/600 | 1.6 | 1.2 | | 194 |
| monoAxis | M | 10/500 | 0 | 1.2 | | 203 |
| monoMonth | M | 11/500 | 0 | 1.2 | | 211 |

Legacy styles (218-366) inherit Gabarito from `ThemeData.fontFamily` (`main.dart:66,108`). They are still used by forms, dialogs, the lock screen, the init-error screen, Recurring and the Transactions list.

| Style | Size/weight | Tracking | h |
|---|---|---|---|
| displayLarge | 34/bold | -0.5 | 1.2 |
| displayMedium | 28/bold | -0.3 | 1.2 |
| displaySmall | 24/bold | -0.2 | 1.3 |
| headingLarge | 28/bold | -0.3 | 1.2 |
| headingMedium | 22/600 | -0.2 | 1.3 |
| headingSmall | 20/600 | -0.1 | 1.3 |
| bodyLarge | 17/400 | -0.4 | 1.5 |
| bodyMedium | 15/400 | -0.2 | 1.5 |
| bodySmall | 13/400 | -0.1 | 1.4 |
| button/label L / M / S | 17 / 15 / 13, all 600 | -0.4 / -0.2 / -0.1 | 1.2 (label 1.3) |
| caption | 13/400 | -0.1 | 1.4 |
| captionSmall | 11/400 | 0 | 1.3 |
| numeric L / M / S | 34/bold, 22/600, 17/600 | | tabular |

Weights actually used in the codebase:

| Weight | Count |
|---|---|
| w600 | 50 |
| w700 | 23 |
| w800 | 11 |
| w500 | 8 |
| w400 | 8 |
| bold | 8 |
| w300 | 1 (falls back to Regular) |

Nothing uses w900, so Gabarito-Black can be skipped.

### 1.5 Motion (`theme/app_animations.dart`, plus literals)

Durations: fast 150, normal 300, slow 500, verySlow 800. Shimmer is 1500. Chart is 1200 (unused by the redesign).

Curve mapping to SwiftUI:

| Flutter | SwiftUI |
|---|---|
| easeOut | `.easeOut` (same cubic 0,0,.58,1) |
| easeInOut | `.easeInOut` |
| easeInOutCubic | `.timingCurve(0.645,0.045,0.355,1,duration:)` |
| fastOutSlowIn | `.timingCurve(0.4,0,0.2,1,...)` |
| easeOutBack (FAB entry) | `.timingCurve(0.175,0.885,0.32,1.275,...)` or `.spring(duration:0.3,bounce:0.25)` |
| elasticOut / bounceOut | unused by the redesign; use `.bouncy` |

In-use values:

| Item | Value |
|---|---|
| Dock morph | 250ms easeOut (100ms while drag-selecting) |
| Tab slide | 300ms easeInOut (`home_page.dart:77`); drag = `jumpToPage`, no animation |
| GlowCard press | 0.98 / 120ms |
| PillButton press | 0.96 / 120ms |
| FAB | entry 300ms easeOutBack; press 0.95 / 120ms; tap burst 500ms (ping ring scale 1+0.7·easeOut, alpha .55·(1-ping), stroke 2; glow flare sin(π·t); icon pop 1+0.22·flare) |
| GlowProgressBar | 800ms easeInOutCubic from 0 on first build |
| ProgressRing | 900ms easeInOutCubic |
| Segmented control | 200ms easeOut |
| Hero digits | 900ms roll |
| Opening screen | intro 1400ms, dots 1200ms loop, handoff `AnimatedSwitcher` 450ms (`main.dart:241`) |

- Reduce Motion is honoured in GlowProgressBar, ProgressRing, GlowFab's burst and the month panel.
- Haptics (`utils/micro_interactions.dart`): light = taps (cards, pills, FAB, header links), medium = long-press or swipe threshold, heavy = delete, selection = dock, segments and pickers.
  - SwiftUI: `.sensoryFeedback(.impact(weight: .light), trigger:)`, `.impact(weight: .medium)`, `.impact(weight: .heavy)` and `.selection`.

---

## 2. Shell

### 2.1 Flutter (`home_page.dart`, `main.dart`)

- **Tabs:** 6, not 5 (AGENTS.md is stale). Each hosts its own nested `Navigator` inside a `PageView` (`NeverScrollableScrollPhysics`).

| # | Label | Icon (Material Symbols Rounded) | Page |
|---|---|---|---|
| 0 | Home | `paid` | SpendingPage |
| 1 | Worth | `donut_small` | NetWorthPage |
| 2 | Goals | `flag` | SavingsGoalsPage |
| 3 | Spend | `pie_chart` | CategoryPage |
| 4 | Flow | `bar_chart` | HistoryPage |
| 5 | More | `settings` | SettingsPage |

- **Layout:** `Scaffold` body is a Column with `UnsavedChangesBanner` on top, then Expanded holding a Stack of the PageView and the dock (`home_page.dart:97-160`).
  - The dock is `Positioned(bottom: max(20, safeBottom))`, centred.
  - The dock is outside the Navigators, so it stays visible on pushed pages. Pages pad their scroll content by `DockMetrics.contentBottomPadding` (= bottom offset + 96).
  - Sheets and dialogs use `useRootNavigator: true` (`spending_page.dart:160`), so they cover the dock.
- **Nested pushes:**

| From | To | Route | Line |
|---|---|---|---|
| Home | TransactionPage (SEE ALL) | Material | `spending_page.dart:68` |
| Worth | account history | Material | `net_worth_page.dart:174` |
| Flow | detail | Material | `history_page.dart:432` |
| Spend | CategoryTransactionsPage | Cupertino | `category_page.dart:311` |
| More | Categories | Cupertino | `settings_page.dart:639` |
| More | Tags & rules | Cupertino | `settings_page.dart:657` |
| More | Recurring transactions | Cupertino | `settings_page.dart:759` |

  - Page transitions are Cupertino on iOS (`main.dart:96-104`), so swipe-back works.
- **Not kept alive:** grep finds no KeepAlive in the tab roots; only `transaction_page.dart:213` mentions `addAutomaticKeepAlives: false`. Off-screen tabs are therefore likely disposed, so scroll position and pushes reset on a tab switch. G claims "kept alive". Verify in the simulator before deciding parity.
- **Dock behaviour** (`floating_dock.dart`):
  - Tap selects and slides the page over 300ms.
  - Horizontal drag, or long-press then drag, selects the tab under the finger; the nearest button wins in gaps. It uses `jumpToPage` with a selection haptic per change (88-135, 162-177).
  - The active button morphs from a 44x44 icon circle into an accent pill with icon (filled variant, FILL=1) plus a 13/700 label. The label's text scale is clamped to 1.2.
  - Dark fill is 13131F@88%, light is white@88%, over a sigma-20 blur.
- **Unsaved banner:**
  - It is a full-width Material strip in the Column above the pages, so it pushes them down.
  - Colour is `getDanger` (FB7185 dark, EF4444 light). Icon is `cloud_off_rounded`, text and button are white, and it has a top SafeArea.
  - Copy is "Some changes are not saved to this device yet." plus a "Retry" TextButton.
  - It shows when either `TransactionModel` or `RecurringTransactionModel` has unsaved changes, and retry calls both `retryPendingSaves`.
  - Quirk: pages still add their own top SafeArea under it, so there is a small extra gap. Swift's `safeAreaInset` avoids this.
- **Quick actions and deep links** (`main.dart:327-394`):
  - They wait for init, then open the add form on the root navigator over whatever tab is current. They do not switch tabs.
  - Deep links are de-duplicated within 2s.
  - Swift `MainView.onChange(pendingAdd)` forces `tab = .spending`, which deviates from Flutter.
- **Root chain:**
  - `MaterialApp` with light and dark `ThemeData` (`main.dart:63-146`) and `themeMode` from `ThemeProvider`.
  - `_OpeningScreen` → `AppPrivacyGate` → `OnboardingTutorialGate` → `BudgetHomePage`.
  - Init failure shows the error screen (`main.dart:411`).
  - Swift already mirrors the phase logic in `RootView`; only the visuals differ.
- **Theme mode:** stored as `system`/`light`/`dark` (`theme_provider.dart`). Swift already handles this via `window.overrideUserInterfaceStyle` (`BudgieApp.swift`), so dynamic `UIColor` tokens and sheets resolve correctly.

### 2.2 Swift MVP versus Flutter

| | Swift (`MainView.swift`, `RootView.swift`) | Flutter |
|---|---|---|
| Tabs | 5 native `TabView`: Spending, History, Net Worth, Recurring, Settings | 6 dock tabs (see above). Recurring is a pushed page under More; Swift `HistoryView` (a transaction list) corresponds to Flutter's TransactionPage under "SEE ALL", not the Flow tab. |
| Bar | system tab bar, accent tint | floating blurred capsule, drag-select, morphing label |
| Nav | each tab is `NavigationStack` with large or inline title, native List | custom `BudgieHeader`, nav bar hidden, ScrollView of cards |
| Banner | `safeAreaInset(.top)` with `.bar` material, warning icon, copy "Some changes aren't saved yet." | solid danger strip, white text, cloud_off, copy "...not saved to this device yet." |
| Add sheet | forces the Spending tab | keeps the current tab |
| Opening | `ProgressView()` | animated brand screen |
| Lock/privacy | plain Theme.background, 96pt logo, system button | opaque 0A0A12 cover (72pt mark, "Budgie", "App preview hidden") and lock screen ("Budgie is locked", primary AppButton with a fingerprint icon and an optional "Disable App Lock") |

---

## 3. Shared widgets

Usage counts are grep matches outside `widgets/`, `design_system.dart` and `utils/`. "Dart uses" lists the files.

| Flutter widget (file:line) | Look and behaviour, props | Uses | SwiftUI proposal |
|---|---|---|---|
| **GlowCard** (`glow_card.dart:11`) | 13131F fill, radius 26, 1pt border, padding 20; press scale .98 (120ms) and light haptic; props `padding, radius, color, border, gradient, boxShadow, onTap, onLongPress`; long-press-only cards get no press feedback | 32 in 9 files | `GlowCard { content }` with `padding`, `radius`, `fill: AnyShapeStyle?`, `border: Color?`, `glow: GlowStyle?`, `onTap`, `onLongPress`. Body is `.background(fill, in: RoundedRectangle(cornerRadius:, style: .continuous))` plus a `.strokeBorder` overlay. The tap variant uses a `ButtonStyle` with `configuration.isPressed` → `scaleEffect(0.98)` and `.animation(.easeOut(duration:0.12))`. Use `.continuous` corners. |
| **GlowListCard** (`:110`) | GlowCard with padding 8 and 1pt hairline dividers inset 12 between children | 14 in 6 files | `GlowListCard { ... }` using `_VariadicView` or an `Group(subviews:)` equivalent. On iOS 17, `ForEach(Array(children.enumerated()))` with an explicit `[AnyView]` or `@ViewBuilder` plus a `Divider`-style helper is simpler. |
| **IconTile** (`:142`) | rounded square, colour@13% fill, 40 (44) with radius 14 (16), icon 20 weight 500 | 21 in 7 files | `IconTile(symbol:, color:, size:=40, radius:, iconSize:=20, background:)`. This supersedes `CategoryIcon` in Theme.swift, which uses 15% opacity and radius 0.3·size. |
| **GlowFab** (`glow_fab.dart:13`) | 54 accent circle, dual shadow, entry easeOutBack, press .95, tap burst (ping ring, glow flare, icon pop); `onPressed`, `onLongPress`, `icon`, `semanticLabel`, `size`; skips burst under Reduce Motion | 5 in 3 files | `GlowFab(symbol:, size:=54, label:, action:, longPress:)`. Use `.keyframeAnimator(initialValue: BurstState, trigger: tapCount)` for ping, flare and pop (iOS 17). Entry via `.scaleEffect` with a timing curve on appear. `.sensoryFeedback(.impact(weight:.light))`. `.accessibilityLabel`. |
| **GlowProgressBar** (`glow_progress_bar.dart:7`) | pill track, glowing fill, optional gradient, thumb, track border, inset; 800ms from 0; clamps to 0..1 and NaN to 0 | 7 in 4 files | `GlowProgressBar(value:, height:=8, color:, track:, gradient:, showThumb:, trackBorder:, fillInset:)`. `GeometryReader` plus `Capsule`. Animate with `.animation(.timingCurve(.645,.045,.355,1,duration:.8), value:)`; use a `@State shown` set in `onAppear` to reproduce the animate-from-0 behaviour. Glow via `.shadow(color: color.opacity(0.6), radius: 12)`. |
| **SplitGlowBar** (`:129`) | assets (green gradient) and liabilities (rose) segments, 3pt gap, glowing | 1 | `SplitGlowBar(assetsFraction:)`, two Capsules in an `HStack(spacing:3)` with `frame(maxWidth:)` weights. |
| **ProgressRing** (`progress_ring.dart:10`) | track ring, arc from 12 o'clock with butt caps, inner card disc, glow blur 28 scaled by t; 900ms | 2 | `ProgressRing(value:, size:, thickness:, color:, inner:, glowAlpha:, content:)`. `Circle().inset(by: thickness/2).trim(from:0,to:t).stroke(style: .init(lineWidth: thickness, lineCap: .butt)).rotationEffect(.degrees(-90))`. Easy. |
| **BudgieHeader** (`budgie_header.dart:11`) | row with title (pageTitle) or 36pt logo (r12) and a trailing pill, or centred trailing plus 36pt spacer; padding (20,12,20,0) | 7 | `BudgieHeader(title:, showLogo:, centerTrailing:, trailing:)`. Needs the logo asset (`logo` imageset exists in the app catalog; Flutter uses `assets/budgie_mark.png`, 512x512). |
| **MonthPill** (`:80`) | chipSurface fill, 1pt border 8%, "Label" plus chevron, light haptic on tap | 5 in 3 files | `MonthPill(label:, action:)`. |
| **SectionHeader** (`:136`) | sectionHeader title plus optional mono accent link ("EDIT"/"SEE ALL"), 4pt inset, baseline-aligned | 3 | `SectionHeader(_ title, link: String?, action:)`, `HStack(alignment: .firstTextBaseline)`. |
| **BudgiePageScaffold** (`budgie_page_scaffold.dart:9`) | Scaffold plus optional FAB pinned right 20 / bottom dock+72 | 7 | Replace with a page modifier: `.budgiePage(fab: { ... })`. It sets the background and applies `contentMargins` for the dock (2.3). |
| **PillChip** (`pill_chip.dart:8`) | tinted (colour@14%) or outlined (@40%) badge, optional 15pt icon, optional tap | 11 in 5 files | `PillChip(_ label, color:, outlined:, symbol:, font:, padding:, action:)`. |
| **PillButton** (`:73`) | 52 (44 if filled) capsule, tint@10% plus border@35% or accent-filled with glow; press .96; weight 700; 15 (14 filled) | 11 in 3 files | `PillButton(title, symbol:, color:, filled:, height:, action:)` via a `ButtonStyle`. |
| **SegmentedPillControl** (`:163`) | 3pt-padded track, accent-filled active segment, 200ms; mono variant with a transparent track and accent@18% active fill (range pills) | 5 in 4 files | `SegmentedPills(_ items:, selection:, mono:)` with `matchedGeometryEffect` for the selected background, `.sensoryFeedback(.selection, trigger: selection)`, `Text` in `rowSubtitle` or `monoLink` with tracking 0. |
| **EmptyState** (`empty_state.dart:12`) | legacy: 64pt icon, title (headingMedium), message, optional `AppButton.primary`; types noData/noResults/error with default copy | 5 in 3 files (`category_page`, `category_transactions_page`, `transaction_page`) | `EmptyStateView(kind:, symbol:, title:, message:, actionTitle:, action:)`; or `ContentUnavailableView` styled with the tokens. |
| **MonthSelector** (`month_selector.dart:7`) | legacy horizontal strip of 120x64 month chips (primary gradient when selected, radius 12, "MMM" + year) | 2 (`net_worth_page.dart:111`, `transaction_page.dart:73`) | `MonthChipStrip(months:, selection:)` with `ScrollViewReader.scrollTo(anchor:.center)` on change. The Swift MVP's chevrons-and-menu selector is a different pattern, so decide (see section 6). |
| **RecurrenceIndicator** (`recurrence_indicator.dart:6`) | 16x9.6 custom-painted double-arrow oval, 1.5 stroke | 2 (`category_transactions_page`, `recurring_transactions_page`) | Port the cubic paths to a `Shape`, or use `arrow.triangle.2.circlepath` at 12pt. |
| **ModernTransactionListItem** (`modern_transaction_list_item.dart:13`) | legacy row on `ElevatedCard`: 48 solid tile (income or expense colour), description plus recurrence glyph, "Category . MMM d", amount in headingMedium; swipe left to delete via `Dismissible` (medium haptic on the threshold, Cupertino confirm, heavy haptic on delete); VoiceOver label via `AccessibilityUtils` | 1 (`transaction_page.dart`, reached by Home > SEE ALL) | `TransactionRow(record:, onTap:, onDelete:)`. See "Hard to replicate" (swipe). VoiceOver label: "description, expense of 12 dollars and 30 cents, category X, on <date>". |
| **ModernTextField** (`modern_text_field.dart:5`) | legacy: fixed caption label above, card fill, radius 12, border 1.5 (2 focused), primary focus colour, error colour with icon and message | 4 (`transaction_form.dart`, `recurring_transaction_form.dart`) | `BudgieField(title:, text:, prompt:, keyboard:, symbol:, error:)` using `@FocusState`. Must keep the decimal keyboard and the locale-separator parsing from `TransactionFormView`. |
| **ModernAppBar** / **ModernSliverAppBar** (`modern_app_bar.dart:7,142`) | legacy indigo-gradient AppBar with sigma-10 blur; used only by Recurring | 1 / 0 | Drop; restyle Recurring to `BudgieHeader`. |
| **ElevatedCard** (`design_system.dart:306`) | legacy Material card | 1 (`recurring_transactions_page.dart`) | Use `GlowCard`. |
| **AppButton** (`design_system.dart:386`) | legacy: primary gradient or outlined secondary; S/M/L = 44/48/56 with radius 12; loading spinner; press .95 | 9 in 5 files (`main.dart`, `spending_page`, `recurring_transactions_page`, `transaction_form`, `recurring_transaction_form`) | `BudgieButton` via `ButtonStyle` (`.primary/.secondary`, sizes, `isLoading`). Or reuse the filled `PillButton`. |
| **AnimatedMetricCard**, **LoadingShimmer**, **AccessibilityUtils** (standalone) | unused, plus legacy | 0 | Skip all three. For loading use `ProgressView` or `.redacted(reason: .placeholder)`. |
| **UnsavedChangesBanner** (`unsaved_changes_banner.dart:14`) | see 2.1 | 1 (`home_page.dart:99`) | Restyle the existing struct to danger fill, white content, `cloud.slash` symbol. Fill `Theme.danger.ignoresSafeArea(edges:.top)`. Flutter copy is "Some changes are not saved to this device yet."; Swift uses different copy (UI_SPEC). Pick one. |
| **AppPrivacyGate** (`app_privacy_gate.dart:12`) | cover and lock screen as in 2.2; `AbsorbPointer` plus `ExcludeSemantics` while locked | 1 | Existing `AppLock.swift` logic is fine; restyle `PrivacyCover`/`LockScreen` (opaque 0A0A12 for the cover, 72pt mark, headingLarge "Budgie is locked", filled accent button). |
| **FloatingDock** / **DockItem** / **DockMetrics** (`floating_dock.dart`) | see 2.1 | 1 / 1 / 12 | see 3.1 |
| **MicroInteractions** (`utils/micro_interactions.dart`) | haptics; desktop hover helpers | 32 in 8 files | `Haptics` is not needed. Use `.sensoryFeedback` per view. |
| **CategoryDonutChart, LocalInsightsSection, VoiceRecordingSheet** | out of my area | n/a | belong to other analysts |

`platform_enhancements.dart` and `platform_utils.dart` are Android/desktop/web plumbing. The only iOS-relevant behaviours are bouncing scroll (SwiftUI default) and amount-keyboard config: decimal pad, autocorrect off, sentence capitalisation for descriptions.

### 3.1 Dock and shell sketches

```swift
struct DockItem: Identifiable { let id: Int; let symbol: String; let filled: String; let label: String }

struct DockMetrics { // injected at the root via .environment(\.dockMetrics, ...)
    let safeBottom: CGFloat
    var bottomOffset: CGFloat { max(20, safeBottom) }          // from screen edge
    var fabBottomOffset: CGFloat { bottomOffset + 72 }
    var contentBottomPadding: CGFloat { bottomOffset + 96 }
}

struct FloatingDock: View {
    let items: [DockItem]; @Binding var selection: Int
    @State private var frames: [Int: CGRect] = [:]; @State private var dragging = false
    // Capsule: padding 8, spacing 2. Button: 44 high, 12/16 hpad, 20pt icon, 13/700 label (gap 7), .dynamicTypeSize(...DynamicTypeSize.xLarge) for the clamp.
    // Background: Capsule().fill(dockFill) over .ultraThinMaterial; strokeBorder 1pt; .shadow(black .6/.15, radius 40, y 16).
    // Gesture: .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("dock")))
    //   pick the button under x (nearest if in a gap); on change: selection = idx (no animation while dragging).
    //   Buttons are plain views with .accessibilityAddTraits(.isButton) / .accessibilityLabel; do not nest Buttons (they would swallow the drag).
    // Selection morph: .animation(.easeOut(duration: dragging ? 0.1 : 0.25), value: selection); label appears/disappears with .transition or an HStack width change.
    // Haptic: .sensoryFeedback(.selection, trigger: selection)
}
```

- The dock frames via `PreferenceKey` or `onGeometryChange` (the latter is iOS 18 only). Use a `PreferenceKey`.
- **Host:** a custom `DockedTabHost` instead of `TabView`. It is a ZStack of six pages, each in its own `NavigationStack`, plus the dock as an `overlay(alignment: .bottom)` on the container with the bottom padding computed from `DockMetrics`.
  - It is outside the stacks, so it stays over pushed pages, and sheets presented from anywhere cover it, both as in Flutter.
  - Page reservation: `safeAreaInset(edge:.bottom){ Color.clear.frame(height: ...) }` on the host, or `.contentMargins(.bottom, dock.contentBottomPadding, for: .scrollContent)` per ScrollView (iOS 17).
- **Tab switch options:**
  1. Slide only old and new pages, 300ms easeInOut, no animation while dragging. Recommended: close to Flutter without building intermediate pages.
  2. A true `offset(x: -index*width)` HStack. This needs all pages built (Flutter builds intermediate ones), which is heavy for the roughly 2,700-line net worth view.
  3. `TabView` with `.toolbar(.hidden, for: .tabBar)` plus the custom dock. Keep-alive, lazy and cheap but no slide; a crossfade is acceptable.
- **State handling:** lazily instantiate each page on first visit and keep it. This is better UX than Flutter's (likely) reset. Flag it as a deviation.
- `.ignoresSafeArea(.keyboard)` on the host so the dock does not ride up over the keyboard.

---

## 4. Font plan

- **Files:** `budget_app/assets/fonts/` holds 6 Gabarito static TTFs (Regular, Medium, SemiBold, Bold, ExtraBold, Black; 100 KB each) and 3 Spline Sans Mono TTFs (Regular, Medium, SemiBold; 38 KB each).
  - Bundle 8: **skip Gabarito-Black**, since w900 is unused. Total is about 1.1 MB.
- **PostScript names** (verified with `fc-scan`):

| Weight | Gabarito | Spline Sans Mono |
|---|---|---|
| 400 | `Gabarito-Regular` | `SplineSansMono-Regular` |
| 500 | `Gabarito-Medium` | `SplineSansMono-Medium` |
| 600 | `Gabarito-SemiBold` | `SplineSansMono-SemiBold` |
| 700 | `Gabarito-Bold` | |
| 800 | `Gabarito-ExtraBold` | |

  - The fonts are static, not variable. Medium/SemiBold/ExtraBold have family "Gabarito Medium" etc. (nameID 1), so `Font.custom("Gabarito", size:).weight(...)` is unreliable. Always use the PostScript name per weight, and never `.bold()` on them (synthesised bold).
- **Copy to** `native/Budgie/Resources/Fonts/`. XcodeGen's `sources: - path: Budgie` picks up `.ttf` as resources and flattens them at the bundle root.
- **Info.plist:** `native/Budgie/Info.plist` is generated from `project.yml`. Edit `targets.Budgie.info.properties` and run `xcodegen generate`:

```yaml
UIAppFonts: [Gabarito-Regular.ttf, Gabarito-Medium.ttf, Gabarito-SemiBold.ttf, Gabarito-Bold.ttf, Gabarito-ExtraBold.ttf, SplineSansMono-Regular.ttf, SplineSansMono-Medium.ttf, SplineSansMono-SemiBold.ttf]
```

  - Alternative if you want fonts in previews, unit tests and the widget target: register at launch with `CTFontManagerRegisterFontsForURL`.
  - The widget extension currently uses system fonts. Matching it would need its own UIAppFonts and the files in its target.
- **Dynamic Type:**
  - `Font.custom("Gabarito-ExtraBold", size: 58, relativeTo: .largeTitle)` scales with the user's size. Flutter scales linearly with the system text scale, so ratios differ slightly between text styles. Choose `relativeTo` per style: body for rows, title3 for card titles, largeTitle for hero.
  - Cap the dock label with `.dynamicTypeSize(...DynamicTypeSize.xLarge)`, matching Flutter's 1.2 clamp.
  - For tight layouts (hero numbers, chips) consider `.minimumScaleFactor`.
- **Tabular figures:** Gabarito has `tnum`. Use `.monospacedDigit()` on the custom font, and verify on device that Core Text maps it to OpenType `tnum`. The fallback is a `UIFontDescriptor` with a feature setting.
- **Global font:** apply the body font once at the root (`.font(...)`) so unstyled Text picks it up. System chrome (alerts, confirmation dialogs, menus) stays SF. Nav bar titles need `UINavigationBar.appearance().titleTextAttributes`.
- **Load check:** add a debug/unit check that `UIFont(name:size:)` is non-nil for all eight names. A missing font silently falls back to SF.
- **Licences:**
  - Gabarito: Copyright 2023 The Gabarito Project Authors (github.com/naipefoundry/gabarito), SIL OFL 1.1.
  - Spline Sans Mono: Copyright 2022 The Spline Sans Mono Project Authors (github.com/SorkinType/SplineSansMono), SIL OFL 1.1.
  - Bundling and redistributing is allowed. The OFL requires the copyright notice and licence text to travel with the fonts.
  - Neither repo has an `OFL.txt` (no licence files found in `budget_app/`). Fetch the texts from the upstream repos, add them next to the fonts and surface them in Settings > About > Licences.
  - If you bundle Material Symbols (see risks), that font is Apache 2.0.

---

## 5. Proposed layout and build sequence

### 5.1 File layout (app target; no new packages)

```
Budgie/DesignSystem/
  Tokens/  Colors.swift        (BudgieColor: light/dark dynamic tokens; supersedes Views/Theme.swift)
           Metrics.swift       (spacing, radii, sizes, DockMetrics + environment key)
           Glow.swift          (GlowStyle, .glow(color:blur:alpha:) modifier with the light-mode swap)
           Motion.swift        (curves, durations, reduce-motion helpers)
  Typography/ Fonts.swift      (PostScript names, load check)
              TextStyles.swift (TextSpec + .textStyle(_:) modifier; all 23 redesign styles plus the few legacy ones still needed)
  Components/ GlowCard.swift, IconTile.swift, PillChip.swift, PillButton.swift, SegmentedPills.swift,
              GlowProgressBar.swift, ProgressRing.swift, SplitGlowBar.swift, BudgieHeader.swift (+MonthPill, SectionHeader),
              GlowFab.swift, BudgieField.swift, EmptyStateView.swift, SwipeToDeleteRow.swift, RecurrenceGlyph.swift
  Shell/      DockedTabHost.swift, FloatingDock.swift, BudgiePage.swift (page modifier), UnsavedChangesBanner.swift
  Screens/    OpeningView.swift, PrivacyCover/LockScreen restyles
  Debug/      DesignGalleryView.swift  (#if DEBUG)
Budgie/Resources/Fonts/*.ttf, OFL-*.txt
```

- `Theme.swift` is kept for a step as a shim so views keep compiling, then removed.

### 5.2 Build sequence

| # | Step | Effort |
|---|---|---|
| 1 | Add fonts, UIAppFonts, `Fonts.swift`, the load check; `TextSpec` and all styles; global body font | S-M |
| 2 | Tokens: full colour set (light/dark), metrics, glow modifier, motion curves; `Theme` shim | S |
| 3 | Core primitives: GlowCard, GlowListCard, IconTile, PillChip, PillButton, SegmentedPills, MonthPill, BudgieHeader, SectionHeader | M |
| 4 | Indicators: GlowProgressBar, SplitGlowBar, ProgressRing, GlowFab (with burst) | M |
| 5 | Shell: DockedTabHost, FloatingDock (tap, drag, haptics, blur, safe-area), DockMetrics, `budgiePage` modifier, restyled banner, sheet routing that does not switch tabs | L |
| 6 | DEBUG `DesignGalleryView` showing every component in light, dark and large Dynamic Type; screenshot compare against `native/docs/research/screenshots` | S-M |
| 7 | Restyle existing views (see 5.3): List/Form to ScrollView of cards, custom headers, no system nav bars | L (split by screen) |
| 8 | `OpeningView` (gradient, glow washes, 120pt mark, wordmark, "BUDGET IN BALANCE", pulsing dots, 450ms handoff) and a launch screen that matches (storyboard or asset with gradient and logo) | M |
| 9 | Legacy-form components: BudgieField, BudgieButton, EmptyStateView, SwipeToDeleteRow, month chip strip | M |
| 10 | Accessibility pass (VoiceOver labels on the dock, Dynamic Type, Reduce Motion, contrast) and physical-device check of shadows and scroll performance | S-M |

### 5.3 Existing Swift views that must be restyled

| File | Change |
|---|---|
| `Views/MainView.swift` | replace `TabView` with `DockedTabHost` (6 tabs); banner restyle; do not force the Spending tab on `pendingAdd` |
| `Views/RootView.swift` | `.starting` shows `OpeningView`; StatusScreen and BlockedView use tokens |
| `Views/SpendingView.swift` (342 lines, List/Form) | Home layout: header, hero, gauge, chips, safe-to-spend card, budgets, recent activity, pill buttons, FAB |
| `Views/HistoryView.swift` (215) | becomes the Transactions list page (Home > SEE ALL); Flow tab is new work |
| `Views/NetWorthView.swift` (223) | Worth tab restyle plus editing (other analyst) |
| `Views/RecurringView.swift` (313) | moves under More > Recurring transactions, legacy look becomes redesign |
| `Views/SettingsView.swift` (136) | More tab restyle |
| `Views/SpendingSafeToSpendSheet.swift`, `Views/TransactionFormView.swift` | sheet chrome (card fill, radius 28, indicator), fields |
| `Views/AppLock.swift` | `PrivacyCover` and `LockScreen` restyle |
| `Views/Theme.swift` | superseded by `DesignSystem/Tokens` |
| `Views/DiagnosticsView.swift` | token restyle |

- Tab correspondence: Flutter has no Recurring tab. Swift's History (transaction list) has no Flutter tab either.
- Six tab roots are not in the MVP at all: Goals, Spend, Flow, plus the redesigned Home/Worth/More.

---

## 6. Risks and open questions

**Hard or lossy to replicate on iOS 17**
1. **Swipe-to-delete on custom cards.** `swipeActions` only works in `List` rows and would fight the card and hairline look. A custom `DragGesture` swipe container costs effort and needs a11y actions. Flutter has this only on the legacy transaction row.
2. **Rolling digit animation** (`animated_digit`, 900ms). `.contentTransition(.numericText(value:))` is close but not an odometer.
3. **Exact line height.** Single-line 1.0 needs pinned frames; negative `lineSpacing` on multi-line text needs testing.
4. **Sheet border.** `presentationCornerRadius(28)` and `presentationBackground` work; the 1pt top border does not, unless drawn inside the content.
5. **Blur.** No sigma control; `.ultraThinMaterial` under the 88% fill is visually equivalent.
6. **Hidden nav bar on pushed pages.** Hiding the bar can disable the interactive swipe-back gesture. Keep the native bar on pushed pages, or add a UIKit gesture workaround.
7. **Glow shadows.** Every glow is a real blur. It is fine on a handful of elements but costly in long lists; test on device.
8. **Distant tab slide.** Flutter builds the intermediate pages during the animation; option 1 in section 3.1 deviates slightly.

**Decisions for the user**
1. **Icons.** Recommend SF Symbols (native feel) with a mapping table; the Flutter set is Material Symbols Rounded (about 50 distinct glyphs used, weight 500, dock icons filled when active). Some have no exact SF counterpart, e.g. `donut_small`, `paid`, and the more obscure ones. Alternative: bundle a subset of the Material Symbols Rounded variable font (Apache 2.0) for pixel-identical icons at the cost of file size and FILL/wght axis handling. Which do you want?
2. **One visual system or two.** Flutter has the redesign (six tab roots and most sheets) and a legacy Material look (Transactions list, Recurring, Add/Edit form, Categories, Tags, lock screen, init-error screen). G recommends porting everything to the redesign tokens; I agree.
3. **Light mode.** The redesign is dark-first; light values exist but were added later. Do you want light held to the same fidelity as dark?
4. **Tab state.** Flutter (probably) resets tab state on switch; Swift can keep it. Keep-alive is my recommendation.
5. **Quick actions and deep links.** Flutter opens the form over the current tab; the MVP forces the Spending tab. Match Flutter?
6. **Banner copy.** "not saved to this device yet" (Flutter) versus "aren't saved yet" (`UI_SPEC.md`).
7. **Month selector.** The MVP's chevrons and menu versus Flutter's inline wheel panel on Home plus the chip strip on the legacy screens. Which Home pattern do we want?
8. **Keyboard.** Should the dock hide while a text field is focused (Flutter lets it ride up)?
9. **Launch screen.** Flutter's storyboard is gradient plus 120pt logo, and the opening screen matches it for an invisible handoff. Swift's `UILaunchScreen` only takes a colour and an image. Copy the storyboard, or accept a colour-only launch?
10. **Widgets.** Widget extension fonts and colours are separate. Restyle them too?

**Verification items**
- Tab dispose behaviour (Flutter), `monospacedDigit()` mapping to `tnum` on custom fonts, shadow radius parity, negative line spacing.
- The dock has no accessibility labels on inactive buttons in Flutter (icons only); Swift should add labels and selected traits.
- OFL texts are missing from the repo and must be added.
- Every animation needs a Reduce Motion path (progress bars, rings, FAB burst, dock morph, tab slide).

**Key files**
- Flutter: `budget_app/lib/design_system.dart`, `theme/app_colors.dart`, `theme/app_typography.dart`, `theme/app_animations.dart`, `widgets/floating_dock.dart`, `widgets/glow_card.dart`, `widgets/glow_fab.dart`, `widgets/glow_progress_bar.dart`, `widgets/progress_ring.dart`, `widgets/budgie_header.dart`, `widgets/pill_chip.dart`, `home_page.dart`, `main.dart`, `assets/fonts/`.
- Swift: `native/Budgie/Views/Theme.swift`, `MainView.swift`, `RootView.swift`, `AppLock.swift`, `native/Budgie/App/BudgieApp.swift`, `native/project.yml`.
