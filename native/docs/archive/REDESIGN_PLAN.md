> Archived; paths refer to the `flutter-final` tag.

# Visual redesign: implementation plan

The owner-approved redesign of the native SwiftUI app (`native/`), from the
design canvas to a mergeable branch. This plan is written for an agent with
no prior context: it says what is already done, what the finished app must
look like, how to split the remaining work across subagents, and how to
verify it. Read it fully before starting.

- **Design source:** the canvas https://claude.ai/artifact/9v74CfEWe7LQAy5oenMvij
  (open it with the Artifact tool, `action: "read"`; it belongs to the
  owner's account). Offline copies of every board you need are in
  [`mockups/`](../redesign/mockups) (open them in a browser; they are static HTML).
  Retained screenshots are in [`screens/`](../redesign/screens): Flow, Goals, Spend
  and Worth, plus `before-` / `after-` pairs for the add form and
  onboarding, light and dark. Current Home branding and the Safe to
  spend sheet are captured in `native/Marketing/AppStore-4.0/` and
  `native/docs/appstore/custom-product-page-4.0/`.
- **Branch:** `claude/native-redesign`, in the worktree
  `/Users/khatruong/Documents/GitHub/flutter-budget/.claude/worktrees/swiftui-mvp-migration-71aa05`.
  It branches from `main` after PR 2 (the SwiftUI app) merged.
- **Tracker:** beads epic `budgie-ou0` (`bd show budgie-ou0`). Remaining
  beads: `budgie-ou0.8` (remaining screens; split it into the workstream
  beads below), `budgie-ou0.11` (full UI suite and accessibility audit,
  once, right before merge), `budgie-ou0.12` (an audit failure to check on
  `main` first).

## 1. Status

Done and committed on the branch (oldest first):

| Commit | What |
|---|---|
| `8968907` | Colour tokens retuned to the Paper / Midnight palettes; every glow, text glow, halo and hero blur removed. |
| `cd3e09d` | Home: cash-flow ring hero, income/expense tiles with sparklines, Safe to spend feature card, budget ring tiles, "See all" / "Edit" links, 30pt page titles, 22pt card radius. |
| `29cf830` | Worth (capsule month chips, segmented toggle, centred hero, split card), Goals (feature summary, goal cards with bars), Spend ("Spending" title), chart glow underlays removed; fixed light borders that rendered transparent. |
| `2d8b8a5` | Docs: PARITY_GAPS "Visual redesign", UI_SPEC token table, PERFORMANCE glow note. |
| `15b1eca` | Home: Expense / Income pills removed (the add form has the switch); UI tests moved to the form's Income segment. |
| `7ddce35` | W0 shared components (budgie-ou0.13). |
| `3dff5ce` | W5 onboarding, lock, opening, banner, voice (budgie-ou0.17). |
| `08d7c34` | W1 add / edit form (budgie-ou0.14). |
| `57cf84f`, `43d6a5d` | W2 Settings (budgie-ou0.15); owner's checkpoint calls ("Add" links, no theme subtitle). |
| `58106cd` | W3 Home sheets and lists (budgie-ou0.16). |
| `294b020` | W7 widgets (budgie-ou0.20). |
| `f5860c5` | W6 tab empty states (budgie-ou0.19). |
| `928b389` | W4 tab dialogs and pages (budgie-ou0.18). |
| `5a0541f` | budgie-ou0.12: `RowOrColumn` replaces `ViewThatFits` in the hero legend and the form title row. |
| `995fe3c` | Unused tokens removed; Licences / Diagnostics audit exclusion dropped. |

Verified on the branch: all 135 BudgieAppTests pass; UI test classes Home,
MVPFlow, Worth, Goals, SpendFlow, Tabs and Insights pass. Not yet run after
the last commit: TagsRulesUITests and the accessibility audit (the audit's
last run failed on `budgie-ou0.12`, which may predate the redesign).

Sections 4 and 6 are implemented (W0-W7 above); W8 (full suite, audit,
docs, screenshots) closes it. Decisions taken during the work that differ
from this plan: the add form keeps the Expense / Income switch when
editing (it already had it); the unsaved banner uses `expenseFixed` (white
on dark-mode `danger` fails AA); SEE ALL amounts are signed like Recent
activity; the launch screen colour follows light / dark.

Mockups in `mockups/` (light and dark of each):

| File | Screen | State |
|---|---|---|
| `Home*`, `Worth*`, `Goals*`, `Spend*`, `Flow*` | the five tabs | implemented; use as reference for shared patterns |
| `FitRows*` | add / edit form with the decimal pad up | **to build** (section 4.1); the owner's chosen layout |
| `OtherForm*` | the same form without the keyboard | reference only (outdated field order) |
| `OtherSettings*` | Settings | to build (4.2) |
| `OtherSheet*` | Safe to spend sheet, the sheet pattern | to build (4.3) |
| `OtherOnboarding*` | onboarding page 1 | to build (4.4) |
| `OtherEmpty*` | Goals empty state, the empty-state pattern | to build (4.5) |
| `OtherWidgets*` | home screen widgets | to build (4.6) |

The canvas also holds the three original Home explorations (A/B/C), the
first keypad-up drafts and the rejected "short wheel" option: ignore them.

## 2. Ground rules

### Inherited (do not relax)

Read `AGENTS.md` (repo root) and `native/docs/FULL_APP_PLAN.md` section 3.
The ones that matter most here:

- Native app only. Never modify `budget_app/` (the Flutter app is the
  parity reference), `amplify/` or `src/`.
- **No changes to `native/BudgieCore/`.** The redesign is presentation
  only. Core formulas and copy are parity-tested against Dart; if a screen
  needs different text, format it in the view and record it in
  `native/docs/PARITY_GAPS.md` under "Visual redesign".
- Persistence rules are unchanged (mutate memory, `await persist`, return
  the verified Bool). The redesign must not touch persistence.
- Every animation has a Reduce Motion path; Dynamic Type through
  `TextSpec` / `.textStyle`; VoiceOver labels on every control and chart;
  44 x 44pt minimum tap targets; text at WCAG AA (4.5:1) on what it sits on.
- **Keep every `accessibilityIdentifier` and accessibility label.** The UI
  tests find elements by them. If a control is genuinely replaced, update
  every test that used it in the same change.
- Xcode project is generated: `cd native && xcodegen generate` after
  adding or removing a Swift file, and commit `project.pbxproj`.
- Zero build warnings.
- Git: stage files by name; no `--no-verify`, no amend, no force push, no
  history rewriting; don't push or open a PR unless the owner asks.
- **Never touch the owner's uncommitted files:** `native/docs/MIGRATION_SAFETY_AUDIT.md`,
  `native/scripts/upgrade_rehearsal.py`, `native/docs/OFFDEVICE_RELEASE_AUDIT_2026-10-01.md`,
  `native/docs/offdevice/`, `native/scripts/offdevice_release_rehearsal.py`,
  `native/.DS_Store`. Don't stage, edit, stash or delete them.
- Beads: claim a bead when you start it, close it only once verified,
  file real follow-ups you find (`bd create ... --parent budgie-ou0`).
  Never `bd sync`.

### Redesign-specific

- **One layout in both modes, two palettes.** Light is "Paper", dark is
  "Midnight". Never branch layout on `colorScheme`; branch only colour,
  and only through tokens in `Budgie/DesignSystem/Tokens/Colors.swift`.
- **No glows.** Cards are flat (fill + 1pt border). The only shadows are
  the add button's soft drop shadow, the dialog card's shadow and the
  toast's shadow. (SEE ALL rows lost theirs in W3, so the
  `BUDGIE_PERF_NO_GLOW` switch now changes nothing: budgie-ou0.21.)
- **No hard-coded colours in views.** Add a token if a colour is new. A
  translucent token is `dynamic(light:dark:alpha: true)` with **both**
  values written as `0xAARRGGBB`: an opaque value must carry `0xFF`
  (`0xFFDC_D4C4`), or it reads as fully transparent. This bug shipped once
  (commit `29cf830` fixed it); `ColorContrastTests.testTranslucentTokensAreVisible`
  now catches it, so add every new translucent token to that test.
- **Every new text/fill token pair gets a `ColorContrastTests` case.**
- **Signs:** the Home cash flow has no sign (it already never had one).
  Keep `+` / `−` on transaction amounts and chart labels: they tell income
  from expenses side by side.
- **Copy:** keep the app's existing strings (titles such as "Add Expense",
  button labels, empty-state messages) unless this plan names a change.
  Mockups sometimes show sentence case ("Add expense"); the app's
  title-case strings win, because UI tests and VoiceOver users depend on
  them.
- **Category colours** come from `BudgieColor.category(token)` (the
  category's `colorToken`); status colours from income / warning / danger.

## 3. Design system reference

Everything below already exists unless marked **new**.

### Tokens (`Colors.swift`)

| Token | Light (Paper) | Dark (Midnight) | Use |
|---|---|---|---|
| `background` | `#F3EFE6` | `#07090D` | page |
| `card` / `surface` | `#FBF9F4` | `#11151C` | cards, sheets, dialogs |
| `chipSurface` | `#EAE4D7` | `#161B24` | month pill, chips |
| `cardBorder` / `border` | `#DCD4C4` | white 7% | 1pt card border |
| `hairline` | `#E6DFD1` | white 6% | row dividers |
| `track` | `#E4DDCE` | `#161B24` | bar and ring tracks, segmented track |
| `textPrimary` | `#1A1A17` | `#EEF1F5` | |
| `textSecondary` | `#5C584F` | `#9AA3B2` | |
| `textTertiary` | `#625E56` | `#8C95A5` | |
| `accent` | `#1D6646` | `#B3ADFF` | links, add button, focus ring, filled pill |
| `onAccent` | `#FFFFFF` | `#0B0B14` | label on accent |
| `income` | `#1D6646` | `#5EE6B0` | income, money kept, good change |
| `spent` | `#A63D24` | `#FF8B7B` | money spent in charts |
| `danger` | `#A63D24` | `#FF8B7B` | expense, over limit, errors |
| `warning` | `#7E5300` | `#FFC861` | |
| `info` / `purple` / `pink` / `cyan` | `#1F5F99` / `#5B47B8` / `#7F3B6B` / `#176464` | `#7CC8FF` / `#B3ADFF` / `#F7A1D8` / `#4FD1C5` | category hues |
| `featureFill` | `#1A1A17` | `#10231F` | the feature card |
| `featureBorder` | ink | mint 28% | |
| `featureText` / `featureSecondary` | `#F3EFE6` / `#C2BBAA` | `#EEF1F5` / `#9AA3B2` | text on the feature card |
| `featureAmount` / `featureDanger` | `#F3EFE6` / `#F0A08C` | `#5EE6B0` / `#FF8B7B` | the feature card's figure |
| `featureControl` | paper 12% | white 6% | chevron circle, ring track on the feature card |
| `featureRing` | `#8ED0AA` | `#5EE6B0` | ring on the feature card |
| `selectionFill` / `selectionText` / `selectionBorder` | ink / paper / ink | lilac 16% / `#B3ADFF` / lilac 40% | selected chip or segment |
| `expenseFixed` / `incomeFixed` | `#A63D24` / `#1D6646` | `#A3372A` / `#0E6B4C` | fills behind a **white** label (form Add button, wheel tiles) |
| `incomeGradient` / `expenseGradient` / `primaryGradient` | near-flat pairs | near-flat pairs | existing button fills (white label) |

**New tokens** to add in Wave A (section 6, W0):

| Token | Light | Dark | Use |
|---|---|---|---|
| `fieldFill` | `#F3EFE6` | `#0B0E14` | text fields, form rows, the date tile (on a card or sheet) |
| `switchOn` | `#1D6646` | `#5EE6B0` | `Toggle` tint |
| `scrim` | ink 38% | black 55% | dialog scrim (replace the hard-coded `Color.black.opacity(0.54)`) |

### Type (`Typography/TextStyles.swift`)

Gabarito (display and UI) and Spline Sans Mono (figures, eyebrows). Styles
in use for the redesign: `pageTitle` 30 ExtraBold -0.9, `sectionHeader`
21 Bold, `textLink` 15 SemiBold, `eyebrow` mono 11 +2.4 uppercase,
`rowTitle` 15 SemiBold, `rowSubtitle` 12, `amountSmall` 15 Bold tabular,
`heroMedium` 48, `HomeHero.amountText` 44 ExtraBold. Sheet and dialog
titles in the mockups are 24 ExtraBold -0.5 (**new** style `sheetTitle`).

### Metrics

Page side padding 20; section gap 28; `cardRadius` 22; `statCardRadius` 22;
card padding 16-20; sheet radius 28-30; row height at least 48; buttons 50
(form footer) or 52-56 (full-width primary).

### Components and patterns

- `GlowCard` (despite the name, flat): card fill, 1pt `cardBorder`, radius 22.
- **Feature card:** `featureFill` with a 1pt `featureBorder`, radius 22,
  padding 18. Text in `featureText` / `featureSecondary`, the figure in
  `featureAmount` (or `featureDanger` for a shortfall), controls on
  `featureControl`. One per screen at most. Used today by Home's
  `SafeToSpendCard` and `GoalsSummaryCard`. **New:** add a
  `.featureCard(radius:padding:)` modifier in `Cards.swift` and move both
  existing uses to it.
- `IconTile`: colour at 13% behind a symbol in the colour; `IconTile(category:)`
  for a category.
- `ProgressRing(value:size:thickness:color:track:inner:)`.
- `SegmentedPills`: track plus a `selectionFill` segment.
- `PillButton(filled: true)`: accent fill, `onAccent` label.
- `SectionHeader(title:link:)`: sentence-case text link ("See all").
- `MonthStrip`: capsule chips "Sep 2026".
- Sheets: `.budgieSheetChrome()` (card fill, grab handle, top radius).
- Dialogs: `.budgieDialog(...)` (centred or bottom card over a scrim).

## 4. What each remaining screen must look like

Mockup files are in `mockups/` (light and dark of each). Where a mockup and
this section disagree, this section wins (it records the owner's later
decisions).

### 4.1 Add / edit transaction form (`FitRowsLight.html`, `FitRowsDark.html`)

The owner's top priority: every user sees the form with the decimal pad
up, so **on a 874pt-tall phone (iPhone 17 Pro) every field must be visible
above the pad without scrolling**. `OtherFormLight/Dark.html` show the same
form without the keyboard; the field order there is outdated (Date now
comes before Tags).

Measured on the simulator: the sheet starts 64pt from the top and the
decimal pad covers the bottom ~302pt, leaving ~508pt.

Layout, top to bottom (all inside the existing scroll area, footer pinned
as today):

1. Grab handle 38 x 5, `hairline`-coloured, 8pt from the top.
2. **Title row:** the title (existing copy: "Add Expense" / "Add Income" /
   "Edit Expense" / "Edit Income") at 22 ExtraBold on the left; the
   Expense / Income `SegmentedPills` on the right, 176pt wide, 32pt tall
   (add mode only, as today). 14pt below the handle.
3. **Amount** (12pt gap): 64pt tall, radius 18, `fieldFill`, 2pt `accent`
   border while focused (1pt `cardBorder` otherwise, `danger` with an
   error). "Amount" label 13 SemiBold `textSecondary` inside, top-left
   (8pt from the top). The figure is right-aligned: currency symbol 24 Bold
   `textSecondary`, value 36 ExtraBold, tracking -0.03em, placeholder
   "0.00" in `textTertiary`. Keep `BudgieField`'s behaviour (autofocus,
   decimal pad, error text under the field).
4. **Description** (8pt gap): 46pt, radius 16, `fieldFill`, 1pt
   `cardBorder`, leading `text.alignleft` symbol, prompt "What was this for?".
5. **Category row** (8pt gap), replacing the inline wheel: 48pt, radius 16,
   `fieldFill`, 1pt border. A 64pt label column ("Category", 13 SemiBold
   secondary), the selected category's `IconTile(category:)` at 28pt
   (radius 9), its name 15 SemiBold, a `chevron.down` trailing. Tapping it
   opens a SwiftUI `Menu` containing a `Picker` (inline style) over the same
   categories the wheel offers today (same order, archived ones excluded,
   same income/expense split), so the menu shows a checkmark on the
   selection. Rule-based suggestions (`applySuggestion`) keep setting the
   selection. Accessibility: one button, label "Category", value the
   category name, identifier `form.category`.
6. **Date row** (8pt gap): same row shape; label "Date", value
   `MMMddyyyy` ("Oct 03, 2026") 15 SemiBold, `calendar` symbol trailing;
   opens the existing `DayPickerSheet`. Keep `DateTile`'s accessibility.
7. **Tags row** (8pt gap, only when the user has tags, as today): same row
   shape; the label column shows "Tags" (13 SemiBold) with "Optional" (11,
   `textSecondary`) beneath it; then the tag chips (34pt, radius 17;
   selected: accent at 13% with accent 13 Bold text; unselected: 1pt
   `cardBorder`, `textSecondary` 13 SemiBold). Many tags wrap inside the
   row (the row grows) using the existing `FlowLayout`.
8. Edit mode only: "Delete Transaction" (existing `PillButton`) under the
   rows, inside the scroll area.
9. **Footer** (pinned above the keyboard, as today): a 1pt `hairline` top
   border; padding 10 / 20 / 6; two 50pt capsule buttons, 12 apart:
   "Cancel" outlined (1.5pt `cardBorder`), "Add" / "Update" filled with
   `expenseFixed` or `incomeFixed` by type, white 16 Bold label, spinner
   while saving. Then "Make this recurring" (14 SemiBold `accent`, `repeat`
   symbol, 40pt tall) centred.

Rules for the keyboard:
- On a 874pt-tall phone with the default text size, nothing scrolls. Check
  with a simulator screenshot with the pad up.
- On shorter phones (iPhone SE, 667pt) or at large Dynamic Type sizes the
  scroll area scrolls; the focused Amount must stay visible, and a 44pt
  fade at the bottom of the scroll area cues that more is below.
- Remove the `keyboardDidShowNotification` code that scrolled the wheel
  into view (the wheel is gone).

Apply the same field components to **`RecurringFormView`** (Amount,
Description, Category row, its own pattern / day controls, which stay as
they are) and to the voice flow's prefilled form (it is the same
`TransactionFormView`). `QuickExpenseSheet` keeps its layout with the new
tokens.

Tests that change, every use of the **category** wheel:
- Picking a category: `UITestSupport.swift:171-173` (`addTransaction`'s
  `category:`), `CategoriesUITests.swift:202-204`, `HomeUITests.swift:257`.
  Replace with one helper in `UITestSupport.swift`: tap `form.category`,
  then the category's menu button.
- Reading the selected category: `TagsRulesUITests.swift:108` and
  `VoiceUITests.swift:97` read `pickerWheels.firstMatch.value`. Read the
  `form.category` button's accessibility value instead.
- `RecurringUITests.swift:75-76` has a generic `wheel(_:index:)` helper,
  called only for the recurring *pattern* wheel (`recurring.form.pattern`,
  line 155). That wheel is not a category and stays, so this needs no
  change.

### 4.2 Settings (`OtherSettingsLight/Dark.html`)

- Keep the system navigation bar and back gesture; the mockup's circular
  back button is the iOS 26 bar's look, not a custom control.
- `SettingsBrandCard` becomes the feature card: logo 52pt, "Budgie" 20
  ExtraBold `featureText`, tagline 13 `featureSecondary` (existing copy).
  Drop its wash gradient (`brandCardWash` token can then be deleted).
- Section eyebrows (`SettingsEyebrow`): mono 11, +0.16em, `textSecondary`.
- Section cards: rows 48pt minimum, `IconTile` 38pt radius 12, title 15
  SemiBold, subtitle 12 secondary, chevron or switch trailing, hairline
  between rows.
- `Toggle` tint `switchOn` (new token).
- Theme row: the `SegmentedPills` Light / Dark / Auto, about 170pt wide.
- Pushed pages and dialogs reached from Settings (Categories, Tags & rules,
  Recurring, Currency / Number format / Lock delay choice sheets, CSV
  import, backup import, Licences, Data diagnostics, the category, tag and
  rule editors) follow sections 4.3 and 4.7.

### 4.3 Sheets (`OtherSheetLight/Dark.html`, shown with Safe to spend)

The pattern for every bottom sheet:
- `.budgieSheetChrome()`: card fill, 1pt top border, radius 30, grab handle
  38 x 5 in `hairline`.
- Title 24 ExtraBold (`sheetTitle`), optional blurb 14 secondary.
- Content in cards (`GlowCard` with rows) or the feature card.
- Primary action: full-width filled pill (accent) 52pt; secondary:
  outlined pill.

`SafeToSpendSheet` specifically: title, blurb, then the **feature card**
holding the total ("Safe to spend" or "Projected shortfall" 13 SemiBold,
the total value 40 ExtraBold `featureAmount` / `featureDanger`, the card's
subtitle line), then the six breakdown rows in a card (label 15 regular;
value mono 14 SemiBold: income rows in `income`, zero values in
`textSecondary`, expense rows in `textPrimary`), then the footer 12
secondary. All strings come from `HomeSummary.breakdownSheet` and
`safeToSpendCard`; the separate total row moves into the feature card.

Other sheets to restyle with the pattern: `BudgetLimitSheet`, the budget
pickers in `BudgetsSection`, `QuickExpenseSheet`, `SpendMonthSheet`,
`FlowSheets` (month detail), `SettingsChoiceSheet`, `DayPickerSheet`,
`VoiceRecordingSheet`, `GoalActions` (bottom dialog).

### 4.4 Onboarding (`OtherOnboardingLight/Dark.html`)

- Content left-aligned (today it is centred), 24pt side padding.
- Skip top-right, 44pt target, 15 SemiBold secondary.
- Icon block 116 x 116, radius 34, feature card style, the page's SF
  Symbol at 50pt in `featureAmount`.
- Eyebrow (existing copy, e.g. "WELCOME TO BUDGIE") mono 11 +0.18em
  secondary; title 40 ExtraBold -0.035em, line height 1.05; body 16, line
  height 1.5, secondary.
- Page dots: active 22 x 8 `accent`, others 8 x 8 `track`.
- Continue / Start budgeting: full width, 56pt, capsule, accent fill,
  `onAccent` 17 Bold.
- Keep the existing copy, identifiers (`onboarding.dots` etc.) and the
  Reduce Motion behaviour.

### 4.5 Empty states (`OtherEmptyLight/Dark.html`, shown with Goals)

One pattern for every empty state:
- A card with a 1.5pt dashed border (`textTertiary` at 60%), radius 22,
  padding 36 / 24, centred content.
- `IconTile`-style block 72 x 72, radius 22, accent at 12%, symbol 32pt accent.
- Title 21 ExtraBold, message 15 (line height 1.45) secondary, max width 280.
- Optional action: filled pill 48pt with a `plus` symbol (accent fill).

Apply it to `EmptyStateView` (all kinds: `.noData`, `.noResults`, `.error`;
`.error` uses `danger` for the tile) and to the tab-root empty cards: Worth
("No net worth accounts yet" + "Add account"), Goals ("No savings goals
yet" + "Add goal"), Spend (no expenses), Flow (empty chart messages stay
inline), Home's Recent activity ("No transactions yet."), and the list
pages (SEE ALL, Flow SEE ALL, category drill-in, account history). Keep
every string.

### 4.6 Home screen widgets (`OtherWidgetsLight/Dark.html`)

`native/BudgetWidgets/BudgetWidgets.swift` (separate target, so it cannot
use `BudgieColor`; define a small private palette there with the same hex
values):
- Adapt to the widget's colour scheme (`@Environment(\.colorScheme)`) with
  `.containerBackground(for: .widget)`: `#FBF9F4` light, `#11151C` dark.
- Quick actions (small): header with the logo (18pt) and the cash flow
  (whole units, mono 13 SemiBold, `income` colour, or `danger` when
  negative; bullets when balances are hidden); two equal buttons, radius
  14, `incomeFixed` / `expenseFixed` fills, white 14 Bold "Income" /
  "Expense" with symbols. Deep links unchanged (`budgetapp://add-income`,
  `budgetapp://add-expense`).
- Voice add (small): 52pt accent circle with the mic (`onAccent`), the
  quick actions' cash flow text top-trailing, "Speak a transaction" 15
  Bold, "Budgie" 12 secondary; link unchanged.
- Keep widget `kind`s, families and timelines.
- The white labels must keep 4.5:1 on the fills (they do with the fixed
  fills).

### 4.7 Pushed pages, dialogs and the rest

No dedicated mockups; apply the patterns:
- **List pages** (Transactions SEE ALL, Flow SEE ALL, category drill-in,
  account history, Categories, Tags & rules, Recurring, Licences,
  Diagnostics): rows like Home's Recent activity (`IconTile(category:)`
  40pt, title 15 SemiBold, subtitle 12 secondary, amount `amountSmall`;
  hairlines between rows inside a card); section headers `SectionHeader`;
  filters and search fields use `fieldFill` and `selectionFill` chips.
- **Dialogs** (`budgieDialog`: goal form, allocation, account editor,
  category / tag / rule editors, data import): card radius 22, title 24
  ExtraBold, fields per 4.1 (`fieldFill`, 16 radius), primary filled pill,
  secondary outlined pill, scrim from the new `scrim` token. Remove the
  leftover `budgieDialogGlow(_:)` / `DialogGlowKey` API (glows are gone):
  every dialog gets the same plain card shadow.
- **Lock screen, privacy cover, opening screen:** background token, the
  logo, `pageTitle`-size heading, filled accent Unlock pill.
- **Toasts and the unsaved-changes banner:** keep behaviour and the current
  styling (the neutral toast is already inverted: `textPrimary`-style fill
  with `background` text); only check both read well in the new palettes.
  The banner stays `danger` with white text.
- **Account history hero card** (`AccountHistoryParts`): replace its wash
  gradient with a plain card plus a tinted `IconTile`.
- **Celebration overlay:** keep; it already lost its glow.
- **Design gallery** (`Debug/DesignGalleryView.swift`, launched with
  `BUDGIE_DESIGN_GALLERY=1`): add every new component and the empty state,
  so subagents can screenshot them without navigating.

## 5. Orchestration (main agent + subagents)

### Roles

The **main agent** plans, owns shared files, reviews, runs the visual
checks and commits. **Subagents** implement one workstream each and never
commit.

Main agent:
1. Reads this plan, `AGENTS.md`, `bd prime`, `bd show budgie-ou0`.
2. Splits `budgie-ou0.8` into one bead per workstream (W0-W7) under
   `budgie-ou0` with `--deps` matching the waves; closes `budgie-ou0.8`
   with a note pointing at them.
3. Does W0 itself (shared components), commits, then launches each wave's
   subagents in parallel (one `Agent` call per workstream, all in one
   message), each with the brief in section 5.3.
4. When a subagent reports: reads its diff (`git diff -- <its files>`),
   checks it against this plan and section 2, builds, runs its unit tests,
   takes light and dark screenshots of its screens on the main simulator,
   fixes or sends it back, then commits that workstream alone (stage its
   files by name).
5. After the last wave, does W8 (verification, docs, report).

### Why not separate worktrees

All subagents work in the **same worktree** on disjoint files (the
ownership table below), so nothing needs merging. They must not run git
commands that change state (no add, commit, stash, checkout, reset).

### 5.1 File ownership

A subagent edits only the files its workstream owns. If it needs a change
in a file it does not own (most often a shared component), it stops and
asks the main agent, who makes the change. Adding a new Swift file needs
`xcodegen generate` and changes `project.pbxproj`, which only the main
agent touches: subagents put new types in files they own instead.

| Workstream | Owns |
|---|---|
| W0 (main) | `DesignSystem/**` (tokens, typography, components, chrome, fields), `BudgieAppTests/ColorContrastTests.swift`, `Debug/DesignGalleryView.swift`, `project.yml`, `project.pbxproj` |
| W1 Form | `Views/TransactionFormView.swift`, `Views/Recurring/RecurringFormView.swift`, `Views/Home/QuickExpenseSheet.swift`, `Views/AddFormPresenter.swift` (only if needed), `BudgieUITests/UITestSupport.swift`, the category-wheel sites in `BudgieUITests/{CategoriesUITests,VoiceUITests,RecurringUITests,HomeUITests,TagsRulesUITests}.swift`, `BudgieAppTests/TransactionFormValidationTests.swift` |
| W2 Settings | `Views/SettingsView.swift`, `Views/Settings/**`, `Views/Recurring/RecurringView.swift`, `Views/Recurring/RecurringCard.swift`, `Views/DiagnosticsView.swift` |
| W3 Home sheets and lists | `Views/Home/SafeToSpendSheet.swift`, `Views/Home/BudgetLimitSheet.swift`, `Views/Home/BudgetsSection.swift` (picker sheets only), `Views/Home/HomeMonthPanel.swift`, `Views/Home/TransactionsView.swift` |
| W4 Tab dialogs and pages | `Views/Goals/{GoalForm,AllocationDialog,GoalActions,CelebrationOverlay}.swift`, `Views/Worth/{AccountEditorDialog,AccountHistoryView,AccountHistoryParts}.swift`, `Views/Spend/{SpendMonthSheet,CategoryTransactionsView,CategoryRows}.swift`, `Views/Flow/{FlowSheets,FlowTransactionsView,TransactionsPreviewCard,InsightCard}.swift` |
| W5 Onboarding, lock, voice, chrome | `Views/OnboardingView.swift`, `Views/AppLock.swift`, `Views/OpeningView.swift`, `Views/RootView.swift`, `Views/MainView.swift` (banner only), `Views/Voice/**` |
| W6 Tab empty states | `Views/Goals/GoalsView.swift`, `Views/Worth/WorthView.swift`, `Views/Spend/SpendView.swift`, `Views/Flow/FlowView.swift`, `Views/Home/HomeView.swift` (Recent activity empty card only) |
| W7 Widgets | `native/BudgetWidgets/**` |
| W8 (main) | `native/docs/**`, everything for the final run |

### 5.2 Waves

- **Wave A (main, sequential):** W0. It unblocks everything.
- **Wave B (parallel):** W1, W2, W3, W5.
- **Wave C (parallel):** W4, W6, W7. (W6 after W0's `EmptyStateView`; W4
  after W3 so list rows match.)
- **Wave D (main):** W8.

Run at most two subagents' UI tests at the same time: each UI test run
drives a simulator and they slow each other down badly.

### 5.3 Subagent brief (fill in the brackets)

```
You are implementing workstream [W#: name] of the Budgie native redesign.
Read /Users/khatruong/Documents/GitHub/flutter-budget/.claude/worktrees/swiftui-mvp-migration-71aa05/native/docs/redesign/REDESIGN_PLAN.md
sections 2, 3, [4.x] and 5 first, then AGENTS.md at the worktree root.
Work in that worktree (branch claude/native-redesign). Edit ONLY these
files: [list from 5.1]. If you need a change anywhere else, stop and tell
me exactly what and why. Do not run git commands that change state, do not
commit, do not add or remove files, do not touch BudgieCore.
Mockups: native/docs/redesign/mockups/[files]. Keep every
accessibilityIdentifier, label and string unless the plan names a change.
Build: xcodebuild build -project native/Budgie.xcodeproj -scheme Budgie
  -configuration Debug -destination 'generic/platform=iOS Simulator'
  -derivedDataPath /private/tmp/budgie-[w#]-dd CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  (zero errors and zero warnings).
Unit tests: the same with `test`, -destination 'id=<your simulator UDID>',
  -only-testing:BudgieAppTests.
UI tests: only [classes], on your own simulator, from a fresh install
  (xcrun simctl uninstall <udid> com.khatruong.budgetbuddy first). Run them in
  the background; they take 1-3 minutes each.
Simulator: create your own with
  python3 native/scripts/sim_seed.py Budgie-Redesign-[w#] <path to your built Budgie.app>
  (it prints the UDID). Never use the simulator named "iPhone 17 Pro"
  (it holds real Flutter data) or anyone else's.
Report: files changed, what each change does against the plan section,
build/test results (paste failures verbatim), anything you could not do,
and any plan item you think is wrong (do not silently deviate).
```

### 5.4 Main agent's review checklist (per workstream)

- Only the owned files changed (`git status --short`; ignore the owner's
  files listed in section 2).
- No hard-coded colours (`grep -n "Color(hex\|Color.white\|Color.black\|\.opacity(" <files>`
  and justify each hit), no glows, no layout branching on `colorScheme`.
- Identifiers and strings unchanged unless the plan says otherwise.
- Build has zero warnings; BudgieAppTests pass; the workstream's UI test
  classes pass on a fresh install.
- Screenshots, light and dark, of every screen the workstream touched, on
  the main simulator, compared against the mockup. For the form: with the
  decimal pad up, on iPhone 17 Pro size, and once at the largest
  non-accessibility text size.
- PARITY_GAPS "Visual redesign" updated for any user-visible difference
  from Flutter (main agent writes this in W8 from the subagents' reports).

## 6. Workstreams

Each bullet is a task; every workstream ends with the checks in 5.4.

### W0 Shared components (main agent, Wave A)

1. Tokens: add `fieldFill`, `switchOn`, `scrim` (section 3); add
   `ColorContrastTests` cases: `textPrimary` / `textSecondary` /
   `textTertiary` / `accent` / `danger` on `fieldFill`; white on
   `switchOn`'s knob is the system's, no test; `scrim` in
   `testTranslucentTokensAreVisible`.
2. `TextSpec.sheetTitle` (24 ExtraBold, tracking -0.5, relative to
   `.title2`).
3. `.featureCard(radius:padding:)` in `Cards.swift`; move
   `SafeToSpendCard` (`Views/Home/HomeView.swift`) and `GoalsSummaryCard`
   (`Views/Goals/GoalsView.swift`) to it. (Main agent owns these two edits.)
4. `BudgieField`: `fieldFill`, radius 16, 2pt accent focus border; add an
   `.amount` variant (64pt, label inside top-left, right-aligned 36pt
   figure) used by the form's Amount.
5. **New** `FormRow` view in `Fields.swift`: 48pt min height, radius 16,
   `fieldFill`, 1pt border, a 64pt label column with an optional
   secondary note ("Optional"), content, optional trailing symbol; as a
   `Button` when it has an action. `DateTile` becomes a `FormRow`
   (keep its error state and accessibility).
6. `EmptyStateView` redesign per 4.5 (keep its API and kinds).
7. Sheet chrome: radius 30, handle 38 x 5 in `hairline`.
8. Dialog chrome: scrim from `scrim`; one plain shadow for every dialog;
   remove `budgieDialogGlow(_:)`, `DialogGlowKey` and the `color` input of
   `DialogShadow` (update `AccountEditorDialog`'s single call site).
9. `PillButton`: confirm filled 52pt full-width variant for sheets;
   outlined variant uses `cardBorder` 1.5pt.
10. Design gallery: show the new field, `FormRow`, feature card, empty
    state and sheet title.
11. Build, BudgieAppTests, screenshot the design gallery light and dark
    (`SIMCTL_CHILD_BUDGIE_DESIGN_GALLERY=1 xcrun simctl launch <udid> com.khatruong.budgetbuddy`).
    Commit.

### W1 Add / edit form (Wave B)

Spec 4.1. Tasks: restructure `TransactionFormView` (title row, amount
field, description, category `Menu` row, date row, tags row with
"Optional", delete button, footer); remove the wheel and its
keyboard-scroll code; same components in `RecurringFormView` (keep its
pattern wheel and day controls); `QuickExpenseSheet` tokens; update the
UI-test helpers and the category-wheel sites listed in 4.1;
`CategoryWheelRow` (in `TransactionFormView.swift`, used by both forms'
wheels) is deleted once neither form uses it.
UI tests to run: MVPFlowUITests, TagsRulesUITests, RecurringUITests,
CategoriesUITests, VoiceUITests, HomeUITests.
Visual check: Add Expense and Add Income with the pad up (iPhone 17 Pro),
Edit Expense, Add Recurring, light and dark; iPhone SE size once.

### W2 Settings (Wave B)

Spec 4.2 and 4.7 (dialogs and pushed pages under Settings). Tasks: brand
feature card, eyebrows, rows, toggles, theme row; Categories, Tags & rules,
Recurring list and card, choice sheets, CSV and backup import dialogs,
Licences, Diagnostics, category / tag / rule editors.
UI tests: SettingsUITests, CategoriesUITests, TagsRulesUITests,
RecurringUITests, BackupUITests, CSVImportUITests, AppLockUITests.

### W3 Home sheets and lists (Wave B)

Spec 4.3 and 4.7. Tasks: `SafeToSpendSheet` with the feature card;
`BudgetLimitSheet`; budget picker sheets; `HomeMonthPanel` (also look at
`budgie-ou0.12` here only after the main agent has confirmed whether it
fails on `main`); `TransactionsView` (SEE ALL) rows, month strip, swipe
actions, empty states.
UI tests: HomeUITests, MVPFlowUITests.

### W4 Tab dialogs and pages (Wave C)

Spec 4.3 and 4.7. Tasks: goal form, allocation dialog, goal actions,
celebration; account editor, account history (hero card without wash),
timeline rows; Spend month sheet, category drill-in, category rows; Flow
month sheet, Flow SEE ALL (search, filters, rows), preview card, insight
card.
UI tests: GoalsUITests, WorthUITests, WorthGoalsDepthUITests,
SpendFlowUITests, InsightsUITests.

### W5 Onboarding, lock, voice, app chrome (Wave B)

Spec 4.4 and 4.7. Tasks: onboarding page layout; lock screen, privacy
cover, opening screen; unsaved-changes banner; voice recording sheet and
mic states.
UI tests: OnboardingUITests, AppLockUITests, VoiceUITests.

### W6 Tab empty states (Wave C)

Spec 4.5. Tasks: Worth, Goals, Spend empty cards; Home Recent activity
empty card; Flow empty chart messages (keep inline, restyle text).
Visual check needs an empty store: launch with an empty
`financial_store` directory (fresh install).
UI tests: TabsUITests, MVPFlowUITests (it asserts "No net worth accounts yet").

### W7 Widgets (Wave C)

Spec 4.6. Tasks: palette, container background, both widgets, hide
balances. Verify with a build of the `BudgetWidgetsExtension` scheme, then
on the main simulator: add both widgets to the home screen through Edit ›
Add Widget (search for "Budgie" with the on-screen keyboard; see the
memory note `sim-widget-gallery-automation` in the owner's Claude memory)
and screenshot them in light and dark. `SystemIntegrationUITests` needs a
simulator prepared by `native/scripts/system_flow.sh`; the main agent runs
it in W8 only if the owner wants it.

### W8 Verification, docs, report (main agent, Wave D)

1. `budgie-ou0.12`: in a separate checkout of `main`
   (`git worktree add /private/tmp/budgie-main main`), run
   `AccessibilityAuditUITests/testEveryScreen` once. If it fails there too,
   note it in the bead as pre-existing; either way fix it on the branch if
   the fix is in the redesign's files (the month panel's amount text must
   scale with Dynamic Type: give it a `TextSpec` relative to a scaling
   style). Remove the temporary worktree afterwards (`git worktree remove`).
2. `budgie-ou0.11`: the full suite, once, on a freshly erased simulator:
   `xcodebuild test ... -only-testing:BudgieUITests` plus
   `-parallel-testing-enabled YES -parallel-testing-worker-count 2` to
   halve the wall-clock. Fix every failure (or file it with evidence if it
   is environmental, like `SystemIntegrationUITests` on an unprepared
   simulator).
3. BudgieAppTests and `cd native/BudgieCore && swift test` (Core is
   untouched, so this only confirms it).
4. Docs: PARITY_GAPS "Visual redesign" gains every new difference (form
   layout and category menu, onboarding alignment, sheet totals in the
   feature card, empty-state card, widget palette, removed dialog glow
   API); UI_SPEC sections for the form, sheets, empty states and widgets;
   AGENTS.md if anything there became wrong.
5. Before/after screenshots of every redesigned screen, light and dark,
   with the demo store (section 7), into `native/docs/redesign/screens/`.
6. Report to the owner: what landed (commits), what was verified, open
   items. Do not push or open the PR until the owner asks.

## 7. Tools and environment

- **Machine:** macOS 27, Xcode 27 (27A266a), iOS 27 simulators.
- **Main simulator:** "Budgie-Redesign", UDID
  `715CCB1E-AFF2-46DD-B437-6742D7B9D6D5` (an iPhone 17 Pro type, 402 x 874pt).
  The iOS Simulator MCP tool (`mcp__Claude_Code_iOS_Simulator__control`)
  is allowed on it for taps and swipes. Tab bar centres in points at
  y = 821: Home 63, Worth 132, Goals 201, Spend 270, Flow 338. Home's
  settings gear is at (364, 93); the add button at (355, 743).
  A new simulator needs the owner's approval in the simulator panel before
  the MCP tool can tap it; `xcrun simctl io <udid> screenshot <file>`
  always works without approval.
- **Never** install on the simulator named "iPhone 17 Pro" (Flutter data
  under the same bundle id).
- **Demo data** for screenshots, in
  `~/.claude/projects/-Users-khatruong-Documents-GitHub-flutter-budget/redesign-tools/`:
  - `demo/` — a checksummed store matching the canvas numbers (October 2026,
    $5,200 in, $3,412.80 out, budgets, goals, seven accounts, App Lock off).
    Regenerate with `python3 demo_store.py <native/Fixtures/store/typical/input> demo`
    if the month has moved on (edit the dates in the script).
  - `seed.sh <Budgie.app>` — reinstalls on `$SIM` (default the main
    simulator), copies the store, launches past onboarding.
  - `shot.sh <out.png>` — screenshot of `$SIM`.
  - `build.sh` — Debug simulator build into `$DERIVED` (default `./build`).
  - `shots-before/` — the pre-redesign screens for comparison.
  Reinstalling resets the app's own theme preference; a UI test that picks
  Dark leaves it on Dark until then.
- **UI tests are slow** (13 s to 3 min each; the typing helper waits out
  the iOS 26/27 virtual-keyboard detach). The owner wants: unit tests plus
  the changed screen's UI test classes while working; the full suite and
  the accessibility audit once, before merge. `MVPFlowUITests` assumes an
  empty store: always uninstall the app before a UI test run. After a run
  `xcodebuild` has once idled ~20 minutes before exiting; if the result
  lines are in the log, stop it.
- **Build logs:** pipe through `grep -v sandbox-exec | grep -E ": (error|warning):|\*\* BUILD"`
  to see only what matters.
