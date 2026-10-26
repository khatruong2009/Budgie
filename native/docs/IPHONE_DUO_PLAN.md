# iPhone Duo: implementation plan

Goal: the native app (`native/`) is fully at home on iPhone Duo, both closed (outer display) and open (inner display), and it keeps every piece of state when someone folds or unfolds mid-task.

Status: plan only. Written 2026-10-05, revised 2026-10-26 after launch. Nothing is implemented. Tracked in beads as epic `budgie-g2d` (`.1` to `.6` are Phases 0-5).

What changed in the 2026-10-26 revision:
- iPhone Duo shipped 2026-10-23 on iOS 27.1, and Xcode 27.1 shipped 2026-10-15 (27A9275).
- **4.0.0 is not boxed.** The shipping archives, builds 3 and 4, are stamped `sdk 27.0` (built with Xcode 27.0, 27A266a; checked with `otool -l`). Apple's launch guide gives three tiers: 26 SDK or earlier is boxed, 27.0 SDK resizes and fills most of the inner display, and 27.1 SDK goes edge to edge with vertical bars. So 4.0.0 already resizes on every fold, runs about 871pt wide when open, and stretches its one-column layout. Section 2 now says which problems affect today's users, and D18 and the release plan changed to match.
- Facts are updated from Apple's launch material and from third-party measurements on the 27.1 simulator (section 1).
- The Flutter app was removed from the tree (tag `flutter-final`). The seeded iPhone 17 Pro simulator no longer exists.

Sources:
- Apple: "Three steps to make your app shine on iPhone Duo" (developer.apple.com/iphone-duo/prepare), the news post "Prepare and submit your apps for iPhone Duo" (2026-10-05), HIG "Designing for iPhone Duo", Tech Talks 111461-111466, and the App Store Connect screenshot spec.
- Third party: Blake Crosley's measurements on the Xcode 27.1 beta simulator (27A9269), last updated 2026-10-17. These were not repeated on the 27.1 release or on hardware. Also launch reviews (Daring Fireball, 9to5Mac, CNN, 2026-10-21).
- Two read-only audits of `native/` (layout, and system integration and tooling), summarised in section 2. Their line references were rechecked on 2026-10-26.

## 1. Platform facts that drive the plan

| Fact | Source |
|---|---|
| Shipped 2026-10-23 with iOS 27.1. Touch ID on the side button, no Face ID. Closing the phone moves to the outer display; it does not lock the device. | Apple, reviews |
| **Behaviour depends on the SDK stamp** (`LC_BUILD_VERSION sdk`). Window sizes on the simulator: 26.0 runs at 375x667 in a box, closed and open. 27.0 runs at 386x678 closed (beside the status rail) and 871x669 open, with horizontal bars and no reserved regions. 27.1 runs at 466x678 closed and 951x669 open, edge to edge, with vertical bars and reserved regions. Apps built with the 27.0 SDK or later resize on fold and unfold. | Apple (tiers), third party (points) |
| Outer display: about 466x678 pt, portrait-native. Compact width in portrait, compact/compact in landscape. The vertical status column is on the trailing side, so safe areas are asymmetric (closed: top 82, bottom 34, trailing 84). Occlusions: camera 37x37, status column 84x170. | Apple (size classes), third party (points, insets) |
| Inner display: about 669x951 pt, landscape-native, aspect ratio about 1.42. Regular/regular in every orientation. **Ignores `UISupportedInterfaceOrientations`.** | Apple |
| Fold and unfold resize the running scene; it is not torn down and reconnected. Lay out from scene or view bounds, `GeometryReader` or `onGeometryChange`, and size classes. Never use `UIScreen.main`, idiom, interface orientation or hard-coded heights, and don't read sizes once at launch. Don't treat `.regular` width as iPad. | Apple |
| With the 27.1 SDK, `TabView` and toolbars become a **vertical rail** under the clock: on the outer display, and on the inner display in landscape. In inner portrait they go back to horizontal bars at the top and bottom. Toolbar items with a symbol move into the rail; text-only items stay horizontal. A sheet whose only button is a text "Done" reserves an empty rail (374pt of content instead of 450). `.toolbarVerticalBehavior(.disabled)` opts a view out. When the keyboard is up, it covers the bottom of the rail, including some tabs. Custom bars are not converted. | Apple, third party |
| Book pose: the window is the same size as Open. The fold is a reserved region (`.division`), about 40pt wide at x 455-495 with 20pt margins. It is inactive in Open (read it with `.includeInactive`) and active in Book. Reserved regions arrive only after the first few layout passes. Sheets move to the leading side of the fold in Book. | Apple, third party |
| APIs. Listed in Apple's docs as iOS 27.1: `ArrangementView` (`.arrangementViewStyle(.split)`), `UIArrangementViewController`, `GeometryProxy.reservedRegions(kind:options:)`, `toolbarVerticalBehavior`. Used on the 27.1 beta simulator but not confirmed in shipping docs: `\.toolbarVerticalEdge`, `onHingeChange(isEnabled:_:)`. Code that references 27.1-only types **does not compile with Xcode 27.0**, and `#available` does not help. | Apple docs, third party |
| Split View on the inner display: landscape only, always 50/50, and each side is about the size of the outer display (compact). Toolbars go on each side's outer edge. New windows can't be created on the outer display. | Reviews, third party |
| Simulator: in Xcode 27.1, Device Hub has Closed, Book, Open and Rotate buttons, plus a resizable simulator. `simctl` has no pose command, and XCTest has no pose or hinge API (the buttons can be pressed through the accessibility API). Screenshots: `simctl io <udid> screenshot --display=primary` for the outer display and `--display=primary-1` for the inner. **The iOS 27.1 runtime lists only the iPhone Duo device type.** StandBy and most extensions, including widgets, don't run in it. The first boot is slow. iPhone Mirroring on macOS 27 is another resize test. Xcode's coding assistant has a "get my app ready for iPhone Duo" skill (`xcrun agent skills export` exports it for other agents). | Apple, third party |
| App Store: Duo screenshots are outer 1398x2034 and inner 2007x2853 (the inner panel itself is 1878x2670). Uploading them shows the "optimized for iPhone Duo" badge. They are **required for every submission from April 2027**. App Store Connect has a Duo preview tool, and featuring nominations can say the app is optimized for every pose. | Apple |
| HIG: one view tree that resizes; compact layout closed, regular layout open; open may show one more level of hierarchy; do not swap whole SwiftUI hierarchies on size class (it destroys `@State`); even grid columns. | Apple |
| Known iOS 27.1 bug: some apps zoom incorrectly after a rotation, and a tap or a refold fixes it. Don't spend time chasing it in Budgie. | Reviews |

## 2. What the audits found in `native/`

The app is one narrow column built for a portrait iPhone. It never reads a size class and has no `NavigationSplitView`, and it does not use `UIScreen.main`. Nothing branches on size, so a resize does not lose state. The problems are hard-coded geometry and assumptions about where the tab bar is.

**Live** means the problem affects 4.0.0 users on Duo today (27.0 stamp). **27.1** means it starts when the build moves to the 27.1 SDK.

Ranked by impact:

1. **Bottom-tab-bar assumptions (27.1).** On the outer display and in inner landscape, the tab bar becomes a vertical rail.
   - Toast inset hard-coded to 49: `Views/MainView.swift:43`.
   - FAB clearance paddings: `Views/Home/HomeView.swift:33` (130), `Views/Goals/GoalsView.swift:43` (96), `Views/Worth/WorthView.swift:91,136` (96).
   - FABs are overlaid bottom-trailing (`HomeView.swift:41-45`, `GoalsView.swift:58`, `WorthView.swift:50`). Trailing is where the status column and the rail sit.
   - Every tab root hides the navigation bar and draws `BudgieHeader` (`DesignSystem/Components/Headers.swift:16-27`), whose month pill is centred.
   - The pushed Settings pages (`SettingsView`, `CategoriesView`, `TagsRulesView`, `LicencesView`, `DiagnosticsView`, `TransactionsView`) show the system navigation bar with a custom `.principal` title and `.topBarLeading`/`.topBarTrailing` items. How `.principal` and text-only items sit beside the rail is unknown.
2. **No regular-width layout (live).** Today the inner display gives 871pt; with the 27.1 SDK it gives 951pt. Every page is full width with a 20pt inset. `Metrics.maxContentWidth = 600` (`DesignSystem/Tokens/Metrics.swift:60`) is defined and unused. Rows, buttons and cards stretch, and charts flatten:
   - Trend: fixed 120pt high (`Views/Flow/TrendCard.swift:27`).
   - Growth chart: fixed 180pt (`Views/Worth/WorthGrowthChart.swift:38`).
   - Scrub hit radius: 48pt (`BudgieCore/.../NetWorthPresentation.swift:138`), so touches between sparse points do nothing.
3. **Sheets (live, if the 27.0 tier reports regular width; Phase 0 checks).** In regular width, sheets present as form sheets.
   - Content-measured `.height` detents are used in ten places (TransactionFormView:784, SafeToSpendSheet:72, BudgetLimitSheet:87, SpendMonthSheet:53, FlowSheets:201, FlowTransactionsView:797, SettingsChoiceSheet:51, BudgetsSection:304, QuickExpenseSheet:52, VoiceRecordingSheet:82).
   - `budgieSheetChrome` draws a fake grabber and rounds only the top corners (`DesignSystem/Components/Chrome.swift:10-38`).
   - `BudgetSheetLayout.screenHeight` (`Views/Home/BudgetsSection.swift:376-385`) reads the key window height once, is not reactive, and falls back to 844. It caps three sheets. This is exactly the one-time read Apple warns against, and a fold changes the height from 678 to 669 or 951.
4. **Fold lifecycle risks (live), unverified:**
   - If a fold makes the scene briefly inactive, `SceneDelegate` raises the privacy cover and `AppLock` calls `endEditing` (`Views/AppLock.swift:116`), which drops keyboard focus mid-form. Closing the phone does not lock the device, so the app has no reason to lock on a fold.
   - If a sheet is re-hosted, `VoiceRecordingSheet`'s `onDisappear` cancels a recording (`Views/Voice/VoiceRecordingSheet.swift:89-93`).
5. **State that a layout switch would lose.** All navigation lives in local `@State` in the tab roots and `MainView`: the selected tab, pushed pages, sheet enums and form fields. There are no navigation paths in `AppModel`. That is fine as long as the tree is never swapped, and it is the main constraint on how wide layouts are built (D20).
6. **Window lookups** take `connectedScenes.first` (`Views/AddFormPresenter.swift:41`, `Views/Settings/ShareSheet.swift:28`, `BudgetsSection.swift:382`). This is safe with one scene; keep it that way (D19).
7. **Small items.**
   - `MonthStrip` centres only on appear and on selection (`DesignSystem/Components/MonthStrip.swift:30-35`), so it drifts off centre after a fold (live).
   - Swipe-to-delete arms at 40% of the row width (`Chrome.swift:447`), which is about 350-380pt on a wide row (live).
   - Fixed-width pills (`TransactionFormView.swift:531`, `Settings/SettingsRows.swift:220`) are cosmetic.
8. **Tooling.**
   - The scripts create their simulator from the "iPhone 17 Pro" device type (`ui_flow.sh:11`, `system_flow.sh`, `sim_seed.py`, `upgrade_rehearsal.py`). The 27.1 runtime has only the Duo device type, so the scripts need a device and runtime parameter, with regression runs staying on a 27.0 runtime.
   - UI tests and the accessibility audit's exclusions assume a bottom tab bar: `AuditSupport.swift:266-284`, `WorthGoalsDepthUITests.swift:57-60`, `BackupUITests.swift:176`.
   - The App Store harness renders 6.3" frames only.
   - There is no native CI.

Already fine:
- Deployment target 17 with availability shims (precedent: Liquid Glass on 26+).
- `TARGETED_DEVICE_FAMILY "1"` is correct, since iPhone Duo is an iPhone.
- No `UIRequiresFullScreen`.
- `UIApplicationSupportsMultipleScenes: false`, so a refused new-window request can't happen.
- The launch screen is a plist colour and image.
- The share popover is iPad-safe.
- `budgieDialog` is capped at 500pt.
- `AppLockWindow` follows the scene.
- GeometryReader-driven charts (`NetCashFlowCard`, progress bars, the ring) re-layout on resize.
- `LAContext` reports Touch ID dynamically.

## 3. Decisions

| # | Decision | Proposal |
|---|---|---|
| D18 | Which build carries Duo support | 4.0.0 is live on Duo in the 27.0 tier: it resizes and fills most of the inner display. Phase 0 judges it. If it loses state or input on a fold, or a sheet is unusable, ship **4.0.1 built with Xcode 27.0** containing only the SDK-independent Phase 1 fixes: fold lifecycle, reactive sheet height, readable width, `MonthStrip` recentring and the swipe arm cap. Building with 27.0 keeps horizontal bars, so the hard-coded insets stay correct. Otherwise skip 4.0.1. Duo support proper ships as **4.1, built with Xcode 27.1**. Never switch the SDK without Phase 1's bar-agnostic insets. |
| D19 | Scenes and multi-window | Keep `UIApplicationSupportsMultipleScenes: false`. 50/50 Split View beside other apps still works. Two Budgie windows would need per-scene presenters and a shared-model review, and gain little for a budget app. |
| D20 | How layouts adapt | One view tree. Switch layouts with `AnyLayout`, `ViewThatFits` and conditional modifiers, which keep child identity. Never use `if regular { A } else { B }` around a screen or a stateful subtree. Selections that both compact and regular layouts read stay in the tab root's existing `@State`, so they carry across a fold. |
| D21 | Regular-width content | Show one more level of hierarchy where there is a list → detail: Spend (categories → category transactions), Worth (accounts → account history), Settings (sections → subpage), Flow SEE ALL (filters → results). Home, Flow and Goals become two-column dashboards with even columns. Editing stays in sheets and dialogs. |
| D22 | Shell | Keep the 5-tab `TabView` and let the system turn the bar into a rail. No sidebar in this release. Migrate `.tabItem` to `Tab` (18+) only if Phase 0 shows the rail needs it. Sheets whose buttons are custom keep `.toolbarVerticalBehavior(.disabled)` if Phase 0 shows they reserve an empty rail. |
| D23 | Orientation key | Keep portrait-only. It governs the outer display and every other iPhone, and the inner display ignores it. All inner layouts must handle both 951x669 (vertical rail) and 669x951 (horizontal bars). |
| D24 | Widgets | Keep both `systemSmall` widgets and their `kind`s. Do not add the extra-large family. The reason recorded on 2026-10-05 (it would disappear on a downgrade to the Flutter build) no longer applies now that 4.0.0 replaced Flutter. Revisit after 4.1 as a separate feature. |
| D25 | Hinge | Do not use `onHingeChange`; the app has no hinge interaction. Layout uses size classes and `reservedRegions` only. |
| D26 | Compiling 27.1-only APIs | `ArrangementView` and `reservedRegions` fail to compile with Xcode 27.0. Once the 4.1 work starts, `main` requires Xcode 27.1. Any 4.0.x hotfix is cut from the 4.0.0 tag on a branch and built with Xcode 27.0. No `canImport(SwiftUI, _version:)` tricks. |

## 4. Phases

### Phase 0: toolchain and ground truth (S)
1. Install Xcode 27.1 (27A9275) next to 27.0. `xcode-select` stays on 27.0 until D18 is decided. Use the stock iPhone Duo device in the 27.1 runtime, which is the only device type it has.
2. Install the **shipping 4.0.0 build** (27.0 stamp) on the Duo sim. Walk every tab, sheet and dialog in Closed, Book, Open and Open-rotated poses, and fold mid-task: in the add form with the keyboard up, during a voice recording, and with a budget sheet open. Record the size class and window size each pose reports. Decide D18 from this.
3. Build the current source with the 27.1 SDK, unchanged, and capture the same matrix. This is the baseline that Phases 1-3 are measured against. Record both matrices with screenshots in `docs/duo/BASELINE.md` (use `simctl io --display=primary` and `primary-1`).
4. Run Xcode's "get my app ready for iPhone Duo" assistant skill and record its findings against section 2. Don't apply its fixes blindly.
5. Answer, with evidence:
   - Does fold or unfold call `sceneWillResignActive`? (privacy cover, `endEditing`)
   - Does an open sheet, the `.overFullScreen` `AddFormHost`, a `budgieDialog`, or the voice sheet survive a fold with its state? Does `onDisappear` fire?
   - Does the 27.0 tier report regular width on the inner display, so that sheets present as form sheets for today's users?
   - With 27.1: where does the rail sit in each pose, what does `\.toolbarVerticalEdge` report, and how do the pushed Settings pages' `.principal` titles and text-only items behave? Does the keyboard cover the Spend or Flow tab during the add form?
   - How do custom `.height` detents and `.presentationSizing` behave on the inner display?
   - Can Device Hub's pose buttons be driven from a script (accessibility API) for UI tests?
   - Do `reservedRegions`, `ArrangementView`, `toolbarVerticalBehavior` and `toolbarVerticalEdge` exist in the shipping 27.1 headers with the beta signatures, and do they work inside a `NavigationStack` and a `ScrollView`?
   - New warnings under the 27.1 SDK. The zero-warning rule applies.

### Phase 1: resize-correct on every display (M)
These changes help every iPhone and contain no wide-layout design. Items 3, 4, 6 (`MonthStrip`, swipe arm) and 7 are SDK-independent and fix live problems; they are the 4.0.1 candidate under D18.
1. **Bar-agnostic insets.**
   - Remove the hard-coded 49 (`MainView.swift:43`) and the FAB clearance paddings (HomeView:33, GoalsView:43, WorthView:91,136).
   - Place FABs and the toast host with `safeAreaInset` or safe-area-relative overlays so they follow the tab bar on any edge. On 27.1, read `\.toolbarVerticalEdge` to keep FABs off the rail's edge.
2. **Asymmetric safe areas.** Centre `BudgieHeader`'s pill within the safe area, not the window. Confirm the `ignoresSafeArea` uses are background-only (they are today: Chrome:35,186, AppLock:175,205, AddFormPresenter:145, MainView:128, WorthView:42, OpeningView:56, OnboardingView:90, CelebrationOverlay:27).
3. **Reactive container height.** Replace `BudgetSheetLayout.screenHeight` with a height measured at the sheet host (`onGeometryChange`). Delete the 844 fallback.
4. **Fold lifecycle.** Fix whatever Phase 0 shows:
   - The privacy cover and `endEditing` must not fire on a resize-only inactive transition.
   - Voice recording must survive a fold, or stop with a clear message and no lost entry.
5. **Sheets in regular width.**
   - Make `budgieSheetChrome` aware of form-sheet presentation: all corners rounded, no fake grabber.
   - Use `.presentationSizing(.fitted)` on 18+ where content-height detents are ignored.
   - Recheck the keyboard-slack maths in `BudgetLimitSheet`.
   - On 27.1, stop sheets reserving an empty rail (D22).
6. **Width-relative interactions.**
   - Cap swipe-to-delete's arm distance in points.
   - Make chart scrubbing pick the nearest point in its column band, not within 48pt.
   - Recentre `MonthStrip` on size change.
7. **Readable width.** Apply `Metrics.maxContentWidth` to single-column pages (Settings and its subpages, Recurring, the SEE ALL lists, onboarding, forms), centred. This makes regular width acceptable before Phase 2.
8. **Switch the build to Xcode 27.1.** Zero warnings. Then run all existing tests on a non-Duo iPhone in the 27.0 runtime (for example the stock iPhone 17) and on the Duo in 27.1, to prove no regression.

### Phase 2: regular-width layouts (L)
Pre-27.1 iPhones never get regular width, because the app is portrait-only. So every new layout can sit behind `#available(iOS 27.1, *)` plus `horizontalSizeClass == .regular`, with today's layout as the fallback. In inner landscape the rail takes the trailing edge (951pt minus the rail); in inner portrait (669pt) the bars are horizontal. Both must work.
1. **Home:** two columns via `AnyLayout`. Left: hero ring, flow chips, safe-to-spend. Right: budgets grid (4 columns, even) and recent activity. Keep the ring off the centre.
2. **Spend:** left, the donut and category list; right, `CategoryTransactionsView` for the selected category. On compact the same selection still pushes. Use `ArrangementView` if Phase 0 confirms it works in this hierarchy; otherwise use one `NavigationStack` with a conditional side column driven by the same `@State` selection.
3. **Worth:** chart and accounts on the left; `AccountHistoryView` on the right. Same selection mechanism.
4. **Flow:** metrics and insights on the left, charts on the right. Chart heights scale with width. SEE ALL shows the filters column next to the results.
5. **Goals:** two-column card grid. Dialogs are unchanged.
6. **Settings:** section list on the left; Categories, Tags & rules, Recurring, Diagnostics and Licences on the right.
7. **Fold continuity rule, tested for each screen:** a page pushed while closed shows as the detail column when opened; the selected detail while open shows as the pushed page when closed; open sheets, dialogs, form text, focus and scroll position survive both ways.

### Phase 3: fold-aware book pose (S-M)
1. Read `reservedRegions(kind: .division, options: .includeInactive)` in each two-column container. Lay the columns out on either side of the fold in both Open and Book, so nothing jumps when the pose changes. The gutter must be at least the division width (about 40pt, at x 455-495 in landscape), so no card, chart or ring straddles the fold. Do not cache the first result (it is empty for the first layout passes).
2. Keep the hero ring, donut and charts within one half. Check that the `.occlusion` regions (outer camera, status column) are already covered by the safe area.
3. Check the onboarding pager, the opening animation, the celebration overlay and the lock screen in book pose.

### Phase 4: system integration (S)
1. Quick actions and `budgetapp://` deep links on both displays, and with the add form open across a fold.
2. App lock with Touch ID on a real device. Check that the lock copy names Touch ID, and that closing the phone (which does not lock the device) does not trigger the app lock.
3. Small widgets on the outer and inner Home Screens, on a real device (the simulator cannot run them).
4. 50/50 Split View beside another app on the inner display: compact-width Budgie must use the compact layout, with the toolbar on its outer edge.
5. Run `system_flow.sh`, because the scene delegate and presenters change.

### Phase 5: tests, tooling, docs, store (M)
1. **Scripts.** Parameterise the device type and runtime in `ui_flow.sh`, `system_flow.sh`, `sim_seed.py` and `upgrade_rehearsal.py`. The default stays a non-Duo iPhone on the 27.0 runtime. Add a Duo pass on the 27.1 runtime. Prefer stock simulators over creating clones.
2. **UI tests.**
   - Replace bottom-bar geometry with edge-agnostic checks: `AuditSupport` exclusions, `WorthGoalsDepthUITests:57-60`, `BackupUITests:176`, the widget taps in `SystemIntegrationUITests`.
   - Add `DuoLayoutUITests` for regular-width structure in a fixed pose. XCTest cannot change pose. If Phase 0 finds a scriptable way to press Device Hub's buttons, drive the continuity rule from a host script. Otherwise the continuity matrix goes in `REAL_DEVICE_CHECKLISTS.md` and is run by hand in Device Hub and on a device.
3. **Accessibility.** Run the audit on both Duo displays, including at XXXL. VoiceOver order in two-column layouts must read left column then right.
4. **Docs.**
   - Decisions D18-D26 go in `FULL_APP_PLAN.md` §2, with the D20 rule added to §3.
   - Regular-width sections per screen go in `UI_SPEC.md`.
   - A note goes on `MIGRATION_SPEC.md`'s orientation row: the inner display ignores it.
   - The Duo build goes in AGENTS.md "Before calling native work done", and the minimum Xcode moves to 27.1 (D26).
5. **App Store.** Extend `Marketing/AppStore-4.0` (capture tests and `render-assets.cjs`) to outer 1398x2034 and inner 2007x2853, check them in App Store Connect's Duo preview tool, and upload them with 4.1 to earn the badge. They are required for any submission from April 2027. Submit a featuring nomination that says every pose is supported.

## 5. Sequencing and size

| Phase | Size | Depends on |
|---|---|---|
| 0 Ground truth | S | Xcode 27.1 |
| 4.0.1 hotfix (if D18 calls for it) | S | 0; Phase 1 items 3, 4, 6, 7, on Xcode 27.0 |
| 1 Resize-correct | M | 0 |
| 2 Regular-width layouts | L | 1 |
| 5 Tooling (scripts, test geometry) | M | 0; runs alongside 1-2 |
| 3 Book pose | S-M | 2 |
| 4 System integration | S | 1, a real iPhone Duo |
| 5 Docs and store | S | 2-4 |

Release: 4.0.1 only if Phase 0 finds real breakage. 4.1 = Phases 0-5. If time is short, Phases 0, 1 and 4, plus readable width and Duo screenshots, are a shippable "works well" release, built with 27.1. Phases 2-3 are the "optimized" release.

## 6. Open risks
- Every user who opens Budgie on a Duo today gets the stretched 27.0-tier layout. Phase 0 should start as soon as Xcode 27.1 is installed.
- The point sizes, insets, fold geometry and rail behaviour were measured on the 27.1 **beta** simulator, not on the release or on hardware. Phase 0 rechecks them before Phase 2 depends on `ArrangementView` or the fold geometry.
- Fold pose isn't scriptable from XCTest, so continuity will be at least partly a manual check. Budget real-device time (REAL_DEVICE_CHECKLISTS).
- The widget and Touch ID paths can only be verified on hardware.
- After 4.1 work lands on `main`, Xcode 27.0 can't build it (D26). A late 4.0.x fix has to come from a branch.
