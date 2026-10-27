# iPhone Duo baseline (Phase 0)

Measured 2026-10-26/27 for `budgie-g2d.1`, against [IPHONE_DUO_PLAN.md](../IPHONE_DUO_PLAN.md). This is the reference that Phases 1-3 are measured against.

## Setup

| | |
|---|---|
| Xcode | 27.1 (27A9275), the only Xcode installed. **Xcode 27.0 is not installed** (27.1 replaced it), so a 4.0.1 built with Xcode 27.0 (D18, D26) needs 27.0 reinstalled first, e.g. as `/Applications/Xcode-27.0.app`, used through `DEVELOPER_DIR`. |
| Simulator | Stock iPhone Duo, iOS 27.1 runtime (24A94425). No clone. |
| Shipping build | The App Store binary from `Budgie 4.0.0 (4) Blue Bird.xcarchive` (commit a3641f5, `sdk 27.0`). Its Mach-O build version was changed from iOS to iOS Simulator with `vtool -set-build-version iossim 17.0 27.0 -replace`, keeping `sdk 27.0`, so it runs in the 27.0 tier. The code is unchanged (identical `otool -t` hash). It had to be signed ad hoc **without entitlements** (the simulator refuses the archive's entitlements), so it has no App Group container; nothing in this walkthrough used it. It is a Release build: the onboarding tour runs first. |
| Baseline build | Current source (2b4a6ac), unchanged, Debug, Xcode 27.1, `sdk 27.1`. Debug and Release both build with **zero warnings**. `BudgieCore` `swift test`: 404 tests pass. |
| Data | Demo store from `redesign-tools/demo_store.py` (Fixtures `typical` input), copied into the app's data container. |
| Probe | A throwaway SwiftUI app (not committed) with Budgie's scene-delegate pattern, built twice: `sdk 27.1` and re-stamped `sdk 27.0`. It logs scene lifecycle, window geometry, size classes, safe areas, `reservedRegions`, `toolbarVerticalEdge`, hinge state, and the state and `onDisappear` of each presentation type across folds. |

Poses were changed with Device Hub's buttons, pressed from a script (see [Scripting poses](#scripting-poses)).

Screenshots: [`baseline/4.0.0-sdk27.0/`](baseline/4.0.0-sdk27.0) and [`baseline/head-sdk27.1/`](baseline/head-sdk27.1), named `<pose>-<screen>.png`. Pose is `closed`, `book`, `open` or `openrot` (inner portrait). Fold tests are `<pose>-<test>-to-<pose>-settled.png`.
- Each shot was taken on both displays with `simctl io <udid> screenshot --display=primary` (outer, 1398x2034) and `--display=primary-1` (inner, 2853x2007 in landscape, 2007x2853 in portrait). The display not in use is always black, so only the active display is kept. `closed-home-inner-inactive.png` in each folder is one example of the black display.
- Shots are reduced to 1x (points) and 256 colours. The full-resolution originals were not kept.

## Window and environment per pose

| Pose | 27.0 tier (shipping 4.0.0) | 27.1 tier (current source on 27.1 SDK) |
|---|---|---|
| Closed | 386x678, compact/regular. An 80pt black strip with the clock sits outside the window on the trailing side. Bottom tab bar. | 466x678, edge to edge, compact/regular. Safe area at the UIKit root: top 0, bottom 34, trailing 84 (top 82 appears only on transient passes and for SwiftUI navigation). Tabs are an icon-only **vertical rail** on the trailing edge, under the 84pt status column. |
| Open (inner landscape) | 871x669, regular/regular, 80pt black strip on the trailing side. Bottom tab bar. | 951x669, regular/regular. Trailing rail. |
| Book | Same window as Open. Content, sheets and dialogs stay centred, so they straddle the fold. | Same window as Open. **Sheets move to the leading half and the keyboard to the trailing half.** Dialogs (`budgieDialog`) and the hero ring stay centred on the fold. |
| Open-rotated (inner portrait) | 669x871, regular/regular, black strip at the top. Bottom tab bar. | 669x951, regular/regular. Horizontal floating tab bar at the bottom (icon and label). `toolbarVerticalEdge` is nil. |

Further findings:
- **Scene and screen.** A fold never deactivates the scene. Across every fold and rotation in both tiers there was no `sceneWillResignActive`, no `sceneDidEnterBackground` and no `scenePhase` change, and the `UIScreen` object stays the same.
- **Orientation key.** The inner display ignores the portrait-only `UISupportedInterfaceOrientations`, as the plan says.
- **Hinge.** It reports closed 0°, Book about 128° and open 180°, through `onHingeChange` and `UIHingeInteraction`.
- **Book versus Open.** The window size doesn't change between them; only the hinge and the system's sheet placement (in the 27.1 tier) tell them apart.

## Answers to the Phase 0 questions

| Question | Answer | Evidence |
|---|---|---|
| Does a fold call `sceneWillResignActive` (privacy cover, `endEditing`)? | **No**, in either tier. No cover appeared in any frame captured during a fold, about 1 s apart. | probe logs; `*-to-*-settled.png` |
| Do sheets, `AddFormHost`, `budgieDialog` and the voice sheet survive a fold with their state? Does `onDisappear` fire? | **All survive, and `onDisappear` never fires.** Form text, the goal dialog's text, the budget limit value and a running voice recording all survive both directions, in both tiers. One difference: in the **27.0 tier, Closed→Open drops the add form's keyboard and focus** (text kept; reproduced twice). The 27.1 tier keeps them. | `closed-addform-to-open-settled`, `closed-voice-to-open-settled`, `closed-dialog-to-open-settled` in both folders |
| Does the 27.0 tier report regular width on the inner display, so sheets present as form sheets? | **Yes.** Regular/regular at 871x669. Sheets are centred form sheets, `.height` detents are honoured, and `budgieSheetChrome` still draws its fake grabber inside them. | `4.0.0-sdk27.0/open-addform`, `open-safe-to-spend` |
| 27.1: where is the rail, and what does `toolbarVerticalEdge` report? | Trailing in Closed, Open and Book; nil in inner portrait (horizontal bars). The rail sits under the status column, centred vertically in the lower half. | `head-sdk27.1/closed-home`, `open-home`, `openrot-home` |
| 27.1: pushed Settings pages' `.principal` titles and text-only items | **Symbol items move into the rail**: Back, Categories "+", Recurring refresh and "+", account edit and delete. They stack under the status column. **Text-only items stay in the content**, e.g. "Add" in Tags & rules. The `.principal` title is centred in the area left of the rail, about 10pt off the safe-area centre in Closed. Pages that also scroll a month strip run it under the rail's Back button. | `head-sdk27.1/*-settings-*`, `open-seeall` |
| 27.1: does the keyboard cover the Spend or Flow tab during the add form? | **Yes**, in every pose. In Closed it covers the whole rail. On the inner display it spans the full width and covers Worth to Flow, with only Home peeking above it. | `head-sdk27.1/*-addform*` |
| `.height` detents and `.presentationSizing(.fitted)` on the inner display | Both are honoured inside a form sheet. On the outer display `.fitted` is ignored and gives a tall bottom sheet (probe). In the 27.1 tier, sheets are form sheets in Open and bottom sheets in inner portrait. | probe; `*/open-budget-sheet`, `openrot-budget-sheet` |
| Text-only "Done" sheet reserves an empty rail? | **Yes** (probe, outer display): the content is 374pt wide with a 76pt trailing safe area. `.toolbarVerticalBehavior(.disabled)` gives 450pt and 0. The plan's "374 instead of 450" is a width, not a height. **No Budgie sheet has a toolbar text button, so none reserved an empty rail**, which means D22's opt-out isn't needed today. | probe C1/C2 |
| Can Device Hub's pose buttons be driven from a script? | **Yes**, see [Scripting poses](#scripting-poses). XCUITest cannot; a host script can. | |
| Do `reservedRegions`, `ArrangementView`, `toolbarVerticalBehavior` and `toolbarVerticalEdge` exist in the shipping 27.1 headers with the beta signatures? Do they work in a `NavigationStack` and a `ScrollView`? | **They all exist and compile; see [API check](#api-check-shipping-271-sdk).** `toolbarVerticalEdge` works, and so does `toolbarVerticalBehavior(.disabled)`. **`reservedRegions` returned empty** for both `.division` and `.occlusion`, with and without `.includeInactive`, in every pose including Book, at the root, inside a `NavigationStack` and inside a `ScrollView`, over 137 layout passes. Yet the system itself moves sheets off the fold in Book. Either the simulator doesn't feed regions to SwiftUI or the probe queried them wrongly. Not resolved; see Phase 3 in the plan. `ArrangementView` compiled but was not exercised. | probe logs |
| New warnings under the 27.1 SDK | **None.** Debug and Release clean builds have zero warnings. | |

## Live problems in 4.0.0 (27.0 tier) and in the 27.1 baseline

Severity scale: data or input lost > unusable > ugly > cosmetic.

| Plan item | 4.0.0 (live) | 27.1 baseline | Severity | Evidence |
|---|---|---|---|---|
| §2.3 / Phase 1.3: `BudgetSheetLayout.screenHeight` read once | **Reproduces.** After a fold with the limit field's keyboard up: Closed→Open, the field is clipped and **Save is under the number pad**. The decimal pad has no return key and the sheet has no keyboard toolbar, so the only ways out are to fold back or to dismiss the sheet and lose the edit. Open→Closed, the title is clipped and Remove is hidden. The value is kept. | Reproduces, both directions | **Unusable until folded back**; nothing lost | `*/closed-budgetkb-to-open-settled`, `*/open-budgetkb-to-closed-settled` |
| §2.4 / Phase 1.4: privacy cover or `endEditing` on fold | Does not reproduce | Does not reproduce | none | probe logs |
| §2.4: voice recording cancelled by `onDisappear` | Does not reproduce; the timer runs on across both folds | Does not reproduce (also Book↔Open) | none | `*/closed-voice-*` |
| Phase 1.4: add form keyboard and focus across a fold | **Reproduces, Closed→Open only**; text kept, one extra tap | Does not reproduce | minor | `4.0.0-sdk27.0/closed-addform-to-open-settled` |
| §2.7 / Phase 1.6: `MonthStrip` recentring | **Reproduces.** With May selected, Open→Closed resets the strip to scroll 0 and the selected month is off screen. | Reproduces | ugly | `4.0.0-sdk27.0/closed-monthstrip-after-fold2`, `head-sdk27.1/open-monthstrip-to-closed-settled-b` |
| §2.7 / Phase 1.6: swipe-to-delete arms at 40% of row width | **Reproduces.** Thresholds: about 314pt on a 785pt row, about 250pt on a 615pt row, against about 140pt on a phone. A confirmation dialog still prevents data loss. | Reproduces | ugly | `4.0.0-sdk27.0/openrot-swipe200`, `openrot-swipe300`; `head-sdk27.1/open-swipe*` |
| §2.2 / Phase 1.6: 48pt scrub radius | **Reproduces.** Worth 1Y in Open: a touch on a point shows the tooltip, a touch midway (67pt from each point) shows nothing. Flow's trend has about 72pt spacing, so its dead zone was computed rather than tested. | Reproduces | minor | `*/open-worth-scrub-point`, `open-worth-scrub-gap` |
| §2.2 / Phase 1.7: no readable width | **Reproduces.** Rows, buttons and cards stretch to about 830pt; charts flatten. | Reproduces | ugly | `*/open-*` |
| §2.3: form sheets with the fake grabber | **Reproduces** | Reproduces in Open | cosmetic | `*/open-addform` |

Not in the plan:
1. **FABs cover content in every pose and both tiers.** Affected: Home's trailing amounts and "See all"; the Safe-to-spend chevron; Transportation card text; Goals' "..." button and percentage; Worth liabilities. In the 27.1 tier they sit just left of the rail, not on it.
2. **Tapping the scrim can hit a row** (27.1, Book). Once a sheet moves to the leading half, a scrim tap where the sheet used to be landed on a Currency row, switched the currency and dismissed the sheet. This is a data change without intent; the demo store was re-seeded.
3. The pinned "Settings" title clips scrolled content at a hard edge after popping back (both tiers).
4. Inner portrait, add form with the keyboard: Category and Date are clipped behind the keyboard (it scrolls). Both tiers.
5. 27.1: the opening-animation bird is centred on the whole window, about 42pt off the safe-area centre in Closed.
6. Book: dialogs and the hero ring straddle the fold in both tiers (Phase 3).
7. 27.0 tier, Open: the onboarding Continue button stretches to full width.
8. Debug only: the voice timer prints "0:893" for durations over 60s, which is reachable only through `BUDGIE_VOICE_MAX_SECONDS`.
9. Closed→Open shows the inner-display UI tilted for about 1s while the system rotates (platform, not Budgie).

Not exercised:
- **Toast placement.** No action that raises a toast was run, so `MainView.swift:43`'s 49pt inset next to the rail is unverified.
- **Fold tests:**
  - Book: only voice was fold-tested.
  - Open-rotated: none.
  - Flow SEE ALL: walked in shipping Book only.
- **Backup:** Export and Import backup weren't opened.
- **Probe:** the `.overFullScreen` focus, stale-height and `ArrangementView` screens weren't run.
- **Hardware only:** widgets, Touch ID and the hardware keyboard.

## 27.0 tier versus 27.1 tier

What moving to the 27.1 SDK makes worse. Phase 1 must fix all of these before the SDK switch:
- The tab bar becomes a trailing rail, so every bottom-bar assumption breaks: the toast's 49pt inset, FAB clearance paddings, and FABs placed next to the rail.
- Symbol toolbar items move into the rail, `.principal` titles shift, and month strips run under the rail's Back button and the status column.
- The keyboard hides the rail.

What it makes better:
- Add-form focus survives a fold.
- The window is edge to edge, with no 80pt black strip.
- In Book, sheets and the keyboard move off the fold.
- In Closed, sheets are proper bottom sheets.

What doesn't change: the stale budget sheet height, `MonthStrip`, the swipe arm, the scrub dead zone, stretched layouts, the fake grabber in form sheets, FABs over content, and the hero ring on the fold in Book.

## Scripting poses

Device Hub (process `DeviceHub`, not Simulator.app) exposes its pose controls as `AXButton`s, which `AXPress` from `osascript -l JavaScript` (System Events) can press. Device Hub does not need to be frontmost.
- **Handle.** The buttons have no `AXIdentifier`. The only handle is the `help` string: `Closed`, `Partially Open` (Book), `Open`, `Rotate Right`. That string could change between Xcode builds.
- **Speed.** The first accessibility walk takes 30-90s. A long-running JXA process that keeps the element references gets each press down to about 50ms.
- **Rotate.** There is one Rotate button, which toggles inner landscape and portrait. Element references go stale after a rotate, so walk the tree again.
- **Lock.** It needs an unlocked GUI session with Accessibility permission. Once the Mac locked, Device Hub exposed no windows at all.

So pose changes can't come from XCUITest, but a host script can drive them between test steps (Phase 5).

## API check (shipping 27.1 SDK)

Every name the plan uses exists in the shipping `iPhoneOS27.1`/`iPhoneSimulator27.1` interfaces, as `@available(... 27.1)`. Most are in `SwiftUICore`.

| Plan name | Shipping declaration | Difference from the plan |
|---|---|---|
| `GeometryProxy.reservedRegions(kind:options:)` | `reservedRegions(kind: ReservedRegion.Kind, options: ReservedRegion.QueryOptions = [], layoutDirectionBehavior: LayoutDirectionBehavior = .mirrors) -> [ReservedRegion]`. `ReservedRegion` has `id`, `kind`, `frame`, `margins`, `isActive`. Kinds are `.division` and `.occlusion`; there is `.includeInactive`. | Extra defaulted third parameter. `(kind:options:)` calls compile. |
| `\.toolbarVerticalEdge` | `EnvironmentValues.toolbarVerticalEdge: HorizontalEdge?` (get-only). UIKit: `UITraitCollection.verticalBarEdge`. | The plan says "not confirmed"; it is confirmed. |
| `toolbarVerticalBehavior` | `toolbarVerticalBehavior(_: ToolbarVerticalBehavior)`, `.automatic` / `.disabled` | Matches |
| `ArrangementView`, `.arrangementViewStyle(.split)` | `ArrangementView<Primary, Secondary>(primary:secondary:)`; `.split` (`SplitArrangementViewStyle`, `.axes(_:)`); also `.overlay` and `splitArrangement*` modifiers | Matches; extra styles |
| `UIArrangementViewController` | Present | Matches |
| `onHingeChange(isEnabled:_:)` | `onHingeChange(isEnabled: Bool = true, _ action: (DeviceHingeContext, DeviceHingeContext) -> Void)`; `DeviceHingeContext.hinge?.status` (`.closed`, `.partiallyOpen`, `.fullyOpen`) and `.angle`. UIKit: `UIHingeInteraction`. | The plan says "not confirmed"; it is confirmed. D25 is unchanged. |
| `presentationSizing` | iOS 18+ | Matches |
| (not in plan) | `toolbarVerticalCompressionBehavior` with `.prefersToolbarItems` / `.prefersTabBar` | New; relevant to the rail's crowding under the keyboard and with toolbar items |

There is no public pose API. Book and Open differ only in hinge state, plus `.division`'s `isActive` according to Apple; on this simulator that was empty.

## Xcode's iPhone Duo assistant skill

`xcrun agent skills export --output-dir <dir>` exports all of Xcode's skills at once; there is no `list` command and no skill named after iPhone Duo. The skill Xcode uses for "get my app ready for iPhone Duo" is **`app-resizability`**, with `device-interaction` alongside it. Both are UIKit-first.

The skill's prerequisite checks all pass:
- `UILaunchScreen` is set.
- Scene lifecycle is in use.
- There is no `UIRequiresFullScreen`.
- Portrait-only orientation is fine for an iPhone-only app.

It also states that iOS 27 requires scene lifecycle and a launch screen (`ITMS-90870`) and ignores `UIRequiresFullScreen`.

Read-only findings against plan §2 (19 in all): 13 confirm the plan, 2 contradict it, 5 are new, and 1 area (fold lifecycle) isn't covered. **None were applied.**

Contradicts:
- **FABs.** The skill wants `safeAreaBar`/`safeAreaInset` for bottom-trailing FAB overlays (`HomeView.swift:38-45`, `GoalsView.swift:57-58`, `WorthView.swift:46-50`). Plan 1.1 allows "safe-area-relative overlays". Phase 1 should use `safeAreaInset`/`safeAreaBar`.
- **Window lookups.** The skill says never to walk global scene state (`connectedScenes.first` in `ShareSheet.swift:28`, `AddFormPresenter.swift:41`, `BudgetsSection.swift:382-384`). The plan (§2.6, D19) keeps them because there is one scene. Phase 1.3 removes the `BudgetsSection` one anyway; the other two can take the window from the view.

New:
- `OpeningView.swift:56` has a bare `ignoresSafeArea()` on a container whose children are laid out against the full window. That is the likely cause of the opening bird sitting off-centre in 27.1, and the plan's claim that every `ignoresSafeArea` is background-only is not true for it.
- `CategoryTransactionsView` and `AccountHistoryView` also use custom `.principal` toolbars, and are missing from plan §2.1's list.
- The widget extension has `TARGETED_DEVICE_FAMILY "1,2"` (`project.yml:141`), while the app has `"1"`.
- The keyboard observers (`Chrome.swift:205,208`, `RuleEditorDialog.swift:131,447,450`) don't affect layout. No action needed.
- The fake grabber in `Chrome.swift:20` is an inset inside the sheet (relevant to D22 and Phase 1.5).

Plan §2 line references all still point at what they describe, with these exceptions:
- `QuickExpenseSheet.swift:52` uses `.fraction(0.66), .fraction(0.9)`, not a content-measured `.height`.
- `VoiceEntryFlow.swift:17` (`.large`) and `Debug/DesignGalleryView.swift:67` (`.medium`) are unlisted.
- Phase 1.2's pill centring is already correct: the pill is centred in the safe area in the 27.1 tier.

## D18 evidence

No fold loses data, text or a recording in 4.0.0, and nothing locks the app or covers it.

The live problems, in order of severity:
1. The budget limit sheet is unusable after a fold while its keyboard is up, until the user folds back.
2. The add form's keyboard and focus drop on Closed→Open.
3. Cosmetic stretching, the swipe arm, `MonthStrip` and the scrub dead zone.

Every 4.0.0 user on a Duo hits the first two only if they fold mid-edit. The recommendation is in the plan's D18 row.
