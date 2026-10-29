# Full Swift app: implementation plan

Goal: take the SwiftUI MVP to a full replacement of the Flutter app. That means every feature, a look that closely matches the Flutter app, and the store format kept byte-compatible so users can downgrade.

Sources:
- Seven per-area analyses of both codebases, saved in [`archive/full-app/`](archive/full-app).
- The existing MIGRATION_SPEC, UI_SPEC and PARITY_GAPS.

Each area file holds the exact copy, formulas, layout metrics, Core/AppModel API sketches and parity-test lists. Implementers should work from those files; this document is the order of work and the decisions.

| Area spec | Covers |
|---|---|
| [01-design-system-and-shell](archive/full-app/01-design-system-and-shell.md) | Tokens, fonts, motion, every shared component. Its custom-dock shell sections are superseded by D2 (native tab bar). |
| [02-home-and-transaction-entry](archive/full-app/02-home-and-transaction-entry.md) | Home tab, budgets, transaction form, SEE ALL list, quick-expense sheet |
| [03-goals](archive/full-app/03-goals.md) | Savings goals tab, allocation, celebration |
| [04-spend-flow-and-transaction-lists](archive/full-app/04-spend-flow-and-transaction-lists.md) | Spend (donut) tab, Flow (cash flow) tab, filterable transactions page, LedgerIndex |
| [05-net-worth](archive/full-app/05-net-worth.md) | Worth tab editing, account history, growth chart |
| [06-settings-categories-data](archive/full-app/06-settings-categories-data.md) | More tab, categories, tags and rules, CSV import, backup export/restore |
| [07-insights-onboarding-recurring-voice](archive/full-app/07-insights-onboarding-recurring-voice.md) | Insight engine, onboarding, recurring parity, voice options, routing and lock fixes |

## 1. What the analysis changed

These facts reshape the MVP. Most are verified against source.

1. **The Flutter shell has 6 tabs, not 5: Home, Worth, Goals, Spend, Flow, More.**
   - They sit in a custom floating dock with drag-select.
   - Recurring is a pushed page under More, not a tab.
   - Per D2, the Swift app uses the native 5-tab Liquid Glass bar instead, with Settings behind a Home header gear.
   - The MVP's History tab has no Flutter equivalent as a tab. It is closest to the "SEE ALL" transactions page reached from Home.
   - AGENTS.md's 5-tab description is stale.
2. **The MVP Spending tab is not the Flutter Home.**
   - Flutter Home has: hero cash flow, spend gauge, month-over-month flow chips, safe-to-spend, Budgets, Recent activity (3 rows), action pills, and a FAB (long-press opens a quick category sheet).
   - The month's transaction list and "expenses by category" live elsewhere: the SEE ALL page and the Spend tab.
3. **Flutter has two transaction lists.**
   - The month-scoped, editable `TransactionPage`: day headers, tap to edit, swipe to delete.
   - The all-time, filterable, read-only Flow "SEE ALL" page: filters for type, category, tag, date range and amount; pagination of 50.
4. **`selectedMonth` is shared state in Flutter.** Home sets it, Flow and Insights read it, and the Flow detail page writes it. The MVP keeps it as view `@State`. It must move into `AppModel`.
5. **`AppModel.serialize` silently persists stale JSON for any section it does not know** (verified, `AppModel.swift:182-191`).
   - The fallback returns `data.sections[section]`, and `noteWritten` is never called.
   - Every new mutable section (budgets, goals, categories, tags, rules, selected net worth month) needs a typed section serializer and a `serialize` case. Without one, both the save and the retry write the old value.
   - This is the first thing to fix.
6. **Ledger reads are O(N) per call.**
   - `FinancialData.transactions` is a computed `compactMap`, `monthLedger()` re-runs per call, and `DartDateTime.fields` recomputes the time zone offset on every access.
   - Home, Spend, Flow and Insights together would re-scan a 10k ledger dozens of times per render.
   - Needs one `LedgerIndex` per data revision (spec 04 section 4.1), plus a `ledgerRevision` that views observe instead of diffing `transactionRows`.
7. **Flutter materialises "legacy" categories at every launch** (from transactions, recurring templates and budget-limit keys) and writes the `categories` section. Swift only fakes them in pickers and misses template and budget-key names. Category management and budgets both depend on fixing this.
8. **Quick actions and deep links can open the add form over the lock screen** (verified).
   - `MainView` consumes `pendingAdd` with `initial: true`, regardless of lock state.
   - Sheets present above the `.appLock()` overlay.
   - Gate route consumption on unlock (and on onboarding completion).
9. **Several MVP defaults differ from Flutter and need a call:**
   - The form has a type toggle; Flutter has none.
   - Recurring "Every 2 weeks" versus Flutter's "Bi-weekly".
   - The banner copy differs.
   - The category `purple` token differs (Flutter uses 818CF8 in both modes).
   - The `asterisk_circle` icon maps to the wrong SF Symbol.

## 2. Decisions

Decided (2026-09-28): D1, D2, D3, D11. The rest have a recommendation; the plan assumes it unless you choose otherwise.

| # | Decision | Status |
|---|---|---|
| D1 | Look | **Decided: replicate the Flutter redesign.** Glow cards, Gabarito and Spline Sans Mono, the redesign tokens. The legacy-look Flutter screens (Recurring, Categories, Tags, form, lock screen) are ported to the redesign tokens, not to their old Material look. |
| D2 | Shell | **Decided: the native Liquid Glass tab bar (`TabView`) with 5 tabs: Home, Worth, Goals, Spend, Flow.** See the notes after this table. |
| D3 | Icons | **Decided: SF Symbols, tinted to Flutter's colours.** Use the Flutter tints and 13-14% tile backgrounds, and the mapping tables in the specs. A few glyphs (piggy bank, donut_small) need a custom symbol or the closest SF substitute. |

D2 notes:
- Settings (Flutter's "More" tab) opens from a gear button in the Home header's empty right slot, as a pushed page. Recurring stays a row under Settings > DATA.
- Liquid Glass renders on iOS 26+ when built with the iOS 26+ SDK. iOS 17-25 users get the standard tab bar.
- Use `Tab` (iOS 18+ API), gated with `#available`, or the iOS 17 `tabItem` form.
- Consider `.tabBarMinimizeBehavior(.onScrollDown)` on iOS 26.
- Content, FABs and banners inset against the system tab bar and safe area; there is no custom `DockMetrics`.
- Onboarding page 3 copy ("Spend, Flow, and More") changes to reference Settings.
| D4 | Light mode fidelity equal to dark | Yes, but review dark first; the redesign is dark-first. |
| D5 | Transaction form: centred dialog card or bottom sheet; keep the Expense/Income toggle; title in edit mode | Sheet with card styling. Keep the toggle (a superset). Use "Edit Expense/Income" titles (Flutter says "Add" even when editing, which is a bug). |
| D6 | Flutter bugs: copy or fix | Fix where the fix is invisible to Dart, and log each in PARITY_GAPS. Covers: hard-coded `$` prefixes and en-US-only parsers; rules cascade ignoring type; the Home month wheel locked to one year; the hero ignoring hide-balances; the date picker assert on old goals; the Flow detail month pill that doesn't filter. |
| D7 | Flow detail list: read-only (Flutter) or editable | Editable superset (tap to edit, swipe to delete). |
| D8 | Search scope in transaction filters | Description only (Flutter), with category covered by the category filter. |
| D9 | Delete tag: leave orphan `tagIds` on transactions (Flutter) or clean them | Leave them; keeps both apps identical. |
| D10 | Backup restore: commit strategy, safety copy, old-schema backups | One commit, swapping memory only on success. Keep a pre-restore safety copy of the store. Keys a backup leaves out or sets to null (schema-1 files; only schemas 1 and 3 ever existed) leave their sections unchanged (Flutter resets them). |
| D11 | Voice entry | **Decided: OpenAI, with the key built into the app** (Flutter's approach). See section 6 for how the key is supplied without committing it, and the limits that contain misuse. |
| D12 | Widget: honour Hide balances; restyle fonts | Honour it; keep the widget `kind` names; restyle later. |
| D13 | Month selector patterns | Home: pill + wheel, plus a year stepper. Spend and Flow: pill + sheet. Worth and the SEE ALL list: chip strip. All as in Flutter, except the year stepper. |
| D14 | Quick actions: open over the current tab (Flutter) or switch to Home (MVP) | Open over the current tab. |
| D17 | Minimum iOS: stay on 17 (Liquid Glass only on 26+) or raise to 26 | Stay on 17. Design and review the look on 26+ first, and check that it degrades cleanly on 17. |
| D15 | Recurring look and copy | Redesign card language, Flutter copy ("Bi-weekly", "Next Occurrence"). Keep the approved MVP behaviours (pause/resume, cursor-preserving edit, add button). |
| D16 | Chart curves | Swift Charts where it matches the Flutter chart. A custom `Shape` for the donut and the cash-flow bars, for exact geometry. The Flow 12-month trend is a custom `Path` reproducing fl_chart's cubic curve (smoothness 0.35, flat first tangent, overshoot allowed), not Swift Charts `.catmullRom` (decided 2026-09-29). |

## 3. Cross-cutting rules for every workstream

These come from MIGRATION_SPEC and the specs. Any PR that breaks one is wrong.

**Persistence**
- Mutate memory, then `await persist([sections])`. Never fire and forget. Return the verified `Bool`.
- Each new section gets a typed serializer and a `serialize` case.
- Patch records' `raw` JSON in place. Change only the keys that changed; keep unknown keys and unreadable rows verbatim. New records use Dart `toJson` key order and double lexemes (`100.0`).
- A cascade across sections (category rename, restore) is one commit.

**Dates and time**
- Use `DartDateTime`, `DartCalendar` and the net-worth month helpers only.
- No `Date` arithmetic, no `Calendar.current`, no `DatePicker` for month math.
- Take the clock from `AppModel.now`.
- Display formats are fixed en_US, as Flutter never sets an intl locale (`DartDateFormat` helpers, spec 04 section 4.5).

**Numbers**
- Format money through `model.moneyFormatter`, so Hide balances is honoured everywhere.
- Build percentage strings with `DartFixed.toStringAsFixed`.
- Reject non-finite input.
- When an edit field's text is unchanged, keep the stored value exactly.

**Strings and ordering**
- Compare strings as UTF-16 code units where Dart does (sorting, rule matching, id tie-breaks).
- Use Dart-equivalent `trim` (includes U+FEFF). Where Dart sorts a list whose ties are visible, use `DartSort` (a port of Dart's `List.sort`: stable up to 33 elements, an unstable quicksort from 34; verified). Note any remaining tie-order difference in PARITY_GAPS.

**Accessibility and polish**
- Every animation has a Reduce Motion path.
- VoiceOver labels on charts, tabs and cards.
- Dynamic Type via `Font.custom(_:size:relativeTo:)`.

**Parity tests**
- Every ported calculation gets a Dart-oracle fixture through `ParityHarness`.
- Every mutation gets a "Swift-written store loads in Dart" check (`verify_swift_output_test.dart`).

## 4. Phases

Effort: S is up to a day, M a few days, L a week or more. Phases 2 and 3 split into workstreams that can run in parallel in separate worktrees once Phase 1 has merged.

### Phase 0: Unblock (S)

- D1-D3 and D11 are decided. Answer D4-D17 as their phases come up.
- Security items in section 7.
- Widget copy fix: "Voice Add" currently promises speech. Retitle it unless voice returns.
  Status (2026-09-30): voice returned (option C1, Phase 4); the widget copy is true again. See PARITY_GAPS "Voice entry".

### Phase 1: Foundations (L; everything else depends on this)

**1A. Core infrastructure** (M-L; spec 02 section 4, 04 section 4, 06 section 4.1)
1. Typed section serializers and `serialize` cases for all sections. Also convert goals, categories, tags and rules to the `StoredRow` pattern (unreadable rows kept). Remove the stale fallback, or make it assert in DEBUG.
2. `LedgerIndex` built once per revision, off the main thread, plus `ledgerRevision`. Move `FinancialData.monthLedger`/`totals` onto it, and keep the old functions as test oracles. Add a timing test on `large_10k`.
3. Shared `AppModel.selectedMonth` / `selectMonth`.
4. Helpers: `DartDateFormat` (en_US `MMMM`, `MMM`, `yMMMM`, `MMMd`, `yMMMd`, `MMM ''yy`, `h:mm a`) and `DartString` (trim, lowercase, UTF-16 contains/prefix/equal).
5. Legacy category materialisation. Include template names and expense budget keys, persist `categories` only when the canonical JSON differs, and add `isBuiltIn` and `raw` to category records.
6. Tag and rule records (read-only at this stage), and `tagIds` on `TransactionRecord.Edit` and `addTransaction`.
7. A toast model hosted at the root.
8. Routing gate: consume `pendingAdd` only when unlocked and past onboarding.

**1B. Design system** (M-L; spec 01 sections 1, 3, 4, 5)
1. Bundle 8 font files (Gabarito 400-800, Spline Sans Mono 400-600) with `UIAppFonts` in `project.yml` and a load check. Add the OFL licence texts from upstream and an About > Licences screen.
2. Tokens: all colours in light and dark, the 14-colour chart palette, metrics, a glow modifier with the light-mode swap, motion curves. Fix `purple` and `asterisk_circle`. Keep `Theme.swift` as a shim, then delete it.
3. Text styles: all 23 redesign styles plus the few legacy ones still used.
4. Components:
   - GlowCard, GlowListCard, IconTile, PillChip, PillButton, SegmentedPills (plus the mono variant)
   - MonthPill, BudgieHeader, SectionHeader
   - GlowProgressBar, SplitGlowBar, ProgressRing
   - GlowFab (with the tap burst), BudgieField, DateTile, EmptyStateView
   - Sheet chrome, a centred dialog presenter, RecurrenceGlyph, a swipe-to-delete card row
5. A DEBUG design gallery for screenshot comparison against `native/docs/archive/research/screenshots`.

**1C. Shell** (M; spec 01 section 2, adjusted for D2)
1. Native `TabView` with 5 tabs, each root in its own `NavigationStack`: Home (`dollarsign.circle`), Worth, Goals (`flag`), Spend (`chart.pie`), Flow (`chart.bar`).
   - The tab bar is tinted with the accent colour. Liquid Glass comes automatically on iOS 26+.
   - Pages use a custom `BudgieHeader` and hide the navigation bar on tab roots. Pushed pages keep the system back gesture.
2. Settings becomes a pushed destination from a gear button in the Home header (the old MVP Settings tab goes away). Recurring moves under Settings > DATA. The old History view becomes the SEE ALL page.
3. The unsaved-changes banner is restyled to Flutter's danger strip.
4. FAB placement: bottom-trailing above the tab bar using the safe area. Verify it doesn't collide with iOS 26's tab bar or search accessory.
5. `OpeningView` and a matching launch screen. Restyle the lock screen and privacy cover.
6. Update the UI tests for the new shell, and add a `BUDGIE_SKIP_ONBOARDING` DEBUG hook.

### Phase 2: Tab parity (parallel workstreams)

| Stream | Scope | Spec | Effort |
|---|---|---|---|
| **Home** | Budgets core (set, remove, progress; patch-in-place JSON). Home layout (header, month pill and wheel, hero with numeric roll, gauge, flow chips, safe-to-spend, Budgets card plus EDIT/Add/limit sheets, Recent activity, pills, FAB, quick-expense sheet). Transaction form rewrite (validation copy, category wheel, date tile, tags, auto-categorisation, "Make this recurring", save toasts). SEE ALL month list (chip strip, summary, pinned day headers, swipe delete). | 02 | L+L |
| **Worth** | Net worth mutations (add, update, delete entry and snapshot, carry-forward core-only, select month with persistence) plus the ported Dart tests. Page (chip strip, hero and delta pill, growth chart with range pills, scrub and hover card, split card, toggle and account rows with context menu). Editor. Account history page (hero, stat cards, trend chart, timeline with snapshot delete). | 05 | L+L |
| **Goals** | Goal record with raw and `StoredRow`, mutations, derived status/pace/summary, id format. Page (summary ring, goal cards, status pills, actions sheet, form, allocation dialog with chips, delete confirm, celebration overlay). | 03 | M+L |
| **Spend** | `CategoryBreakdown` (top 6 + Other, palette ranks, delta vs previous month). Donut `Shape` with sweep, selection and hit test. Category rows with progress bars and a tail/expand row. Month sheet. `CategoryTransactionsView` drill-in. | 04 | M+L |
| **Flow** | `CashFlowMath` (window, metrics, YoY, bar layout, sparkline bound). Metric strip, net cash-flow bars with month detail sheet, YoY card, 12-month trend (Swift Charts), range sheet, preview card. Filterable transactions page (`TransactionFilter`, filters card, results summary, pagination). An Insights slot (filled in Phase 3). | 04 | L+L |
| **Settings (from the Home gear)** | Settings root (brand card, eyebrow sections, rows, Theme pill, currency/locale/lock-delay choice sheets, Hide balances, App lock subtitle logic, busy states, version). New setters: locale, hide balances, lock timeout. | 06 section 1.1-1.4 | M |

Suggested order if not fully parallel: Home, then Flow + Spend (they share `LedgerIndex` and filters), then Worth, Goals, Settings.

### Phase 3: Data features (parallel workstreams)

| Stream | Scope | Spec | Effort |
|---|---|---|---|
| **Categories** | Mutators (add, update, archive, move, with errors and copy). Rename cascade as one commit across 5 sections (rules restricted by type per D6). Budget-limit key rename. Re-derive `budgetLimits`. Management page and editor (18 icons, 8 colours). | 06 section 1.5 | L+M |
| **Tags and rules** | Tag and rule CRUD, rule matching (UTF-16, priority, bounds), suggestion engine, Tags & rules page, rule editor. Form integration (already stubbed in Home). History tag filter. | 06 section 1.6 | M+M |
| **CSV import** | Faithful csv 6.0.0 parser port, header and row validation with exact error copy, multiset dedupe, confirm dialog, `importTransactions`. Adversarial-corpus parity tests. | 06 section 1.7 | M+S |
| **Backup** | `DartJSON.encodeIndented`, canonical `toJson` for every record type, envelope encode, ordered-validation decode with exact messages, restore per D10, generator run afterwards, preference mirroring. Encode/decode parity fixtures. | 06 section 1.8 | L+M |
| **Insights** | `InsightEngine` port (9 rules, ids byte-identical so dismissals carry over), `InsightPreferences` (dismiss/snooze prefs with Dart load quirks), section and cards on Flow, 7 ported tests plus differential fixtures. | 07 section A | L+M |
| **Onboarding** | Flag, `completeOnboarding`, 3-page tour with Flutter copy, shown inside the lock gate. One copy change: page 3 names Settings instead of "More". Page 1 keeps Flutter's privacy sentence; its OpenAI mention ships with voice (Phase 4, bead budgie-uia.56). | 07 section B | S+M |
| **Recurring parity** | Pushed page under Settings > DATA with a summary subtitle. Card redesign, Flutter copy, manual "Generate due" button. Form: amount first, "Next 3 Occurrences" preview (`previewOccurrences`), validation copy, start-date time-of-day fix. RecurrenceGlyph on all transaction rows. | 07 section C | M |

### Phase 4: Voice entry via OpenAI (M-L; spec 07 section D)

Status (2026-09-30): implemented as option C1, including the Onboarding page 1 sentence and the quick action, link and widget routes below; see PARITY_GAPS "Voice entry" for what differs from Flutter.

1. **Key plumbing** (section 6).
2. **`OpenAIVoiceClient`**, plain `URLSession`, no dependency:
   - Multipart upload to `/v1/audio/transcriptions` with the Flutter model and prompt.
   - JSON call to `/v1/chat/completions` with `response_format: json_object`.
   - Same system prompt as `voice_expense_service.dart:62-77`: today's date, weekday, and the category names.
   - Timeouts, and the Flutter error copy.
3. **`VoiceDraftParser`:** port `parseVoiceJson` and its 40 Dart tests, plus a differential fixture from the harness.
   - It keeps category clamping, amount sanitising and the 90-day date clamp.
   - The category vocabulary is `model.categories(for:)`, with a fallback of "General" or "Other".
4. **Recording sheet:** listening, thinking and error states; a 30 s cap; AAC 16 kHz mono; stop on background; delete the temp file; Reduce Motion path; haptics.
5. **Form prefill mode:** not dismissible by swipe; no "Make this recurring".
6. **Entry points:**
   - Mic FAB on Home.
   - `AddRoute.voice` for `voice-add` / `voice_add` / `action_voice_add`.
   - Re-register the "Add by Voice" quick action (`mic.circle.fill`).
   - The Voice Add widget, which already exists with that `kind`.
   - All gated on unlock.
7. **Platform:**
   - Add `NSMicrophoneUsageDescription` (Flutter's string).
   - Privacy manifest and App Store privacy label: audio and transcript are sent to OpenAI.
   - Update MIGRATION_SPEC section 11, PARITY_GAPS and `RoutingTests`/`SystemIntegrationUITests`.
   - Onboarding page 1: add the OpenAI sentence (section 6, "Copy and disclosure"; bead budgie-uia.56). The Onboarding stream shipped Flutter's sentence unchanged because voice did not exist yet.

### Phase 5: Verification and release

1. **Parity harness:** extend `ParityHarness` with the fixtures listed in each spec. These cover budgets, goals, net worth mutations, cash flow, breakdown, filters, insights, categories, CSV, backup and voice. Run under multiple time zones, including a midnight-DST zone.
2. **Performance:** a pass on a 10k-row store. Signposts, scroll and filter timing, and glow-shadow cost on device. Done on the simulator, with the device procedure: [PERFORMANCE.md](PERFORMANCE.md).
3. **Visual QA:** Flutter versus Swift side by side on simulators, every tab, light and dark, Dynamic Type, Reduce Motion.
4. **Tests:** UI tests for each tab's main flow; accessibility audit.
5. **Existing beads:**
   - real-device prewarm and locked-launch test (budgie-uia.8)
   - upgrade and downgrade rehearsal (budgie-uia.9)
   - build number (budgie-uia.10)
   - lock cover over sheets (budgie-uia.11)
6. **Docs:** rewrite PARITY_GAPS for the full app, update AGENTS.md (6 tabs, native app), and bump the marketing version.

## 5. Size and sequencing summary

```
Phase 0  decisions + security + widget copy               S
Phase 1  1A core infra | 1B design system | 1C shell      L   (1A and 1B in parallel; 1C after 1B components; native TabView)
Phase 2  Home | Worth | Goals | Spend | Flow | Settings   6 streams, each M-L+L
Phase 3  Categories | Tags&rules | CSV | Backup |
         Insights | Onboarding | Recurring                7 streams, S-L each
Phase 4  Voice via OpenAI, embedded restricted key         M-L
Phase 5  parity, perf, visual QA, device rehearsals       M-L
```

Roughly, the remaining UI work is about 10 times the MVP's Swift UI code, since Flutter's UI is about 28k lines against the MVP's 2.8k. The data layer is the part that is already done.

Critical path: 1A (serializers, `LedgerIndex`, `selectedMonth`), then 1B/1C, then Home, then Flow. Everything in Phase 3 except Insights can start as soon as 1A and the needed components exist.

## 6. Voice: OpenAI key built into the app (D11)

The key ships inside the app bundle, as it does in Flutter. Anyone with the IPA can extract it, so the controls below limit what a leaked key can cost.

**Keep it out of git.**
- The key lives in a gitignored `native/Config/Secrets.xcconfig` (`OPENAI_API_KEY = ...`), included from the target's build settings.
- `Info.plist` gets `OPENAI_API_KEY = $(OPENAI_API_KEY)`, read at runtime via `Bundle.main`.
- Commit a `Secrets.example.xcconfig` with a placeholder.
- A build-phase check fails Release builds when the key is empty or the placeholder.
- Never use `.env` or any asset file.

**Contain misuse on the OpenAI side.**
- Use a dedicated OpenAI project for Budgie.
- Give it a restricted key allowed only the two models used: `gpt-4o-mini-transcribe` and the chat model.
- Set a monthly budget and hard limit on that project, with usage alerts.
- Rotate the key when shipping a release, if usage looks abnormal.

**Contain misuse in the app.**
- Voice runs only in the foreground, after unlock, and one request at a time.
- Cap recordings at 30 s.
- Show a user-facing message on 401/429 instead of retry loops.

**Copy and disclosure.**
- Onboarding page 1 claims data stays on the device "unless you choose to export or share a backup". Flutter ships that claim alongside voice. Amend it to mention that voice entries are sent to OpenAI for transcription (a copy change; the flag format is unaffected). This lands with voice in Phase 4 (bead budgie-uia.56), not with the Onboarding stream: the tour ships Flutter's sentence until then.
- Declare the data flow in the privacy label.

This contradicts AGENTS.md's offline-first rule by explicit decision. Record it there when the feature lands.

## 7. Security findings (act now, independent of the migration)

1. **An OpenAI key was committed to this public repo's history.**
   - Commits `f73a222` ("feat: added budgie insights!") and `f133a64` ("got new API key", 2023-10-12) put `budget_app/.env`, holding an `sk-` value, into history.
   - Both are reachable from `origin/main` on the public repo `khatruong2009/flutter-budget`.
   - The file has been gitignored since, but history still has it.
   - Confirm that key is revoked in the OpenAI dashboard. If it is, nothing else is required. Rewriting history is optional and disruptive.
2. **The Flutter build bundles `.env` as an asset** (`pubspec.yaml:88`), so any key in it ships inside the IPA in plain text. Confirm whether any App Store build contained a live key; rotate if so.
   - The Swift app will also embed a key (D11), so give it its own restricted, budget-capped key (section 6). Don't reuse the Flutter one.
