# Parity gaps: how the Swift app differs from the Flutter app

The native app (4.0.0) implements every feature of the Flutter app (3.4.0).
This file lists every place where it behaves differently, and why:

- **Flutter behaviour reproduced on purpose:** Flutter bugs the Swift app
  copies so both apps agree (approved Q1; fix in both apps later).
- **Deliberate differences (approved):** the owner approved each one.
- **Deliberate differences (not yet approved):** waiting for the owner.
- **Platform:** iOS and packaging differences.

In every case the data is preserved: anything the Swift app does not edit
is written back exactly as read, and the Flutter build can be reinstalled
over the Swift app at any time (verified, see UPGRADE_VERIFICATION.md). Calculations and copy are checked against the
real Flutter code by native/ParityHarness (README there).

## Features added after the MVP (data preserved)

Each of these was missing from the first Swift build (the MVP) and is now
available; the status column records how it matches Flutter.

| Flutter feature | Stored in | Status |
|---|---|---|
| Voice entry (OpenAI) | nothing persisted | Available: the mic button on Home, the "Add by Voice" quick action, `budgetapp://voice-add` / `voice_add` and the Voice Add widget open a recording sheet over whatever is showing; it records up to 30 seconds, sends the audio to OpenAI for transcription and the transcript to a chat model, and continues into the add form prefilled with what was said (nothing is stored until Add). Needs a key in `native/Config/Secrets.xcconfig`; Debug builds without one show the "not configured" message. The widget gallery text ("Speak a transaction") is true again. Differences under "Deliberate differences" below. |
| Insights | `local_insights_*` prefs | Available: the Insights section on Flow (up to three cards, "Insight options" menu with Snooze for 30 days / Dismiss). The engine and the two preferences match Flutter (Fixtures/insights; Swift-written prefs verified in Dart), so a dismissal or snooze in either app hides the same card in the other. |
| Categorization rules, tags | `categorizationRules`, `transactionTags`, `Transaction.tagIds` | Available: Settings > Tags & rules (add and delete tag, the tag stripped from rules; add and delete rule; Fixtures/tags). The transaction form applies rules and toggles tags. Swift also edits a rule in place, switches it on and off, and sets amount bounds and "Any type" (Swift superset, all within Flutter's schema and applied by Flutter's matcher; see "Deliberate differences"). As in Flutter there is no priority or reorder. |
| Category management (add, rename, archive, reorder) | `categories` | Available: Settings > Categories (add, edit with the rename cascade, archive/restore, move up/down). Launch materialises legacy names (transactions, templates, budget keys) and normalises sort orders exactly like Flutter (Fixtures/categories). Differences are listed under "Deliberate differences". |
| Onboarding tour | `flutter.onboarding_completed` | Flag shared with Flutter (`OnboardingFlag`: a CFBoolean true under the same key; missing or another type shows the tour), read at launch after protected data is available, written when the tour is completed or skipped. Available: the three-page tour shows once, in place of the tabs and inside the lock gate (differences under "Deliberate differences"). |
| Backup export/import (JSON envelope v3) | files chosen by the user | Available: Settings > Export backup (share sheet) and Import backup (document picker, "Replace all data?", one-commit restore after a safety copy). Export, decode and restore match Flutter byte for byte (Fixtures/backup); differences under "Backup export and restore" below. |
| CSV import | ledger | Available: Settings > Import from CSV (document picker, counts-only confirmation, one-commit import). Parser, decode, validation, dedupe, copy and the import match Flutter (Fixtures/csvimport); differences under "CSV import" below. |
| Month picker limited to the selected year | UI state | Fixed (D13): Home's month panel has a year stepper above the wheel, and the wheel always shows the selected month. |

## Flutter behaviour reproduced on purpose (approved Q1; fix in both apps later)

- Weekly/biweekly recurrences advance by 7/14 x 24 hours of elapsed time,
  so after a DST change they drift an hour (a midnight template lands at
  23:00 the previous day after the November change).
- Safe-to-spend compares full timestamps against midnight of "today": an
  expense entered today with the default date/time is not counted in
  "Expenses recorded" until tomorrow, while the month totals include it.
- `daysRemaining` counts elapsed 24-hour units, one day short in
  spring-forward months.
- Suggested goal contributions use the wall clock, not the viewed month.
- Legacy `starting_assets`/`starting_liabilities` preferences recreate
  "Starting Assets/Liabilities" accounts whenever the net worth list is
  empty (Flutter never removes those keys).
- An empty bare `transactions` legacy key (`[]`) replaces the ledger of a
  v1 backup envelope during legacy migration.
- "Match device" formats money as en_US (the Flutter app never sets an intl
  locale); JPY/KRW show two decimals.
- Tie order of sorts. Dart's `List.sort` is an insertion sort (stable) for
  lists of up to 33 elements and a dual-pivot quicksort (not stable) from
  34 (dart:_internal `sort.dart`, threshold `right - left <= 32`; verified
  on the VM, Fixtures/backup/dart_sort.json). BudgieCore's `DartSort` is a
  faithful port; the rules order (`CategorizationEngine.ordered`: the Tags
  & rules list, suggestions and the backup export) uses it and matches
  Flutter at any size (Fixtures/tags `sort_*`). The sites below still use
  Swift's stable sort, so from 34 elements the order of tied items can
  differ until they switch to `DartSort`:
  - CSV rows with identical timestamps keep input order, so tie order can
    differ from a Flutter export of the same data. Bytes are otherwise
    identical.
  - Spend tab: categories with equal month totals keep first-appearance
    order, so with 34 or more categories in a month the order of tied
    categories (their rows, colours and which of them fall into "Other")
    can differ (Fixtures/spend `forty_ties`).
  - Worth: accounts with the same month value and the same lowercased name
    keep stored order, and snapshots recorded at the same instant keep
    stored order (34 or more items).
  - Goals: goals with the same completion state and target date keep
    stored order (34 or more goals).
  - Category sort-order normalisation with duplicate `sortOrder` values
    (34 or more categories of a type).
- Category renames follow exact (UTF-16) names only. A case variant
  ("gift" when "Gift" is renamed) or the other Unicode normalisation keeps
  the old name, and gets a definition of its own at the next launch if it
  has none. When the new
  name already has a budget limit, that limit stays and the renamed
  category's limit is dropped (Dart `putIfAbsent`). A case-only rename
  cascades; an icon or colour edit, or the same name with padding, does
  not. Transactions renamed get `updatedAt` = now, even when that is
  earlier than the stored value, and one instant for the whole rename
  (Dart calls `DateTime.now()` once per renamed row, so its rows get
  distinct, increasing microseconds; nothing reads that order).
- A category name with leading or trailing spaces (a transaction's,
  template's or budget key's) is materialised again at every launch: the
  launch pass compares the trimmed name with the stored, untrimmed one
  (`_containsName`), so each launch adds another definition with a new id
  (`type-<uuid>`, the slug being taken). Flutter does this; Swift does it
  once, then stops (see "Deliberate differences (not yet approved)"
  below). A restore adds one as well (Swift runs the launch pass in the
  restore, Flutter at its next launch). Fix in Flutter later.
- Goals: a goal is "Behind" on its target day unless fully funded (the
  deadline is 00:00 of that day), and a goal created today for today is
  "Behind" at once. Overdue goals show "bump to ... to catch up".
- Goals: on hand-edited data with a zero or negative target, any
  allocation stamps `completedAt` although the goal never shows Complete.
- Goals: only Add money celebrates. Raising "Saved so far" to the target in
  the edit form completes the goal with no haptic or overlay, and whether
  Add money celebrates is judged on the goal as shown before the dialog
  (`amount >= remaining`), not on the model's own completion test.
- Insights (BudgieCore `InsightEngine`, `InsightPreferences`; verified by
  Fixtures/insights): ids can repeat (three identical rows give two
  `duplicate:` cards with one id, and two budget keys that slug alike give
  one pace id); both cards show and one dismissal hides both. Recurring
  change and goal behind ignore the selected month. Goal day counts are
  elapsed 24-hour units (one short across a DST change). A snooze is 30 x
  24 hours of elapsed time, so its wall-clock time moves an hour across a
  DST change. Dismissals are permanent, and neither list is ever pruned; a
  malformed snoozed preference stays until the next snooze rewrites it.

## Deliberate differences (approved)

- Net worth mutations (add, update, delete account, delete snapshot, carry
  forward, select month) are awaited and return the verified write result.
  Flutter's add/update/delete/select return nothing and ignore the save
  result (the retry banner still shows); its carry-forward returns whether
  anything changed, which Swift's returns only when the write also
  succeeded.
- Net worth: updating or deleting an account id that does not exist
  writes nothing (Flutter rewrites the unchanged list, revision +1).
  Deleting a snapshot shared by several accounts with the same id writes
  when any of them changed (Flutter decides by the last one only).
- Net worth: an edited account is patched in place. Unknown keys, `id` and
  `createdAt` lexemes, and the stored JSON of kept snapshots survive;
  legacy-shaped snapshots (`monthKey`/`updatedAt`, or no date) of that
  account are written as Flutter writes them. Flutter rewrites every
  account from `toJson`, dropping unknown keys. For data Flutter wrote the
  bytes are identical (Fixtures/worth).
- Net worth amounts must be finite: a NaN/Infinity balance (Flutter's
  editor accepts a 330-digit number as Infinity) is refused before memory
  changes; Flutter keeps it in memory and fails every later save.
- Savings goal mutations (add, edit, delete, add money) are awaited and
  return the verified write result. Flutter's return nothing and ignore the
  save result (its page shows the success snackbar either way; the retry
  banner still shows). Invalid input and unknown ids write nothing in both.
- Savings goals: an edited goal is patched in place. `id` and unknown keys
  survive, and every other key keeps its stored JSON when it already holds
  the value Flutter would write; otherwise Flutter's value is written (int
  or string amounts become doubles, a date that fell back to "now" is
  written out, `completedAt` is always present). Untouched goals and
  unreadable rows are written back verbatim. Flutter rewrites every goal
  from `toJson`, dropping unknown keys and pinning fallback dates of all of
  them. For data Flutter wrote the bytes are identical (Fixtures/goals).
- Savings goal amounts must be finite: NaN/Infinity (Flutter's form accepts
  "NaN", "Infinity" and "1e999") are refused before memory changes, as is an
  allocation whose sum overflows or a goal whose stored amount is a
  non-finite string (an edit, which replaces both amounts, repairs it).
  Flutter keeps the value in memory, and then every later save of the model,
  transactions included, fails until restart. A NaN progress shows 0%
  (Flutter's card throws).
- Savings goals: a row Flutter cannot read (not an object, or a non-string
  `id` or `name`) makes Flutter's whole app load fail (initialization error
  screen). Swift keeps the row verbatim, hides it, and loads the rest.
- Savings goals: editing a goal whose id is duplicated patches each copy
  with the edit, keeping each copy's own `createdAt` and completion stamp
  (Flutter overwrites every copy with the edited card, `createdAt` and stamp
  included). Add money and delete act on every copy in both.
- Savings goals: a new goal's id uses Flutter's format and counter, with
  the timestamp of its `createdAt` (Flutter reads the clock twice,
  microseconds apart). A stored goal without an id gets a UUID that is
  saved with the next goal write; Flutter generates a new
  `savings_goal_...` id at every launch until a goal save.
- Goals dialogs (add / edit, Add money, delete) stay open while the write
  is awaited, with the scrim and buttons inert, then close (Flutter closes
  the dialog first and saves afterwards).
- Goals toasts: "Savings goal added / updated / deleted" and "Allocation
  added" show only when the write is verified; a failed write shows the
  save-failed toast with Retry instead (Flutter shows the success snackbar
  either way), and a change the model refuses (the goal is gone, a sum
  that overflows) closes the dialog without a toast. Toasts replace each
  other rather than queue (shared toast host).
- Goals celebration: the medium haptic and overlay play only when the Add
  money write succeeded (Flutter plays them after a failed save too).
  VoiceOver hears "Goal complete, {name}" queued after the toast, and the
  overlay is one labelled element; Flutter announces nothing.
- Goals amount fields (Target amount, Saved so far, Allocation amount) parse
  with the money format's separators (`AmountInput`, D6): "1.500,00" is 1500
  under de_DE and a lone "12,5" is 12.5; signs, exponents, hex, "NaN" and
  "Infinity" are rejected with the field's error. Flutter strips every ","
  and "$" and uses `double.tryParse` ("1,5" is 15). The prefix symbol is the
  base currency's (Flutter always shows `$`).
- Goals edit form: the amounts prefill locale-grouped ("5,000.00", like the
  budget limit sheet; Flutter "5000.00"), and a field left as prefilled saves
  the stored amount exactly (Flutter re-parses the 2-decimal prefill, so an
  untouched 33.333 becomes 33.33).
- Goals Add money: while the field reads the "Finish goal" text the
  remainder is saved, nudged up by the ulp or two `current + remainder`
  can lose (14133.23 + (60422.9 - 14133.23) is 60422.899999999994), so the
  goal always completes (Flutter fills the remainder rounded to cents and
  can fall short, e.g. 33.334 -> 33.33).
- Goals target date: the shared graphical day picker sheet (the app's
  outlined Cancel and accent-filled OK pills) instead of Material's
  calendar dialog; on iOS 26 the system picker draws the selected day in
  the label colour (its tint reaches only the month header; `.tint`,
  `.accentColor` and `UIDatePicker.appearance().tintColor` were tried),
  where Material fills it with the accent, over Flutter's range (Jan 1 of
  last year to Jan 1 of year + 20, inclusive) stretched to include the
  shown date, so an old overdue goal can be edited (Flutter asserts, D6).
- Goals cards are keyed by goal id, so ring state follows its goal when the
  order changes (Flutter's cards are unkeyed and keep it by position).
- Goals tab state survives tab switches (native `TabView`): the rings and
  the add button do not replay their entry animations on return (Flutter
  rebuilds the page). A celebration still ends when the tab is left. The
  status and pace re-read the clock when the app returns to the foreground.
- Goals icons (D3): `banknote` stands in for Material's piggy bank
  (`savings_rounded`) on the empty state and the "Saved so far" field; the
  ellipsis button's ring uses the 8% pill border token (Flutter 10%).
- Goals actions sheet: the floating card over the dialog scrim at the
  bottom, 20pt from the edges (Flutter's transparent modal bottom sheet),
  sliding up (a fade under Reduce Motion) and dragged down or scrim-tapped
  to close; Edit goal / Delete goal swap it for that dialog in the same
  presentation (Flutter pops the sheet, then opens the dialog). The Add
  money dialog shares the 500pt dialog width
  (Flutter 460, only visible on screens wider than 548pt); a celebration
  card for a long name keeps a 20pt margin (Flutter's reaches the edges).
- Goals accessibility: each card reads as one element ("{name}, {status}",
  valued percent, amounts and pace) with Add money, Edit goal and Delete
  goal actions, the Add money and ellipsis buttons staying separate; the
  summary card reads "Saved so far" with its totals. Flutter labels only
  the add button and the ellipsis.

- Transactions page: when the selected month loses its last transaction,
  the page falls back to the newest month with data (Flutter keeps the
  stale month selected, with no chip highlighted and a "No Transactions"
  list).
- Transactions page: the swipe's medium haptic fires as the drag crosses
  40% of the width (Flutter's fires on release), and the row springs back
  while the confirmation shows (Flutter slides it out first).
- Transactions page: a delete is awaited and shows "Transaction deleted"
  only when the write succeeded, otherwise the save-failed toast (Flutter
  fires and forgets the write and always shows the deleted snackbar).
- Editing a recurring template keeps its next occurrence and paused state
  (Flutter resets both and re-creates up to 90 days of duplicates). A
  schedule change restarts the cursor from the new start date but never on
  or before the last generated occurrence. Pause/resume is available.
- Resuming a paused template (Swift only; Flutter has no pause) moves its
  cursor to the first occurrence on or after today
  (`RecurringGenerator.resumedCursor`, the generator's own steps): the
  occurrences missed while it was paused are skipped, not back-filled. One
  that falls today is still due and is written by the next "Generate Due
  Transactions" or launch. Only `nextOccurrence` changes, so Dart reads
  nothing unusual. `RecurringParityTests.resumed` checks this against the
  Dart oracle's old-cursor case, which records Flutter's generator (every
  missed occurrence in the 90-day lookback). An active template whose
  cursor fell behind, because the app was not opened, still back-fills as
  in Flutter.
- Generated recurring transactions and the advanced cursor are saved in
  one write (Flutter saves them separately; a crash in between duplicates).
- Recurring form "Next 3 Occurrences" while editing starts at the cursor the
  edit will leave (`RecurringTemplate.editedCursor`: what will really be
  generated next). Flutter previews from the start date, because its edit
  resets the cursor there. Adding previews from the start date as Flutter
  does (Fixtures/recurring, five zones).
- Recurring form: no Day of Week wheel for weekly/biweekly; `dayOfWeek`
  stores the start date's weekday (Flutter stores the wheel's value, which
  can contradict the start date). Nothing in either app reads `dayOfWeek`.
- Recurring form: the Day of Month wheel follows the picked start day until
  the wheel is touched (Flutter's defaults to today's day and never
  follows); the preview uses the wheel's value, as Flutter's does.
- Recurring form: "Start date cannot be more than 1 year in the past"
  applies only to a start set in this form (a new template, or an edit that
  picked a different day), never to an untouched stored start (Flutter
  refuses to save any edit of a template that started over a year ago). The
  picker offers only days that pass the rule (`RecurringForm.startDateRange`):
  Flutter also offers the day of `now - 365 days`, whose midnight always
  fails unless it is exactly midnight. An edit's stored start day is always
  offered too: for a template that started over a year ago the picker
  reaches down to it and opens on it, so OK without moving the wheel keeps
  the start and the day of month (the days in between fail the rule).
  Re-picking the stored start's own day keeps the stored value and its
  time, so the schedule and cursor stay (Flutter stores that day's
  midnight).
- Recurring form amount: NaN and Infinity are refused with "Please enter a
  valid number" (Flutter's `double.tryParse` lets NaN through `<= 0` and
  saves it); the locale's decimal separator is accepted.
- Recurring "Generate Due Transactions": one awaited write of rows and
  cursors; "Due transactions generated and next occurrences updated" is
  shown verbatim, also when nothing was due (Flutter), but a failed write
  shows the save-failed toast instead (Flutter ignores the result). With
  nothing due and an earlier write still unsaved, it retries that write
  first and shows the success toast only if everything is then on disk.
  Deleting a template is awaited too: "Recurring transaction deleted" only
  after a verified write.
- Recurring page look (D1, D15): the system navigation bar with the
  redesign title instead of Flutter's gradient `ModernAppBar`; GlowCards
  with a tinted 44pt category tile (income green, else accent) and the
  amount in income green or primary text (Flutter: solid red/green 48pt
  tile, amount in the type colour); the Edit/Delete buttons are redesign
  pills, with Delete in danger (Flutter: both secondary). A third
  "Pause"/"Resume" pill and a "Paused" chip carry the approved pause
  (the MVP's swipe action; a ScrollView of cards has none). Active
  templates are listed first, then paused ones, each in stored order
  (Flutter: stored order). The list scrolls under the opaque system bar
  with no shadow line, as on the other pushed pages. The empty state
  adds an "Add Recurring" pill (Flutter has no add action on this page;
  the "+" in the bar is the approved one), and its glyph is SF `repeat` at
  52pt, as tall as Material's 60pt `repeat` (about 49pt) but wider, with
  rounded corners.
- Recurring card at accessibility text sizes: the description wraps
  freely with the Paused chip and the amount under it, "Pattern" and
  "Next Occurrence" stack, and the buttons grow with their text (at
  least 44pt). Flutter keeps both rows side by side.
- Recurring form: a sheet with the redesign fields instead of Flutter's
  centred dialog, with the Expense/Income toggle when adding (Flutter's
  type is fixed by the caller); an edit keeps the type fixed as Flutter.
  The fields are the transaction form's redesign `BudgieField` and
  `DateTile` (D1, D5): chip-surface fill, 52pt, and a two-line Start Date
  tile with its caption inside, a calendar glyph and a chevron. Flutter's
  are card-coloured with a 1.5pt border, about 44pt tall, with "Start
  Date" as a label above a one-line tile. The wheels are filled the same
  way, and their selection band is the system capsule (Flutter: a
  radius-8 rectangle).
- Recurrence glyph on every transaction row with a template id (Home
  Recent activity, Flow preview and Flow SEE ALL too; Flutter shows it only
  on the Recurring card, the Home SEE ALL month list and the category
  drill-in), and ", recurring" in those rows' VoiceOver text.
- Onboarding gate order: the flag is read once per launch, synchronously,
  after the protected-data wait and before the data screens appear (no
  loading spinner, and a prewarmed launch cannot read it as missing). A
  quick action, widget or `budgetapp://` link arriving during the tour stays
  queued and opens when the tour is completed or skipped (Flutter opens the
  form over the tour). Completing sets the flag and closes the tour at once
  (`UserDefaults` writes cannot fail; Flutter closes it in a `finally`), so
  the button never shows Flutter's spinner. Completing also replaces a
  number 1 stored under the flag (e.g. by `defaults write -int 1`) with a
  real bool: the key is removed before the set, which `NSUserDefaults`
  would otherwise skip as unchanged. Flutter's `setBool` leaves the number,
  so its tour shows on every launch.
- Onboarding page 2 title wraps "Track what comes / and goes." on a phone;
  Flutter's wraps "Track what comes and / goes.". SwiftUI's text layout
  moves a word down so the last line is not a single word, and `Text`
  has no option to turn that off (only a UIKit label could).
- Onboarding page 3 copy (D2, no More tab): "...and Spend, Flow, and
  Settings (behind the gear on Home) help you understand and manage your
  budget." (Flutter: "Spend, Flow, and More"). Page 1 adds a sentence to
  Flutter's privacy text (owner-approved wording): "Voice entries are the
  one exception: your recording is sent to OpenAI to be turned into an
  expense." The page scrolls at large Dynamic Type sizes like the others.
- Onboarding symbols (D3): `wallet.bifold.fill` (`creditcard.fill` before
  iOS 18), `chart.bar.xaxis.ascending` and `chart.xyaxis.line` stand in for
  Material's `account_balance_wallet`, `add_chart` and `insights` (no plus
  on page 2, no sparkles on page 3), drawn at 40pt so the glyphs are the
  size of Flutter's 52pt icon boxes.
- Onboarding accessibility and large text: the page dots are one adjustable
  VoiceOver element ("Tutorial page, 2 of 3"; swipe up or down to change
  page), and Continue announces the new page (Flutter only labels the dots
  and the pages). At large Dynamic Type sizes a page scrolls (Flutter's
  column overflows), and the Skip and Continue buttons grow with their
  text.
- Both store files unreadable: Swift stops with "Your data couldn't be read"
  until the user chooses to start empty (Flutter silently starts empty). The
  set-aside `.corrupt-*` files are kept in both.
- Unreadable rows (malformed JSON rows in a section) are kept verbatim and
  hidden; Flutter drops them on its next save (transactions) or fails to
  load (recurring, net worth, goals). For categories, one malformed row
  makes Flutter replace the whole list with the built-in seeds, and for
  tags and rules it makes Flutter load an empty list, and its next tag or
  rule save destroys the stored rows; Swift keeps using the readable rows
  (the seeds only when none are readable). A rule whose `priority` is a
  number JSON writes as infinite (`1e400`) is one of those rows for Dart
  (`toInt()` throws); Swift reads it with the largest priority.
- At launch Flutter rewrites the whole `categories` list in canonical
  `toJson` form whenever it differs from the stored JSON (a row missing
  `isBuiltIn`, say). Swift writes the list only when a definition was added
  or a sort order changed, and patches just those keys, so unknown keys
  survive.
- Category edits patch the changed keys of the rows they touch (unknown
  keys, number lexemes and unreadable rows survive). Flutter rewrites the
  whole `categories` list, and on a rename the whole `transactions`,
  `recurringTransactions` and `categorizationRules` sections, in canonical
  `toJson` form. On data Flutter wrote itself the bytes are identical
  (Fixtures/categories).
- Renaming a category (D6) renames the rules whose type is that category's
  type or that apply to any type. Flutter also renames rules of the other
  type: renaming the expense "Gift" moved an income-only "Gift" rule to a
  name the income list does not have, so it stopped suggesting anything.
- A category edit and its rename cascade are one commit of every section
  it changed (`categories`, `transactions`, `categoryBudgetLimits`,
  `recurringTransactions`, `categorizationRules`). Flutter makes up to four
  commits with no rollback, so a failed write, or leaving the page while it
  saved, left a half-renamed state (definition renamed, rows not).
- A category save that fails stays in memory behind the unsaved-changes
  banner (Retry, or the next save, writes it) and the caller shows the
  save-failed toast. Flutter's `CategoryProvider` throws: the page shows
  "Could not update this category", skips the rename cascade, and no banner
  covers the lost change.
- Deleting a tag writes `transactionTags` and `categorizationRules` in one
  commit. Flutter makes two (tags, then rules), so a failed second write
  left rules naming a deleted tag, which makes its backup import refuse the
  file. Flutter also rewrites both lists when nothing changed (an unknown
  tag or rule id); Swift writes nothing then (the stored content is the
  same either way).
- Tag and rule edits patch only what changed: a new row has Dart's `toJson`
  shape, and deleting a tag rewrites just the `tagIds` of the rules naming
  it (unknown keys, number lexemes, non-string `tagIds` elements Dart
  ignores, and unreadable rows survive). Flutter rewrites both lists in
  canonical `toJson` form; on data Flutter wrote itself the bytes are
  identical (Fixtures/tags).
- A tag or rule save that fails stays in memory behind the unsaved-changes
  banner (Retry, or the next save, writes it) and the caller shows the
  save-failed toast. Flutter is silent: the change stays in memory with no
  message and is gone after a relaunch.
- BudgieCore refuses a rule whose trimmed merchant text is empty, whose
  amount bound is not finite, or that names a tag id no tag has. Flutter's
  provider accepts all three: its dialog never sends the first (Add does
  nothing), the second cannot be saved, and the third makes its backup
  import refuse the file. The rule editor and the Swift-only edit
  (`updateRule`) also refuse (`RuleDraft.boundsError`; Core's `addRule`
  stores them, as Flutter's provider does, but the editor checks first)
  a negative bound ("Amounts can't be negative": every amount a
  rule is checked against is 0 or more, since the form reads an empty or
  unparsable field as 0 on a decimal pad without a minus key and saves only
  amounts above 0, so under Dart's `matches` a negative minimum is no bound
  and a negative maximum never matches) and a minimum above the maximum
  ("Minimum can't be more than maximum": the rule could never match; equal
  bounds are one exact amount). An edit may keep tag ids the rule already
  stores without a tag (foreign data), and an edit of an unknown id is
  refused ("This rule no longer exists"). The rule editor shows a refusal
  in danger caption above its buttons; its fields check the bounds first
  and show the two bound messages under the fields.
- Tags & rules page (D1 port of the Material page): padded 16 like
  Flutter's ListView; the title is cardTitle in the navigation bar
  (Flutter: M3 titleLarge AppBar); rows use the redesign's 40pt icon tiles
  (`tag` in accent, `sparkles` in info, Settings' Tags & rules tint) and
  rowTitle / rowSubtitle (Flutter: plain 24pt Material icons, M3 ListTile
  bodyLarge / bodyMedium); the delete icon is `trash` at 20 in a 48pt
  button. The "ADD" buttons, copy, order, empty cards and the rule
  subtitle's raw tokens ("contains · Groceries · 1 tags") are Flutter's.
- Deleting a tag asks first ("Delete tag?", Cancel / Delete), because it
  also removes the tag from every merchant rule; Flutter deletes at once.
  Deleting a rule is instant (no confirmation), as in Flutter, but memory
  changes first, so the row goes before the write; Flutter's row stays
  until its write is done. A failed write leaves the rule deleted in memory
  behind the unsaved banner, with the save-failed toast.
- New tag dialog: the redesign's centred card with a "Tag name" caption
  above the field (Flutter: an AlertDialog with a hint only) and Cancel /
  Add pills. A duplicate name shows "A tag with this name already exists"
  under the field and keeps the dialog open with the typed name (Flutter
  closes it and shows the message in a SnackBar); after the first Add the
  message follows the text. A blank name closes silently, as in Flutter.
- New merchant rule dialog: the redesign's centred card; Type, Match and
  Category are field-style boxes that open a popover list anchored to the
  box, a check on the current option (Flutter: Material dropdown menus
  over the field), and Type and Match read "Income" / "Expense" and
  "Contains" / "Starts with" / "Exact match" (Flutter's dropdowns show the
  raw enum names). As in Flutter, a dropdown tapped with the keyboard up
  dismisses the keyboard first; the list opens once it has gone. The tag
  chips are the transaction form's pills, 8 apart, under a "Tags" caption
  (Flutter: Material FilterChips 4 apart with no caption). Add is shown
  disabled while the merchant text is blank (Flutter's Add is enabled and
  does nothing). The merchant field is not capitalised and its Done key
  closes the keyboard, as in Flutter. With the keyboard up the fields
  scroll under the title (as Flutter's SingleChildScrollView); Swift adds
  cues that more is below: the scroll indicator flashes once the keyboard
  is shown, and the bottom edge fades while more is below (iOS 18+).
  A type change keeps the category shown (the picked one, or the first
  expense category when untouched) when the new type has that name, else
  takes its first, as in Flutter.
- Tag pills (the rule dialog and the transaction form) are one line; a
  name wider than the card gets a row of its own and ends in an ellipsis
  (Flutter's chip label is one line too and fades at the edge).
- The tag and rule dialogs, and the tag delete, stay open and inert while
  the change is written (Flutter closes first and writes afterwards).
  Memory changes first, so the new or deleted row is already shown or
  removed on the page behind the dialog.
- VoiceOver reads each rule's delete button as "Delete rule {pattern}"
  (Flutter's tooltip is "Delete rule" on every row) and offers Delete as
  an action on each tag and rule row (and Edit on each rule row).
- Swift superset (approved 2026-09-29): Flutter can only add and delete a
  rule. Every addition below writes only fields Flutter's
  `CategorizationRule` schema already has, in its `toJson` form, and
  Flutter's `matches` / `suggest` already apply them, so a downgraded
  Flutter build loads the rules and suggests exactly as Swift did
  (`verify_swift_output_test.dart`: the loaded rules, `toJson` bytes of
  Swift-made rows, and `suggest` over probes at, just below and just above
  every bound, for both types). Priority stays 0 for new rules and is kept
  as stored on edits; there is no priority or reorder UI.
  - Edit in place: tapping a rule row (or VoiceOver's Edit action) opens
    "Edit merchant rule", prefilled, with Save. The rule keeps its id and
    stored position (Flutter's `addRule` with an existing id would move it
    to the end), and only the keys whose value changed are patched (a
    stored `5` for a 5.0 bound, unknown keys and a foreign `matchType`
    stay). Every readable row with the id is edited (foreign data can
    repeat an id; the backup import refuses that anyway). An edited rule's
    own category stays selectable under its type even when archived or
    missing, so Save never changes it silently. Flutter would list the
    edited rule where it is stored, as Swift does.
  - Enable switch (`isEnabled`): each rule row has a switch (the app's
    green, like the Settings switches); a disabled rule's tile and text are
    dimmed (muted opacity) and its subtitle ends in "off". Dart's `matches`
    skips disabled rules, so the next matching rule is tried.
  - Amount bounds (`minimumAmount` / `maximumAmount`): optional "Minimum
    amount" / "Maximum amount" fields at the end of the editor, with the
    currency symbol, parsed like the other amount fields (`AmountInput`,
    D6); empty is no bound. Both are inclusive, as Dart's `matches`
    (NaN would pass both; the form never sends it). Written as Dart
    doubles (`20.0`), a cleared bound as a present `null`. An edit
    prefills a bound rounded to cents; a field left as prefilled keeps the
    stored value exactly. The form checks a rule's bounds against its
    Amount field, which reads as 0 until typed, so a rule with a minimum
    above 0 waits for the amount (as it would in Flutter).
  - Any type (`transactionType: null`): the Type dropdown offers "Any
    type" after Income and Expense. Its Category list is the expense list
    followed by the income names the expense list lacks (UTF-16), since
    the rule serves both forms. The form applies a suggestion only when
    its category is in the form's list and then tries no later rule
    (Flutter's gate, reproduced), so an Any-type rule on a one-type
    category suggests nothing for the other type and hides later rules
    there; the editor says so under the picker ("Only expenses have
    Groceries, so income won't be categorized by this rule.").
  - Subtitle: it starts with Flutter's exact string, which is all of it
    for a rule Flutter's dialog could make (one type, no bounds, enabled):
    "contains · Groceries · 1 tags". Swift-only parts follow, each after
    " · ": "any type", the bounds ("at least $5.00", "up to $20.00",
    "$5.00 to $20.00", "exactly $5.00"; the money format, so Hide balances
    masks them) and "off": "contains · Gift · any type · up to $20.00 ·
    off". Flutter shows only the leading part for these rules.
- Category Move up / Move down with archived rows hidden moves the row past
  the previous or next shown row. Flutter moves by one in the full list
  (archived rows included), so a move over a hidden archived row seemed to
  do nothing. With "Show archived" on the moves are Flutter's. Moving an
  unknown id does nothing (Flutter throws "No element"; unreachable from
  the page).
- Categories page (D1 port of the Material page): the add action is only
  the bar's "+" (Flutter also shows a FAB running the same action); the
  title is cardTitle in the navigation bar (Flutter's AppBar title is M3
  titleLarge, 22 / w400); the row menu is the system `Menu` (Flutter's
  Material popup menu), with the same items and order.
- Category editor: the redesign's centred card (`budgieDialog`, as the
  Goals form) instead of Material's AlertDialog: the title is centred in
  goalTitle (Flutter: headlineSmall, left), "Name" is a caption w600 above
  the field (Flutter: a floating label), and Cancel / Add | Save are pills
  (Flutter: a text and a filled button). The icon and colour choice
  buttons, their sizes, colours and order are Flutter's, and so is the
  wrap: the grid is capped at five buttons a row (icons 5/5/5/3, colours
  5+3), though the wider card would fit six. The Name field's return key
  is Done and only dismisses the keyboard, as Flutter's.
- Category editor errors show inline under the Name field and keep the
  dialog open with the typed name: "Enter a category name" (Flutter's
  validator) and, before saving, the provider's "A category with this
  name already exists", which Flutter shows in a SnackBar after the dialog
  has closed (the input lost). After the first Save the message follows
  the text as it is edited (Flutter re-validates only on Save). The
  dialog stays open and inert while the edit saves, and closes on a failed
  write with the save-failed toast (the change is kept behind the unsaved
  banner).
- The category editor's colour rows are 8pt apart, like the icon rows
  (Flutter's colour `Wrap` sets no run spacing, so its two rows touch).
- Refused category row actions ("At least one category must remain
  active") show the neutral toast (below), Flutter's default SnackBar
  look; the editor's errors stay inline (above).
- Category icons (D3: SF Symbols tinted with Flutter's colours):
  `car.fill` and `pawprint.fill` stand in for the filled Cupertino
  `car_detailed` and `paw`, the other 16 are the outline SF counterparts
  (`money_dollar` is `dollarsign`, clearly taller than Cupertino's small
  dollar; `person_2` is thinner in Cupertino). The Categories page draws
  them at 17pt (row tiles, the editor grid) and the row menu's bold
  `ellipsis` at 17pt, where they measure within a pixel or two (at 3x) of
  Flutter's 20pt Cupertino glyphs and 24pt `more_horiz` (SF Symbols draw
  about 18% larger at the same size); the editor grid uses the regular
  weight, closer to Cupertino's strokes. The row tiles keep the shared
  `IconTile`'s medium weight, and every other screen's category tile
  (Home, Spend, Flow, the form) still draws the symbol at the shared
  `IconTile` 20pt, about 18% larger than Flutter's.
- Categories page, platform look: "Show archived" is the system switch
  (the iOS 26 track is about 62 x 28 against CupertinoSwitch's 51 x 31;
  its right edge lines up with Flutter's), and the row cards are the
  shared `GlowCard` (continuous corners and a fainter border than
  Flutter's circular radius-26 arcs).
- `Toast.Style.neutral` stands in for Flutter's default SnackBar with the
  primary text colour as the fill and the page background as the text
  (M3 inverseSurface / onInverseSurface from the seed are close but not
  those tokens), floating with radius 12 like the other toasts (Flutter's
  default is fixed, full width, radius 4).
- A quick action, widget tap or deep link on a locked launch opens its
  form only after App Lock is passed (Flutter pushes it on the root
  navigator, above the lock screen).
- A preference with an unexpected type reads as absent; Dart would throw.
- Numbers typed into Swift are validated finite; Dart would fail to save a
  NaN/Infinity forever.
- App Lock on a device with no passcode lets the user in with a message
  (Flutter shows its lock screen with an unlock button that cannot
  succeed). Without a passcode there is nothing to authenticate against.
- Editing a transaction without touching the amount keeps the stored
  value exactly; the Flutter form re-parses its 2-decimal prefill.
- Transaction form (D5): a card-styled sheet instead of a centred dialog,
  with an Expense/Income toggle (Flutter's type is fixed by the entry
  point) and "Edit Expense/Income" titles when editing (Flutter says "Add").
- Transaction form: saving blocks swipe-to-dismiss, so a failed write
  always shows its toast (a barrier tap in Flutter drops the snackbar).
- Transaction form: NaN, Infinity and overflowing amounts ("1e400") are
  rejected with "Please enter a valid number" (Flutter accepts them).
- Transaction form: the device's decimal separator is accepted ("12,5" in
  a comma locale, as the MVP did); Flutter's `double.tryParse` rejects it.
  Rule suggestions parse the amount the same way.
- Transaction form: clearing the description on an edit saves
  "Transaction" (Flutter keeps the old description), and the non-blocking
  "Description is recommended" warning is dropped (Flutter shows it only
  while the save is in flight).
- Transaction form: when a rule changes the category, the wheel scrolls to
  it (Flutter's wheel stays on the old row while the saved value changes).
- Transaction form: the date picker's range stretches to include a stored
  date before 2000 or in the future (Flutter's `showDatePicker` asserts).
  The picker is a graphical calendar sheet with Cancel / OK.
- Transaction form: switching Expense/Income (D5) gives an edit its stored
  category back on the record's own type (else a category the new type
  lacks becomes its first), drops the tags the last rule suggestion added
  (manual picks and the record's stored tags stay), then runs the new
  type's rules on the current description and amount.
- Transaction form: the amount icon is the base currency's symbol (Flutter
  always shows `$`); the wheel tiles use the danger/income tokens (Flutter
  uses fixed #EF4444/#10B981 in both themes); tags are redesign pill chips
  (accent tint with a checkmark when selected) instead of Material
  FilterChips.
- Transaction form: an edit offers "Delete Transaction" with a
  confirmation (Flutter deletes only by swiping the row).
- Transaction form: "Make this recurring" turns the same sheet into the
  recurring form for the form's type (Flutter pops the dialog and opens a
  new one); as in Flutter nothing is carried over and an edit is discarded.
- Budget limit sheet (D6): the field prefix is the base currency's symbol
  (Flutter hard-codes "$").
- Budget limit sheet and Flow SEE ALL Min / Max amounts (D6): both parse
  with the number format's separators (`AmountInput`): "1.500,00" is 1500
  under de_DE (Flutter's limit strips `[^0-9.]` and reads 1.5; its filter
  drops ',' and reads 1.5 from "1.500,00" and 1.23456 from "1.234,56"). A
  lone grouping separator not followed by three digits is read as the
  decimal key of a keyboard in another locale ("12,5" is 12.5 under en_US;
  Flutter's limit and filter read 125). Only digits and separators are
  accepted: Flutter saved "-5" as 5 and "1e3" as 13, and its filter took
  "-5", "+5", "1e3", "0x10", "NaN" and "Infinity" (NaN marked the filter
  active but excluded nothing; an infinite minimum hid every row); Swift
  leaves such a bound unset. A limit must be above 0; a filter bound may be
  0.
- Budget limit sheet: an untouched prefill saves the stored limit exactly
  (99.999 stays 99.999, and 0.001 can be saved); Flutter re-parses the
  2-decimal prefill, saving 100.0 and refusing "0.00".
- Budget limit field: filled with the chip-surface token (Flutter's theme
  fill is #F9FAFB light / #15151F dark; dark is identical).
- Home month panel: a year stepper (previous/next year, light haptic,
  keeps the month) sits above the wheel (D13), and the wheel always shows
  `selectedMonth` (Flutter's wheel keeps the month it first showed, so it
  can disagree with the pill).
- Home month wheel: a custom snapping drum with the CupertinoPicker
  geometry (34pt rows, diameter ratio 1.07, squeeze 1.45, about five rows
  in 128pt, 0.447 dimming, band inset 9 / radius 8) that selects every
  month it passes like Flutter. Rows are compressed and foreshortened but
  drawn flat (no 3D tilt), and each row is dimmed by its share inside the
  band (Flutter dims the part of each glyph outside the band). Row height
  and box scale with Dynamic Type; VoiceOver gets one adjustable "Month".
- Home hero: the odometer rolls the rounded amount (Flutter's rolling
  widget truncates the cents, so it can show 0.01 less than the halo and
  VoiceOver), is not re-rolled by a text-size change, and scales down to
  fit instead of overflowing a narrow screen.
- Home: the page's bottom padding clears the add button and the mic button
  above it (130pt; Flutter lets the Expense/Income pills sit under them).
  The 44pt mic button (`mic.fill`, "Add by voice", `home.voice`) is centred
  over the add button 12pt clear of it, as Flutter's Column; it opens the
  voice flow through the same presenter as the quick action, so it is
  gated, and dropped while a voice flow is already up, like them.
- Home Recent activity: a row opens its edit form like SEE ALL's rows
  (Flutter's rows are not tappable).
- Home spend gauge: under Reduce Motion a changed value jumps (Flutter
  only skips the first fill and still animates changes).
- Home accessibility: the gauge reads "Spent X of Y income" and the year
  stepper's buttons are labelled; a recent-activity row's VoiceOver label
  is the description ("Transaction" when empty) with the rest as its
  value, which reads the same as Flutter's single label.
- Category icons: a transaction, template or budget row finds its
  category's icon by name case-insensitively, archived definitions
  included (`categoryInfo(named:type:)`). Flutter reads its active
  `expenseCategories` / `incomeCategories` map by exact name and shows its
  fallback icon (the grid; a bag or dollar on the recurring list) for an
  archived category or a case variant.
- Transactions page (SEE ALL): a row's VoiceOver label reads the amount
  through the money formatter ("expense $12.50": base currency, masked
  under Hide balances); Flutter's reads "expense of 12 dollars and 50
  cents" whatever the currency. Both read the date as yMMMMd.
- Flow SEE ALL category options: names whose lower-case forms are equal
  ("Groceries" / "groceries") keep first-appearance order (Swift stable
  sort); Dart's sort is not stable from 34 options, so their relative order
  can differ (switch to `DartSort`, see the tie-order note above).
- Flow SEE ALL rows (D7): a tap opens the edit form and a left swipe asks
  "Delete Transaction" before deleting; the delete is awaited and toasts
  "Transaction deleted" or the save-failed message (a row already gone just
  closes the alert). Flutter's rows are read-only.
- Flow SEE ALL month pill (D6): picking a month in 'SELECT MONTH' also sets
  From/To to that month's first and last day, so the list shows that month;
  Flutter changes only the shared month and the list ignores it. While
  From/To are not exactly that month (before any pick, after RESET or after
  editing a date) the pill's label is dimmed to the secondary colour, no
  month is ticked in the sheet, and VoiceOver adds "not filtering the list";
  Flutter's pill always looks applied and ticks the shared month.
- Flow SEE ALL amount fields (D6): the prefix is the base currency's symbol
  (Flutter hard-codes "$ ").
- Flow SEE ALL chrome: the system navigation bar's back button and swipe
  replace the 36pt chip back button, and the 'Transactions' title (in
  sectionHeader, beside the back button) and the month pill sit in that
  bar, so the list scrolls under a normal bar; Flutter's header row
  (pageTitle) scrolls away with the page.
- Flow SEE ALL tag chips: redesign pills (accent tint with a check when
  selected, outlined otherwise) instead of Material `ChoiceChip`s.
- Flow SEE ALL sheets: 'SELECT CATEGORY' / 'SELECT MONTH' use the redesign
  sheet chrome (44x4 handle) with plain rows (no Material ripple); the From/To
  date picker is the shared graphical day picker sheet (Cancel / OK) instead
  of Material's calendar dialog.
- Flow SEE ALL: dragging the page down into the keyboard dismisses it
  interactively (the decimal pad has no return key); scrolling up leaves it
  up, and rows scrolled above it still swipe to delete. Flutter keeps it up.
- Flow SEE ALL accessibility: rows read "description, category, date, signed
  amount" with an edit hint and a Delete action; filter controls are
  labelled. Flutter authors no semantics on this page.
- Safe-to-spend breakdown sheet: redesign sheet chrome (card colour, 44x4
  grab handle, 28 radius) instead of Material's default sheet and 32x4
  handle; the divider uses the border token.
- Quick-expense sheet: a native sheet at 66% or 90% height; Flutter's
  draggable sheet also shrinks to 36% and closes there.
- Spend drill-in (like D7): rows open the edit form and swipe to delete;
  the delete is awaited and shows "Transaction deleted" or the save-failed
  toast (Flutter's rows do nothing on tap, and its delete is fire-and-forget
  with no snackbar). The swipe's medium haptic fires at the 40% threshold
  and the row springs back while the confirmation shows, as on SEE ALL.
- Spend drill-in: the colour and icon follow the category's current rank
  in the month (Flutter keeps the ones it was pushed with, so a delete that
  re-ranks the category shows a different colour there than on the list).
- Spend drill-in: the system navigation bar (back button, edge swipe,
  category title in cardTitle) instead of Flutter's 36pt header; the back
  tap has no light haptic.
- Spend empty states: `EmptyStateView`'s plain 56pt symbol in the
  secondary colour instead of Flutter's 96pt expense-gradient tile with a
  white glyph.
- Spend donut: VoiceOver reads it as one adjustable element ("Spending by
  category", the total or the selected slice as its value; swipe up/down
  selects slices). Flutter's donut has no semantics.
- Spend tab: the month, selected slice, expanded tail and a pushed
  drill-in survive a tab switch, and the donut does not sweep again
  (Flutter's tab pages are probably rebuilt; not verified on device).
- Spend tab: under Reduce Motion a changed bar value jumps (Flutter only
  skips the first fill and still tweens month changes).
- Spend tail row: the tile's neutral fill is the hairline token (white 6%
  dark, ink 6% light; Flutter's light value is black 5%).
- Spend month sheet: a native sheet (system scrim, drag to dismiss)
  sized to its content, instead of Material's bottom sheet.
- Home sheets (safe-to-spend breakdown, EDIT / Add pickers, limit sheet):
  native sheets sized to their content with the system's bottom allowance
  (floating and inset on iOS 26) instead of Flutter's `SafeArea`; the
  pickers cap at 75% of the screen, and the limit sheet sits on the
  keyboard with Flutter's 16pt gap under Save.
- Flow tab: the chart range and a pushed SEE ALL page survive switching
  tabs (the native `TabView` keeps each tab's state); Flutter's `PageView`
  disposes the tab, so its range resets to 6 months on every tab switch.
- Flow tab accessibility: bars, metric chips, year-over-year rows and the
  trend have VoiceOver labels ("September 2026, net +$3,158", "12-month net
  trend, From ... to ..."); Flutter has no semantics there and reads only
  the bare texts.
- Flow sheets (chart range, month detail): the redesign sheet chrome (44x4
  handle at 60%, 24 radius, content-sized detent) instead of Material's
  sheet with a 40x4 handle at 30%; range rows dim on press instead of the
  Material ripple.
- Flow bars: the current month's badge capsule grows to fit its text
  (Flutter clips it to four bar widths), and month labels overflow their
  column rather than clip at large text sizes.
- Flow month detail sheet: the net amount scales down to fit one line
  (Flutter's row overflows); SF Symbols stand in for Material's
  `bar_chart`, `south_west`, `north_east` and `check`; a negative net shows
  a down-trend symbol (Flutter shows `trending_up`, D6).
- Flow trend: a data change interpolates the twelve values (and the bound
  derived from them) over 150ms; fl_chart interpolates the spots and the
  axis bounds separately, so mid-animation frames can differ slightly.
- Flow preview rows find the category icon like the other transaction rows
  (case-insensitive, archived included; see "Category icons" above).
- Goals glyphs are sized by the rendered tick / dots, not the point size:
  SF `checkmark` medium at 20 (ring) and 25 (celebration) and `ellipsis`
  medium at 12 match Material's `check_rounded` 28 / 34 and
  `more_horiz_rounded` 18 at w500 (18.5 / 22.5 / 11.5pt wide), in boxes of
  Flutter's icon sizes.
- Toasts: the text and Retry use `onAccent` (#0A0A12 dark, white light)
  for Flutter's M3 `onInverseSurface` snackbar text (a dark neutral in
  dark mode), not white. A toast shown again while it is up restarts its
  4s (Flutter queues it).
- Month chip strip (Worth, Home's SEE ALL): the selected chip is centred
  when the strip appears, as Flutter's `MonthSelector` does after its first
  frame.
- Worth account rows: the long press is a native context menu with the
  sheet's actions (Edit Balance, View History, Delete Account) instead of a
  Material bottom sheet.
- Worth hero (D6): the odometer rolls the rounded whole-unit amount in the
  base currency (Flutter truncates the fraction and hard-codes "$"), shows
  "••••" under Hide balances like Home's hero (Flutter shows the digits),
  scales down to fit (Flutter overflows), and a sign change rebuilds the
  reels (Flutter's "-" is a separate text beside them).
- Worth editor: a failed write closes the dialog and shows the save-failed
  toast (Flutter only shows the banner); Save, Cancel, close and the scrim
  are disabled while saving (a Flutter double tap adds the account twice).
- Worth editor: the balance month is an inline month grid with a year
  stepper (January 1970 to this month) instead of Material's calendar
  picker, so a persisted future month cannot hit the picker's assert.
- Worth editor: an untouched balance saves the stored value exactly
  (Flutter re-parses its 2-decimal prefill); a comma-decimal keyboard's ","
  typed at the end reads as "." (Flutter's formatter drops it, D6); the
  field glyph follows the base currency (Flutter: `attach_money`).
- Worth editor: the banner and Cancel / Save stay in place and only the
  fields scroll when the keyboard or a large text size leaves too little
  room (Flutter scrolls the whole dialog, buttons included). The account
  name glyph is SF `wallet.bifold` (iOS 18+; `creditcard` on iOS 17) for
  Material's `account_balance_wallet_rounded`.
- Worth growth chart hover card: its text stops growing at the xxxLarge
  Dynamic Type size so the card fits the 180pt chart (Flutter's overflows).
- Worth editor fields are the shared `BudgieField` and `DateTile` (1.5pt
  focus stroke, chevron) instead of the editor's own chrome (2pt accent
  focus border, accent calendar icon); both label their fields in
  `caption` w600. The close button has a VoiceOver label.
- `BudgieField` labels everywhere are `ModernTextField`'s (the transaction
  and recurring forms'): `caption` w600 above the field. The Goals form's
  and the Settings dialogs' Flutter fields use a regular-weight Material
  floating label instead.
- Worth: "Delete account?" (from a row or the history page) and "Delete
  balance update?" are system alerts with Flutter's copy instead of
  Material dialogs; Delete keeps a plain (not destructive, not red) role,
  as Flutter's accent TextButton. A failed delete or month selection shows
  the save-failed toast (Flutter: banner only).
- Worth tab: the Assets / Liabilities tab, the chart range and a pushed
  history page survive switching tabs (Flutter's `PageView` resets them).
- Worth growth chart: a range change that changes the number of points
  cross-fades over 150ms (fl_chart morphs the spots); VoiceOver reads a
  summary and steps through the points, and rows, hero, split card and
  delta pill have labels (Flutter labels only the hero and FAB).
- Worth account history: the page scrolls inside the safe area, so its last
  timeline row clears the tab bar; Flutter's page keeps only 32pt of bottom
  padding under the floating dock, which covers the last rows.
- Worth account history chart tooltip: drawn once, and kept inside the
  plot horizontally. fl_chart supplies one touched spot per line (glow and
  main), so Flutter stacks the date/amount block twice, and its tooltip is
  not clamped (at the first point it runs off the screen edge).
- Worth account history chart: a data change (a deleted update) redraws at
  once; fl_chart tweens the spots and axis bounds over 150ms linear.
- Worth account history: when the account disappears while the page is
  open (deleted elsewhere, or a restore without it) the page shows "Account
  deleted" / "This account is no longer tracked in your net worth." instead
  of Flutter's stale name over empty cards; the edit and delete buttons
  hide.
- Worth account history: the timeline trash buttons and the bar's edit and
  delete buttons carry VoiceOver labels ("Delete this balance update" /
  "Keep at least one balance update", "Edit balance", "Delete account"),
  each row reads as one element with a Delete action, and the hero, stat
  cards and chart have summaries ("Balance trend, 3 balance updates from
  ... to ..."). Flutter has only the two tooltips.
- Worth account history: SF Symbols stand in for Material's `north_east`
  (`arrow.up.right`), `south_west` (`arrow.down.left`), `calendar_month`
  (`calendar`), `edit_rounded` (`pencil`) and `delete_rounded`
  (`trash.fill`, `trash` in the bar). The snapshot chip's fill uses the
  hairline token (white 5.9% / ink 6.3%) for Flutter's white 6% / black 5%.

- Settings is pushed from the Home gear (D2): the system navigation bar
  (back button and swipe) carries the "Settings" title (26/800) at the
  leading edge; there is no floating-dock bottom padding.
- The `appSettings` section keeps unknown keys and the stored key order
  when Swift rewrites it (Dart's `_persistAtomic` writes only its five keys,
  in its own order, dropping anything else).
- The Home Screen widgets honour Hide balances (D12): the app writes
  `budgieHideBalances` (Bool) to the App Group at launch, with every cash
  flow sync and on every Hide balances change, and the widget shows
  "••••" in a neutral colour instead of the cash flow. Flutter's widget
  never masks; it reads only `cashFlow` / `cashFlowMonth`, which Swift
  still writes, so a downgrade just shows the amount again.
- Settings setters (currency, number format, app lock, lock delay, hide
  balances) change memory, then the preference mirror, then the
  `appSettings` section, awaited, and return the verified result, with
  Flutter's guards (Fixtures/settings/setters.json). The page updates as
  soon as memory changes (Flutter after the write), and every screen
  re-formats at once (Flutter's other tabs only on their next rebuild). A
  failed write keeps the change in memory behind the unsaved banner, with
  no toast (Flutter's setter throws, skips its formatter sync and notify,
  and the change reverts on relaunch because the stale section beats the
  newer preference).
- App lock: turning the switch on asks for Face ID / the passcode first
  ("Turn on App Lock") and keeps the open session unlocked (the switch
  stays on while the prompt is up, and the privacy cover is held back until
  the scene is active again); a device
  without a passcode gets "Set a passcode in the Settings app to use App
  Lock." (Flutter locks the session at once and shows its lock screen).
  The relock clock starts only when the app goes to the background, not on
  `inactive`, so the enable prompt and Control Centre do not relock with a
  0-second delay (Flutter counts any inactive blip).
- Settings choice sheets (Base currency, Number format, Lock delay) use the
  redesign sheet chrome (44x4 handle, card border) instead of the plain
  Material sheet (32x4 handle in a 48pt strip); content-sized up to 75% of
  the screen as in Flutter. Picking a row awaits the setter, then closes
  the sheet (Flutter closes first). The current row has the selected trait.
- Settings switches (App lock, Hide balances) are systemGreen like
  Flutter's Cupertino switch (the app-wide accent tint is overridden);
  VoiceOver reads each switch by its title with the subtitle as the hint.
  Tappable rows read "title, subtitle" once (label and value; Flutter
  merges its button label with the child texts), and the section eyebrows
  are headers.
- Settings > ABOUT also lists Data diagnostics and Licences (the SIL OFL
  texts the bundled fonts require), and Design gallery in debug builds;
  Flutter has only Version. The version is read from the bundle at once
  (Flutter shows "Budgie 2.0.0" for a frame while PackageInfo loads).
- Export as CSV shows "Transactions exported successfully!" only when the
  share sheet completed (Flutter shows it after any dismissal, a cancel
  included); the spinner shows while the file is built (off the main
  thread) and while the share sheet is open, as in Flutter. The sheet is
  the system's compact one presented from the topmost controller, as
  share_plus does, with Flutter's subject ("Budget Transactions Export",
  the Mail subject and the header's title) and share_plus's header
  subtitle ("CSV • 6 KB"). Both exports' temporary files are written with
  complete file protection (unreadable while the device is locked; the
  store is `completeUntilFirstUserAuthentication` because the app reads it
  in the background, which an export never needs) and deleted once the
  sheet reports back, or at once when the page was left before the file
  was ready (Flutter leaves them in `tmp`). Leftovers (a kill while the
  sheet was open) are swept at launch, when the app goes to the
  background (except the file an open sheet is using) and before each
  export.
- Settings row subtitles get a second line at accessibility text sizes
  (Flutter's `_SettingsRow` clips them to one, so at AX sizes only the
  first word or two showed). The running data row's spinner is the
  accent colour (Flutter: a ring in the text colour).
- The Theme pills slide one accent capsule between segments (the shared
  `SegmentedPills`); Flutter fades each segment's fill in place.
- Settings SF Symbols stand in for Material Symbols: `square.on.circle`
  (category), `sparkles`, `banknote` (payments), `globe` (language),
  `lock`, `timer`, `eye.slash`, `repeat`, `arrow.down.to.line`
  (file_download), `arrow.up.to.line` (file_upload), `icloud.and.arrow.up`
  (backup), `arrow.counterclockwise.circle` (settings_backup_restore),
  `info.circle`, `moon` (dark_mode), `chevron.right`.
- Insights preferences of the wrong type (`local_insights_dismissed_v1`
  not a string list, or holding a non-string; `local_insights_snoozed_v1`
  not a string) read as absent (D6). Flutter's `getStringList`/`getString`
  throw an uncaught `TypeError` there and the Insights section never
  appears until the preference is fixed. The next dismiss or snooze
  replaces the bad value with a valid one. Nothing in either app writes
  such values.
- Insights on hand-edited data whose percentage is NaN or infinite (a
  "NaN" goal amount, amounts that overflow to Infinity): Dart's `round()`
  throws inside `generate` and the section is replaced by an error widget;
  Swift shows no Insights section. Finite overflows print the saturated
  value (`9223372036854775807%`) in both.
- Insights preferences edited by hand: an id holding a lone UTF-16
  surrogate becomes U+FFFD in Swift, and snoozed JSON nested more than 128
  levels deep reads as no snoozes (Dart keeps the entries before the nested
  value). Every id the engine produces is ASCII.
- Insights UI: the "Insight options" button is an iOS `Menu` (Flutter's
  Material popup), and the unusual-expense icon is `bell.badge.fill` for
  Material `notification_important` (UI_SPEC "Flow: Insights"). The cards
  are computed off the main thread: a dismissed or snoozed card goes at
  once, and the next candidate appears when the recomputation lands (a
  frame or two; Flutter swaps it in the same frame). The preferences are
  read once at launch, so the section is not rebuilt (and does not pop in
  a frame late) on each visit to Flow as Flutter's is; Flow still
  refreshes when it appears and when the app becomes active, so a snooze
  that ended while away shows again (a refresh whose inputs, the calendar
  day included, are unchanged computes nothing: the engine reads the clock
  only through the day and the snoozes). At accessibility text sizes the
  card stacks its tile above the text (Flutter keeps the row and its text
  column narrows).

- (Approved 2026-10-01.) A category name with leading or trailing spaces (a transaction's,
  template's or budget key's; the typical fixture has "  Padded Cat ") no
  longer adds a definition at every launch. Flutter's `_containsName`
  (category_provider.dart:226) trims the candidate but not the stored
  names, and `ensureLegacyCategoryNames` stores the name untrimmed (:93,
  :98), so the definition it made never matches again: the debug build
  went from 19 to 20 categories on the first launch and 29 after nine
  restarts, each a new `type-<uuid>` row. Swift's first launch adds the
  same one definition as Flutter's (same bytes, so the launch fixtures
  still match); on later launches a definition stored before the launch
  matches by its trimmed name and nothing is added. Inside one launch
  Flutter's rule stands (two rows with the same padded name add two
  definitions, once). Invisible to Dart beyond the missing duplicates:
  the section is the same shape, and the Flutter build run after Swift
  still adds its own duplicate (its bug). The parity tests load Flutter-
  written stores with `matchesPaddedCategoryNames: false`, which is
  Flutter's rule exactly, because a store that already holds the padded
  definition (large_10k) is, for Flutter, a launch that adds another;
  CategoryRelaunchTests holds the fix.

- (Approved 2026-10-01.) Dialog scrims (every `budgieDialog`) ignore taps while the keyboard is
  showing, hiding or changing height (between UIKit's will- and
  did-change-frame notifications): the keyboard moves the card then, so a
  tap on the scrim was aimed at where the card just was, typically its
  buttons (Flutter's barrier dismisses on any tap).

- (Approved 2026-10-02.) **Transaction form, keyboard up (visual QA R5, budgie-uia.48).** With the
  software keyboard showing, the form scrolls once so the whole Category
  wheel box is in view (Flutter's dialog is shorter and shows it without
  scrolling; Swift's sheet also holds the grab handle and the Expense/Income
  toggle, D5). The title then sits just under the grab handle until the user
  scrolls back. Not done at accessibility text sizes, where the area is too
  short to show the wheel without scrolling the focused Amount field away.

- (Approved 2026-10-02.) **Spend rows and drill-in rows, amounts wider than the row (R1).** An
  amount too wide for its row is cut off with an ellipsis and the category
  name keeps at least about 56pt. Flutter lets such an amount run off the
  screen (and in the Spend list pushes the whole page sideways); only
  absurd amounts reach this (the September stress data).

### CSV import

The parser (csv 6.0.0 with the app's settings), `utf8.decode`, header and
row validation with their messages, the multiset dedupe and the page's
copy are Flutter's (Fixtures/csvimport: the real parser on random input,
the real `parseTransactionsCsv` and `importTransactions` in five zones, the
real Settings page for the copy). Differences (D6; Dart cannot see them):

- The failure toast shows the bare message, "Could not import: Not a
  valid transactions CSV export" (Flutter prints `e.toString()`: "Could
  not import: FormatException: Not a valid transactions CSV export").
- Singular forms when a count is 1: "Import 1 transaction?", "1 duplicate
  will be skipped", "1 row could not be read", "Imported 1 transaction, 1
  duplicate skipped", "No new transactions: 1 duplicate skipped, 1 row
  could not be read", "No transactions imported: 1 row could not be read".
  Flutter always uses the plural.
- The success toast shows only after the verified write; a failed write
  gets the save-failed toast (Flutter ignores the write result and shows
  success; its retry banner appears).
- A picked file whose bytes cannot be read shows "Could not import: The
  file could not be read" (Flutter returns silently, like a cancel).
  Cancel stays silent.
- A picked file over 50 MB is refused before it is read: "Could not
  import: The file is larger than 50 MB" (and "Could not import backup:
  ..." for a backup). Flutter reads any size; a large file picked by
  mistake could run the app out of memory during the preview. Real
  exports are far smaller (10,000 transactions are about 1 MB). The file
  is memory-mapped and the decoded text is not kept during the parse.
- Imported rows get `createdAt` = `updatedAt` = the import time plus one
  microsecond per row, in file order, so the last file row sorts first on
  its day. Flutter calls `DateTime.now()` per valid row while parsing
  (before the confirm dialog, deduplicated rows included); equal values
  are possible, and then the random ids decide the same-day order.
- Category names the imported rows bring without a definition get one in
  the same commit (`transactions` and `categories` together), exactly as
  Flutter's next launch defines them (slug or `type-<uuid>` id, end of the
  type, icon grid, accent); the stores are then equal. Only the imported
  rows' names are materialised, as Flutter's next launch would (a padded
  one is added by Flutter's launch pass again; Swift's finds the one made
  here, see the padded-name entry above).
- Rows already stored are kept byte for byte. Flutter rewrites the whole
  `transactions` section in `toJson` form, which differs only for rows
  another writer produced, e.g. a local time that does not exist in the
  current zone (typical's New York midnight read in Santiago), which
  Flutter writes back as the resolved time. Unreadable rows: see above.

- The confirmation is the redesign's centred card (Cancel and an accent
  "Import" pill; Flutter: a Material AlertDialog with text buttons); the
  import is awaited with the card modal and inert, Cancel dimmed and a
  spinner in the Import pill, which VoiceOver reads and announces as
  "Importing". The rows and the sections to write are built off the main
  thread and written as built, in one commit, as a background task (so
  leaving the app does not stop it part way). The data rows stay disabled from
  the tap until the message (Flutter's `_isImporting`), VoiceOver reading
  "Importing" for the row. The picked file is read in place (Flutter's
  picker copies it into the app cache and leaves it there).
- The neutral messages ("All transactions in this file already exist",
  "No transactions found in this file") use the neutral toast, Flutter's
  default SnackBar look.

Flutter behaviour kept on purpose (D6 candidates; fixing them would change
what gets stored):
- Amounts are en-US with one optional leading `$`: `1.234,56`, `€5`,
  `$ 1,000` and `1,23` are row errors (a file has no locale, the exporter
  writes `1234.50`, and Flutter rejects decimal commas on purpose).
- Negative amounts are rejected ("invalid amount"), although the export
  writes them (`-12.50`), so they do not survive an export and re-import.
  `-0` is accepted and stored as `-0.0`.
- A `Z` or `±hh:mm` date is stored as a UTC value (with `Z`) and filed
  under its UTC day; the written day must be that UTC day
  (`2026-02-15T23:30-08:00` is a row error). Date-only cells are local
  midnight (the resolved time in a DST gap).
- Category names are not matched to definitions or case-normalised
  (`groceries` is stored as written; it shares the `Groceries` definition).
- The confirm dialog shows counts only; the `Row N: ...` messages exist
  (`Summary.rowErrors`) but are not shown.
- Identical rows within one file are all imported. The dedupe
  key joins its parts with an unescaped `|` (category `c|a` + description
  `b` matches `c` + `a|b`) and compares UTF-16 code units (NFC and NFD
  spellings differ). A stored name with a lone surrogate exports as
  U+FFFD, so re-importing that export adds a copy of the row.
- Row numbers count CSV records (the header is Row 1, blank records
  included). A quote after a closing quote keeps the field quoted, so the
  rest of the line and following lines join that field until the next
  quote. A bare CR is never a line break (a CR-only file is one row and
  fails the header check).

### Backup export and restore (D10)

The file format is Flutter's: a Swift export equals Flutter's export of the
same store byte for byte, and each app restores the other's files
(Fixtures/backup; `verify_swift_output_test.dart` restores Swift exports
through Flutter's own restore chain). Only two backup schemas ever
existed, 1 (six `data` keys, July 2026) and 3; there is no "v2".

- Restore is one store commit of all ten sections (Flutter makes about
  nine, with no rollback). The app swaps memory only after the verified
  commit; on failure nothing changes and nothing is flagged unsaved
  (Flutter can leave a partial restore and still say "Backup restored").
- A safety copy of the store files and preferences is written to
  `Application Support/pre-restore/s<sequence>-<stamp>/` first, on the
  store actor right before the commit (no other write can land between
  them, so the copy is exactly what the commit replaces), and the restore
  does not run if it cannot be made. The newest three are kept, pruned
  only after a successful restore; "newest" is the creation sequence in
  the folder name, not the clock, and the copy the restore just made is
  never pruned (a device clock set back cannot remove it). Flutter has
  none (its `.backup.json` ends up holding a mid-restore generation). The
  copy also keeps any stored rows neither app can read, which the restore
  replaces (as Flutter).
- Changes that are only in memory (a failed save, the unsaved banner) are
  retried before a restore; if some still cannot be saved, the restore is
  refused with "Could not import backup: Some changes are not saved yet.
  Tap Retry at the top of the screen, then import the backup again." and
  nothing is copied, written or replaced. The safety copy is taken from
  disk, so an unsaved change would otherwise be in neither the restored
  data nor the copy. Flutter restores over them.
- The restore runs as a background task, so leaving the app does not stop
  it between the commit and the preference mirrors and theme. A "Match
  device" locale in the file removes the `flutter.locale_override` mirror
  just before the commit (Flutter writes all its mirrors before its
  commit): both apps fall back to that mirror when the stored
  `localeOverride` is null, so a kill after the commit could otherwise
  bring the old locale back. The other mirrors follow the commit (their
  stored values are never null, so the mirrors are only fallbacks); a
  failed commit puts the locale mirror back. Remaining window: a kill in
  the instant between the verified commit and the mirror writes (the same
  main-actor turn) leaves the theme and the fallback mirrors stale; the
  data itself is restored.
- A `data` key that is absent or null leaves its section or setting
  unchanged: schema-1 files keep categories, tags, rules and the five
  settings (and their preferences). Flutter resets them to the built-ins,
  none, USD, Match device, lock off, 60 s and hide off, and empties any
  list a hand-edited file leaves out. `localeOverride` is the exception:
  present and null means Match device. `{"schemaVersion":3,"data":{}}` is
  accepted as in Flutter, and so changes nothing but the recurring
  generator and legacy categories.
- The confirmation keeps Flutter's copy verbatim (no pluralisation; counts
  are the decoded sizes, budgets <= 0 and duplicate-id rows included, 0 for
  a key the file leaves out) and, when the file leaves something unchanged,
  adds "Your categories, tags, rules and settings are kept." naming what is
  actually kept.
- The recurring generator runs on the restored data before the commit, so
  its rows and cursors are in the same commit (Flutter runs it after the
  restore, one commit per row). The launch pass that materialises legacy
  categories also runs in the restore (Flutter runs it at the next launch).
  The end state equals Flutter's after its next launch.
- Two files Flutter fails on without a `FormatException` are reported as
  "This backup file is corrupt or incomplete.": `autoLockTimeoutSeconds`
  of `1e999` (Flutter: "Unsupported operation: Infinity or NaN toInt") and
  a rule `minimumAmount`/`maximumAmount` of `±1e999` (Flutter shows the
  dialog, then fails its first write with "Converting object to an
  encodable object failed: Infinity"). Nothing changes in either app.
- JSON nested more than 128 levels deep is "not a valid Budgie backup
  file" (the parser's recursion cap); Flutter accepts such a file when the
  deep part is under a key it ignores.
- `appSettings` keeps unknown keys (the section is patched); Flutter
  writes a fresh five-key object.
- Settings rows: the four data rows are disabled from the tap until the
  result message (through the share sheet, the picker and the dialog), the
  running one with a spinner, as Flutter's `_dataBusy`; VoiceOver reads
  "Exporting" or "Restoring" for it. "Backup exported" shows only when a
  share activity completed (Flutter: after any dismissal, a cancel
  included), in the system's compact share sheet with "Budgie Backup" as
  the Mail subject and the header's title and share_plus's "JSON • 70 KB"
  subtitle; the temporary file is handled as the CSV export's (complete
  file protection, deleted once the sheet reports back, swept at launch
  and in the background; Flutter leaves it in `tmp`). The picked
  file is read in place (Flutter copies it into `tmp` and leaves it); a
  file that cannot be read shows "Could not import backup: The file could
  not be read" (Flutter returns silently, like a cancel).
- The confirmation is the redesign's centred card (Cancel and a danger
  "Replace" pill; Flutter: a Material AlertDialog with text buttons). The
  restore is awaited with the card modal and inert (Cancel dimmed, a
  spinner in the Replace pill, read and announced as "Restoring") and the
  rows disabled. Nothing can edit the data while it runs: quick actions,
  widget taps and `budgetapp://` links wait and open the add form once it
  ends (`canOpenRoutes`), and retries wait. A save that reached the store
  layer anyway would be flagged unsaved (banner, Retry), never dropped,
  and the restore would then stop before its commit with "Your data
  changed while the backup was being restored. Nothing was replaced; try
  again.", keeping that change.
  A backup that turns App Lock on locks the session at once (Flutter's
  false -> true; the session is never marked unlocked by a restore).
- Export: `exportedAt` and the file name come from one clock read (Flutter
  reads the clock twice). Rows the Swift store keeps but cannot read are
  left out, as Flutter, which cannot load them either.
- `selectedNetWorthMonth` is neither exported nor restored (as Flutter):
  the current one is kept even if it points outside the restored data.
- A lone UTF-16 surrogate in a category name that the launch pass creates
  (from a transaction, template or budget key) is written as U+FFFD
  (Swift strings cannot hold one); Flutter keeps it. Rows read from a
  store or a backup keep theirs.

Flutter behaviour kept on purpose (D6 candidates; fixing them would change
what Flutter reads or shows):
- The file's `app` and `appVersion` are never checked.
- Duplicate category names, blank names, unknown category `type` strings
  (read as expense) and rules naming a missing category are accepted;
  orphan `tagIds` on transactions are kept.
- `autoLockTimeoutSeconds` has no upper bound (1e30 becomes the largest
  int, which never locks).
- Goals without dates get the restore time (`DateTime.now()` at decode);
  goals and tags without ids get fresh ones.
- Restoring theme `system` over `system` writes no preference.
- A setting equal to its current value is still mirrored to its preference.


- A sheet open when the app goes to the background (e.g. the transaction
  form) is not covered by the App Lock privacy cover.
- No iPad layout (the Flutter app is iPhone-only too).

### Voice entry (Phase 4; owner brief 2026-09-30)

- The category vocabulary offered to the model, and the names its answer
  is checked against, are `model.categories(for:)` (the active categories
  of each type, custom and renamed included, archived left out). Flutter
  offers its built-in names only. So Swift can return a custom category
  Flutter never would; a category outside the list still becomes
  "General" (expense) / "Other" (income), as in Flutter, even when that
  fallback is not itself in the list.
- A draft category that is not in the picker (an archived or renamed
  "General" / "Other") is kept as an extra wheel row in the prefilled form
  and saved, as Flutter keeps and saves it. Switching the form's type and
  back restores the draft's category (Flutter's form has no type toggle;
  Swift's keeps it for the prefilled form too, so a wrong income/expense
  guess can be fixed).
- The prefilled form is a sheet that replaces the recording sheet's
  content in place (one presentation, so the host survives the swap);
  Flutter closes the recording sheet, then opens the form as a dialog.
  Like the dialog it cannot be dismissed by swiping or tapping outside;
  Cancel and Add close it.
- A draft amount of `-0.0` (or zero) shows an empty Amount field and Add
  says "Amount is required", as Flutter.
- Not configured: the sheet says "Add OPENAI_API_KEY to
  native/Config/Secrets.xcconfig" (Flutter: its `.env` copy). Only Debug
  builds can reach it; Release builds fail to build without a key.
- The system prompt, models, retry choices (401, 403, 429 and every other
  failure read "Something went wrong. Try again.") and the microphone
  message match Flutter. Only one voice flow can be up at a time in both.
- Recording sheet details: the mic is `mic.fill` (Flutter's outlined
  `mic_rounded`) and the error icon `exclamationmark.circle`; the error
  haptic is `.sensoryFeedback(.error)` (Flutter's system vibrate); the drag
  handle uses the shared sheet chrome's 0.6 alpha (Flutter's voice sheet
  0.35); the 56pt spinner is a custom arc (no Material spinner), turning
  slowly under Reduce Motion; pills have a 44pt minimum height so large
  Dynamic Type can grow them. The audio session is `.record` with haptics
  allowed while recording (Flutter's plugin uses `playAndRecord`).
- The recording sheet uses the system detent, as the other native sheets
  do. On iOS 26+ that floats it: inset 8pt from the sides and bottom, all
  four corners rounded, its content at 0.96 scale (mic 84.5pt not 88, Stop
  pill 42pt not 44), and the system dims what is behind by about 20%
  (Flutter's barrier is about 54%). The drag handle sits about 15pt higher
  than Flutter's, from the shared sheet chrome. The mic-denied message
  wraps as "...Enable it in Settings / > Budgie." (Flutter breaks after
  "in"); the copy is unchanged and the wrap is accepted.
- Going to the background while listening stops the recording and goes on
  to transcribe it, as Flutter does; the app may be suspended before the
  request finishes, in which case the sheet is at "Something went wrong.
  Try again." when the user returns and Try again re-sends the kept file.
  An audio interruption (a phone call, Siri) while listening is treated
  the same way; Flutter has no handling for it and keeps counting over the
  paused recorder.
- A recorder that fails to start shows "Something went wrong. Try again."
  and Try again records again (Flutter leaves the sheet listening with no
  timer). Stop pressed while the recorder is still starting stops it and
  deletes the file.

### Colour tokens meet WCAG AA (owner-approved 2026-09-30)

The owner approved on 2026-09-30 that these colour tokens differ from
Flutter so that text and the labels on filled controls reach WCAG AA
(4.5:1). Flutter's values fell short: textTertiary 2.3-2.9:1 in both modes,
light income 2.5:1, danger 3.8:1 and warning 2.2:1 as text, white on the
income and danger fills 2.5 and 3.8:1, the filled accent button 4.47:1, the
button gradients' lighter stops down to 1.9:1. Each value is the nearest one
with the same hue (only the lightness changed, in OKLCH) that passes against
every surface it sits on (page, card, chip surface, and its own 10-14% tint
for text; white for fills). Dark income, danger, warning and accent already
passed and are unchanged; so are the chart and category palettes
(`BudgieColor.chartPalette`, and the Spend rank palette through
`chartAccent` / `chartIncome` / `chartDanger` / `chartWarning`, which keep
Flutter's values), the wash and glow behind the Worth account hero and
editor banner, and the fixed `incomeFixed` / `expenseFixed` wheel tiles.
The home screen widget's two white-labelled buttons and its mic circle were
darkened the same way (the widget has its own palette, not these tokens).
Two helpers keep category colours readable as text: `textSecondaryOnTint`
(`#5A6170` light) on strongly tinted cards, and `BudgieColor.legible`,
which mixes a pale chart colour towards the primary text colour until it
reaches 4.5:1 on its own tint (the Spend drill-in chips).
`BudgieAppTests/ColorContrastTests` asserts every pair below.

| Token | Mode | Flutter / old | New | Pair | Ratio before | Ratio after |
|---|---|---|---|---|---|---|
| textSecondary | light | 6B7280 | 626977 | text on card | 4.83 | 5.52 |
| textSecondary | light | 6B7280 | 626977 | text on chip | 4.30 | 4.90 |
| textTertiary | light | 9CA3AF | 686F7A | text on card | 2.54 | 5.07 |
| textTertiary | light | 9CA3AF | 686F7A | text on chip | 2.26 | 4.50 |
| textTertiary | dark | 5C5C78 | 81829F | text on card | 2.86 | 4.93 |
| textTertiary | dark | 5C5C78 | 81829F | text on chip | 2.81 | 4.86 |
| dockInactiveIcon | light | 6B7280 | 636A78 | text on track | 4.00 | 4.50 |
| accent | light | 6366F1 | 5453DD | text on card | 4.47 | 5.74 |
| accent | light | 6366F1 | 5453DD | text on chip | 3.97 | 5.10 |
| accent | light | 6366F1 | 5453DD | white on fill | 4.47 | 5.74 |
| income | light | 10B981 | 07744F | text on card | 2.54 | 5.80 |
| income | light | 10B981 | 07744F | text on chip | 2.25 | 5.16 |
| income | light | 10B981 | 07744F | white on fill | 2.54 | 5.80 |
| danger | light | EF4444 | C60D21 | text on card | 3.76 | 6.03 |
| danger | light | EF4444 | C60D21 | text on chip | 3.34 | 5.36 |
| danger | light | EF4444 | C60D21 | white on fill | 3.76 | 6.03 |
| warning | light | F59E0B | 8F5B05 | text on card | 2.15 | 5.73 |
| warning | light | F59E0B | 8F5B05 | text on chip | 1.91 | 5.09 |
| primary | both | 6366F1 | 5453DD | white on fill | 4.47 | 5.74 |
| primaryGradient stop 1 | light | 6366F1 | 5F61EC | white on fill | 4.47 | 4.76 |
| primaryGradient stop 2 | light | 8B5CF6 | 8757F1 | white on fill | 4.23 | 4.50 |
| incomeGradient stop 1 | light | 10B981 | 006E4B | white on fill | 2.54 | 6.30 |
| incomeGradient stop 2 | light | 34D399 | 05875E | white on fill | 1.92 | 4.53 |
| incomeGradient stop 1 | dark | 059669 | 056647 | white on fill | 3.77 | 7.00 |
| incomeGradient stop 2 | dark | 10B981 | 04875D | white on fill | 2.54 | 4.54 |
| expenseGradient stop 1 | light | EF4444 | C2021D | white on fill | 3.76 | 6.32 |
| expenseGradient stop 2 | light | F87171 | CC4A4D | white on fill | 2.77 | 4.51 |
| expenseGradient stop 1 | dark | DC2626 | CC0716 | white on fill | 4.83 | 5.82 |
| expenseGradient stop 2 | dark | EF4444 | DF3337 | white on fill | 3.76 | 4.50 |

Ratios are WCAG 2 contrast; "text on chip" is the chip surface `#F1F1F7` /
`#15151F`. Not every token pair is listed (see `ColorContrastTests` for the
complete set, including each colour on its own tint).

### Visual redesign (owner-approved 2026-10-03)

The owner approved a new look for the whole app on 2026-10-03, designed on
the canvas https://claude.ai/artifact/9v74CfEWe7LQAy5oenMvij. It changes
only presentation: data, calculations and copy still match Flutter, except
the copy changes listed here.

- **Palette.** Every colour token changed (see UI_SPEC's table): "Paper" in
  light mode (warm paper, ink, deep green, terracotta), "Midnight" in dark
  mode (near-black, mint, coral, lilac). The values in "Colour tokens meet
  WCAG AA" above are superseded; the AA rule still holds and
  `ColorContrastTests` checks the new values. The chart and Spend rank
  palettes are new too (`SpendPaletteTests`), in Flutter's slot order.
- **No glows.** Glows, text glows, halos, the hero blur and the glow
  underlay on chart lines are gone; cards are flat with a 1pt border and a
  22pt radius. The add button keeps a soft drop shadow.
- **Home.** The hero is a ring of the month's income split into spent and
  kept, with the cash flow in whole units in the middle (still never a sign;
  danger when negative), "34% kept" / "Short this month" / "Breaking even"
  under it, and a legend with the exact spent and kept amounts. Flutter's
  spend gauge and the "$X in · $Y out" subline are gone. The income and
  expense tiles add a six-month sparkline and colour the change by whether
  it is good (income up, expenses down) instead of by type. Safe to spend is
  the feature card (ink block in light mode, mint tile in dark mode).
  Budgets are two-column ring tiles (one column at accessibility sizes) with
  the share used, and a dashed "Add a budget" button; the add row's
  subtitle is now its VoiceOver hint. Recent rows tint the icon with the
  category's colour. Home's Expense / Income pills are gone: the add
  button's form switches between expense and income, as it already did.
- **Shared.** Section links read "See all" / "Edit" in sentence case (were
  mono "SEE ALL" / "EDIT"); page titles are 30pt, section titles 21pt. Month
  chips (Worth and SEE ALL) are single-line capsules ("Sep 2026"), selected
  in the selection fill. The Assets / Liabilities toggle is a segmented
  track.
- **Worth.** The hero is centred; the change pill has no border; the split
  card puts its legend above a 12pt bar.
- **Goals.** The summary is the feature card. A goal card shows the name and
  status pill, "{saved} of {target}" with the percent, a 10pt bar in the
  status colour and the pace line (Flutter's 84pt ring is gone).
- **Spend.** The page title is "Spending" (Flutter: "Categories"), matching
  the tab.
- **Add / edit transaction form.** Laid out to fit above the decimal pad
  on an iPhone 17 Pro without scrolling: the title and the Expense / Income
  switch share a row; the amount is a 64pt field with "Amount" inside it
  and the figure right-aligned; then Description, then one-line rows for
  Category, Date and Tags ("Optional"). The category wheel is replaced by a
  Category row that opens a menu of the same categories, in the same order,
  with a checkmark on the selection. Tag chips show selection by fill and
  weight, without a checkmark. Shorter screens and large text scroll, with
  a fade cueing more below. The recurring form uses the same fields (its
  pattern and day wheels stay); the quick expense sheet tints each tile in
  its category's colour (Flutter: red).
- **Fields, rows and buttons.** Text fields sit on a field fill with a
  16pt radius and a 2pt accent border while focused. Date tiles are
  one-line rows (label column, value, trailing calendar). Outlined buttons
  have no tint: a 1.5pt card-coloured border around a label in the
  button's colour.
- **Sheets and dialogs.** Sheet titles are 24pt ExtraBold; sheets have a
  30pt radius and a slimmer grab handle. Every dialog has the same plain
  drop shadow over a palette scrim (Flutter: the Worth editor's coloured
  glow, black 54% elsewhere). The Safe to spend sheet shows its total in
  the feature card above the six breakdown rows (Flutter: a total row
  under them). The budget limit sheet leads with the category's tile and
  name; budget pickers tint each tile in its category's colour.
- **Empty states.** One pattern everywhere: a dashed card with a tinted
  72pt tile, the title, the message and, where there is one, a filled
  button (Flutter: a bare icon and text; Recurring's 120pt gradient
  circle).
- **SEE ALL.** Each day is one card of rows like Home's Recent activity:
  the category's tile (Flutter: a solid income / expense tile), and the
  amount signed and coloured like Recent activity (+ income in green,
  - expenses in the text colour; Flutter: unsigned, in the type's colour).
  The month wheel's selection band uses the chip colour.
- **Settings.** The brand card is the feature card (no wash). Rows have
  38pt tiles; switches use the income green (mint in dark mode). The theme
  row drops its subtitle "Light, dark, or match device"; the Tags & rules
  section links read "Add" (Flutter: "ADD"); Import from CSV and Import
  backup tiles are blue and red. Licences and Data diagnostics are card
  pages instead of grouped lists.
- **Onboarding, lock and launch.** Onboarding is left-aligned with the
  page's symbol in a feature-card block, a 40pt title and a full-width
  56pt button. The lock screen and privacy cover show the logo (Flutter:
  a lock glyph) on the page background and follow light / dark mode; so do
  the launch and opening screens (Flutter: always dark), and the opening
  screen has no accent washes or shadow.
- **Unsaved-changes banner.** A deeper red behind its white text in dark
  mode (the dark palette's red fails AA under white).
- **Voice sheet.** The error message is a 24pt title, with full-width
  Try again and Cancel stacked.
- **Goals and Worth dialogs.** Sheet titles and outlined Cancel buttons;
  the account editor's banner is a flat tint of the type colour (Flutter:
  a gradient and a coloured glow); its type and month choices sit on the
  field fill, the selected month in the selection colours. The goal
  celebration's scrim is the palette scrim (a little darker in dark mode).
- **Account history.** The hero card has no colour wash (a tinted tile
  instead); timeline rows show a calendar tile instead of a dot.
- **Spend.** The month sheet lists months as rows in a card. The category
  drill-in's summary card has no tint, and its rows sit in one card with
  hairlines (Flutter: separate cards); amounts stay unsigned, as every row
  there has the same type. Category rows indent their bars under the text.
- **Flow.** The month detail sheet puts the net on the feature card, with
  Income and Expenses as rows in a card under it (Flutter: coloured tiles
  with arrows; expenses are in the text colour). Flow SEE ALL and the
  preview card use the category's tile (Flutter: income green or accent;
  uncategorised rows keep Flutter's fallback); its search and filters sit
  on the field fill with selection-coloured tag chips, and an empty result
  is the dashed empty card with a title ("No Results Found" with filters,
  else "No Transactions Yet"; Flutter: the message alone). The range,
  category and month sheets keep their mono headings ("CHART RANGE",
  "SELECT CATEGORY", "SELECT MONTH") over rows in a card.
- **Home screen widgets.** Follow light / dark mode on the card colour
  (Flutter: a fixed dark gradient). Quick actions: the logo and the cash
  flow over two flat Income / Expense buttons; the voice widget has no
  cash flow. System fonts (the extension does not bundle the app's).

## Deliberate differences (not yet approved)

- **Chart scrub picks the nearest point anywhere in the plot (iPhone Duo, plan Phase 1).** The Worth
  growth chart and the account trend chart select the point nearest the finger in x, with no distance
  limit (each point owns the column out to halfway to its neighbours). Flutter's fl_chart only selects
  a point within `touchSpotThreshold` 48pt, which on the Duo's open display leaves gaps (Worth 1Y:
  67pt from each point, no tooltip). On a phone the result is the same wherever points are under
  48pt from any touch; with only a few points a touch between them now selects one instead of nothing.
- **Swipe-to-delete arms at most 163pt in (iPhone Duo, plan Phase 1).** Flutter's `Dismissible` arms at
  40% of the row width; here the distance is capped at 163pt (40% of the widest iPhone row), so a
  wide row on the Duo's open display needs the same swipe as a phone, not about 314pt. Phones are
  unchanged.

## Platform

- iOS's text layout appears to avoid ending a paragraph on a single word
  (Flutter fills each line first; the cause is inferred, there is no
  public switch to check it). The Flow insight headline
  "Eating Out has stayed under budget" therefore breaks as "...stayed /
  under budget" where Flutter breaks "...under / budget", though the
  column is as wide as Flutter's, and the 48pt menu reserve is not the
  cause (visual QA R6, budgie-uia.48).
- Minimum iOS 17 (Flutter: iOS 15). Users on iOS 15/16 stay on the last
  Flutter release.
- Quick action icons use SF Symbols (the Flutter build referenced asset
  names that did not exist, so its items had no icon): `minus.circle.fill`,
  `plus.circle.fill` and, for "Add by Voice", `mic.circle.fill`.
