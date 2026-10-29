> Archived; paths refer to the `flutter-final` tag.

# Analyst report: More tab (Settings) and everything reachable except Recurring

Paths: `F` = `W/budget_app/lib`, `S` = `W/native`. Line refs are Flutter unless prefixed `S:`.

## Headline findings

1. **Flutter Settings is not a native-looking list.** It is a scroll view of `GlowListCard` rows with mono eyebrows. All sub-pages (Categories, Tags & rules) and all dialogs use the older Material AppBar / AlertDialog look.
2. **The Swift MVP lacks about 80% of this area.** It has Theme, Currency, Face ID toggle, CSV export and Version. Everything else is missing (section 3).
3. **There are three real Flutter quirks to decide on.** These are Flutter bugs that Swift must either copy or consciously fix, and the fix is invisible to Dart:
   - The category-rename cascade renames rules by category name only, ignoring rule type.
   - Deleting a tag leaves orphan `tagIds` on transactions.
   - Restoring a schema-1 backup silently resets settings, categories, tags and rules.
4. **Swift Theme has one colour mismatch.** Flutter `purple` = `0xFF818CF8` in both modes (`category_settings_page.dart:402`, `AppColors.primaryLight`). `S:Budgie/Views/Theme.swift` uses 8B5CF6/A78BFA.
5. **Swift `CategoryInfo` drops `isBuiltIn`.** It is read-only and has no raw row. Writing categories needs both.
6. **Two Swift gaps in `AppModel` that block this area.**
   - `serialize(_:)` (`S:AppModel.swift:182`) falls back to `data.sections[section]` for unknown sections. `noteWritten` is never called, so new sections such as categories, tags, rules and budget limits would persist stale JSON on retry.
   - `TransactionRecord.Edit` and `AppModel.addTransaction` have no `tagIds`.

---

## 1. Feature inventory

### 1.1 Settings root (`settings_page.dart:579-911`)

Order and copy, top to bottom. `Sym` is the Material Symbols icon.

| Block | Row | Icon and tint | Subtitle | Action / control |
|---|---|---|---|---|
| Header | `BudgieHeader(title:'Settings')` | — | — | — |
| Brand card | "Budgie" / "Make every dollar count" | `assets/budgie_mark.png` 52x52, radius 16, glow | — | Non-interactive (1064-1131) |
| APPEARANCE | Theme | dark_mode, accent | "Light, dark, or match device" | Segmented pill `Light \| Dark \| Auto` (order Light, Dark, Auto). Semantics label "Theme mode". |
| PERSONALIZATION | Categories | category, accent | `"{n active} active · custom names, icons, and order"` (n = non-archived) | Push `CategorySettingsPage` |
| | Tags & rules | auto_awesome, info(blue) | `"{tags} tags · {rules} rules"` | Push `CategorizationSettingsPage` |
| | Currency | payments, income(green) | `"{Name} ({CODE})"`, e.g. "US Dollar (USD)"; unknown code renders "ZZZ (ZZZ)" | Choice sheet "Base currency" |
| | Number format | language, info | "Match device" or the locale label | Choice sheet "Number format" |
| PRIVACY | App lock | lock, accent | on: `"Lock after {label}"` (so "Lock after Immediately"); off: "Require device authentication" | Switch |
| | Lock delay (only if lock on) | timer, info | label | Choice sheet "Lock delay" |
| | Hide balances | visibility_off, warning | "Mask amounts throughout the app" | Switch |
| DATA | Recurring transactions | (excluded from this report) | | |
| | Export as CSV | file_download, income, bg income@12% | `"All {n} transactions"` | Share sheet |
| | Import from CSV | file_upload, accent, bg accent@12% | "Add transactions from a file" | File picker |
| | Export backup | backup, income | "Everything, as a JSON file" | Share sheet |
| | Import backup | settings_backup_restore, accent | "Restore everything (replaces current data)" | File picker |
| ABOUT | Version | info, `dockInactiveIcon` `8A8AA8`, bg white/black @6% | `"Budgie {CFBundleShortVersionString}"` (fallback "2.0.0", no build number) | none |

Choice sheets (985-1035) use `showModalBottomSheet` with these settings:
- Root navigator, drag handle, scroll-controlled, max height 75%.
- Title uses headingMedium (22/600), padded 16.
- Each row is a `ListTile` with a trailing accent checkmark on the current value.
- Tapping a row pops with the value.

Choice lists:
- **Currencies** (1038-1050), in order: USD US Dollar, CAD Canadian Dollar, EUR Euro, GBP British Pound, AUD Australian Dollar, JPY Japanese Yen, CNY Chinese Yuan, INR Indian Rupee, KRW South Korean Won, MXN Mexican Peso, BRL Brazilian Real.
- **Locales** (1052-1061), preceded by "Match device" (value `device`, stored as null):
  - en_US English (United States)
  - en_CA English (Canada)
  - en_GB English (United Kingdom)
  - en_AU English (Australia)
  - de_DE German (Germany)
  - fr_FR French (France)
  - es_ES Spanish (Spain)
  - ja_JP Japanese (Japan)
- **Lock delay** (963-983): 0 "Immediately", 30 "30 seconds", 60 "1 minute", 300 "5 minutes", 900 "15 minutes".
- **Label function** (925): 0 gives "Immediately", under 60 gives "{s} seconds", otherwise "{s~/60} minute(s)". The plural is applied only when the value is not 60.

Semantics: every tappable row is `button: true` with label `"{title}, {subtitle}"`. Taps fire a light haptic (`MicroInteractions.lightImpact`).

Busy states:
- Four data flags: `_isExporting`, `_isImporting`, `_isBackingUp`, `_isRestoring`.
- `_dataBusy` is true when any one is set. It disables all four data rows (`onTap: null`).
- The active row's chevron is replaced by a 20px spinner.

### 1.2 Persistence side effects per control

| Control | Preference key (`flutter.` prefix) | Store section `appSettings` | Source |
|---|---|---|---|
| Theme | `themeMode` = `light\|dark\|system` | none | `theme_provider.dart:42-64` |
| Currency | `base_currency_code` (String) | full 5-key object rewritten | `app_settings_provider.dart:58-67` |
| Locale | `locale_override` set, or **removed** when Match device | full object; `localeOverride` becomes null | 69-82 |
| App lock | `app_lock_enabled` (Bool) | full object | 84-91 |
| Lock delay | `auto_lock_timeout_seconds` (Int) | full object | 93-100 |
| Hide balances | `hide_balances` (Bool) | full object | 102-110 |

Details:
- The section object is written in this key order: `baseCurrencyCode, localeOverride, appLockEnabled, autoLockTimeoutSeconds, hideBalances` (158-168). Swift's `AppSettings.section(over:)` already does this and preserves unknown keys.
- Currency setter trims and uppercases the code, returns early if the length is not 3 or the value is unchanged (60).
- Load precedence per field is section first, then preference, then default: USD, null, false, 60, false (32-56). Swift matches this (`S:Records.swift:523`).
- Flutter setters have no failure handling. A failed store write is an unhandled exception. Swift's `persist()` and unsaved banner are strictly better.
- `MaterialApp(locale: appSettings.locale)` (`main.dart:60`) also localises Material widgets. This is minor. Consider `.environment(\.locale, …)` only if fidelity requires it. Money formatting uses the locale via the formatter, which Swift already ports.

### 1.3 Hide balances: where masking applies

- `MoneyFormatter.format` and `formatSigned` return `••••` (four U+2022, `money_formatter.dart:33,53`). This includes compact mode.
- All 13 files that use `MoneyFormatter` are masked automatically: spending, history, net worth, category, savings goals, recurring list, accessibility labels, donut chart, transaction list item, and others.
- **Not masked:**
  - `MoneyFormatter.formatNumber` (used in the budget-limit edit field, `spending_page.dart:838`).
  - Percentages (`toStringAsFixed(1)%`).
  - Text in edit fields (net worth `NumberFormat('#,##0.##')`, transaction form `toStringAsFixed(2)`).
  - CSV export and backup.
  - The iOS home-screen widget (reads App Group `cashFlow` directly).
- The spending hero swaps the odometer for plain dots when hidden (`spending_page.dart:1155`).
- **Swift already routes every amount through `model.moneyFormatter`** (`S:AppModel.swift:305`, all views grep-clean). Only the toggle is missing. The net worth chart already checks `formatter.hideBalances` (`S:NetWorthView.swift:140`).
- Open question: should the widget honour hide balances? Flutter does not, so this is a privacy gap to consider.

### 1.4 App lock (`widgets/app_privacy_gate.dart`)

Flutter behavior:
- **Launch:** if the lock is enabled, it locks and auto-attempts unlock (42-50).
- **Backgrounding:** on inactive, hidden, paused or detached it records `_backgroundedAt ??= now` and, when the lock is enabled, shows a privacy cover (59-72). Cover: `backgroundDark`, logo 72, "Budgie" (headingLarge), "App preview hidden".
- **Resume:** it locks if `enabled && elapsed.inSeconds >= timeout`. With timeout 0 this is always true (73-88).
- **Turning the switch on:** there is no authentication check. It immediately locks the current session and prompts (137-143).
- **Auth call:** `localizedReason: 'Unlock Budgie to view your financial data'`, `stickyAuth`, `biometricOnly: false` (106-113).
- **Lock screen:** background colour, lock icon 54 in accent, then:
  - Title "Budgie is locked".
  - Body "Authenticate to view your financial data." or the error text (in danger colour).
  - Primary "Unlock" button, or "Authenticating…" while busy, with a fingerprint icon.
  - "Disable App Lock" secondary button only when unsupported.
- **Error strings:**
  - "Authentication was not completed."
  - "Budgie could not authenticate on this device."
  - StateError: "Set up a device passcode or biometrics to use App Lock."

Swift `S:AppLock.swift` gaps:
- It authenticates before enabling and does not lock the open session. This is defensible; keep it and note it in PARITY_GAPS.
- Its cover has no "App preview hidden" copy.
- Its lock screen has no title or body copy and no "Disable" path. It lets the user in when there is no passcode, which is an approved divergence.
- It starts the timer only on `.background`, not `.inactive`.
- It uses reason "Unlock Budgie".
- Lock delay is already read from `appSettings.autoLockTimeoutSeconds`, so the picker only needs to write it.

### 1.5 Categories (`category_settings_page.dart`, `category_provider.dart`, `category_definition.dart`, `common.dart`)

**Data model** (`category_definition.dart`):
- Fields and JSON key order (42-51): `id, type('expense'|'income'), name, iconIdentifier, colorToken, sortOrder(int), isArchived, isBuiltIn`.
- `fromJson` defaults: icon `square_grid_2x2`, colour `accent`, sortOrder 0, isArchived false, isBuiltIn false.
- Built-in seeds (`category_provider.dart:293-339`): the Swift `CategoryCatalog.builtIn` is identical, but every seed row must carry `isBuiltIn: true`. Seed ids are `expense-{lowercased name with spaces to '-'}`. Both types have a "Gift" (`expense-gift`, `income-gift`).
- **Icon registry** (`common.dart:4-23`), 18 identifiers: square_grid_2x2, asterisk_circle, cart, house, car (car_detailed), airplane, bag, gift, heart, film, paw, people (person_2), money (money_dollar), chart (chart_bar), book, phone (device_phone_portrait), wrench (hammer), leaf (leaf_arrow_circlepath).
  - Swift's `CategoryCatalog.symbol` maps all 18.
  - Fidelity fix: `asterisk_circle` should map to SF `asterisk.circle`. Swift currently uses `fork.knife.circle`.
  - Consider `leaf.arrow.circlepath` for `leaf`.
- **Colour tokens** (`category_settings_page.dart:381-411`): accent, green, blue, orange, red, purple, pink, cyan.
  - green = `getIncome` (10B981 / 34D399).
  - blue = `getInfo` (3B82F6 / 60A5FA).
  - orange = `getWarning` (F59E0B / FBBF24).
  - red = `getDanger` (EF4444 / FB7185).
  - purple = **818CF8 in both modes**.
  - pink = F0ABFC.
  - cyan = 22D3EE.
  - accent = 6366F1 / 818CF8.
  - Unknown token falls back to accent.

**Page UI:**
- Material `Scaffold` with AppBar "Categories" and an actions "+" IconButton (tooltip "Add category"). A FAB "+" duplicates it.
- Below the AppBar, top to bottom:
  - Segmented pill `Expenses | Income` at spacing 16/8/16/0.
  - `SwitchListTile` "Show archived", padding 24 horizontal, off by default. Neither control's state is persisted.
- The list has one `GlowCard` (padding 8) per category, separated by 8, with bottom padding 32.
- Each row is a `ListTile`:
  - Leading `IconTile` (40, tinted 13%).
  - Title is the name, in rowTitle style.
  - Subtitle is `["Built in", "Archived"]` joined with " · " (an empty string when neither).
  - Trailing popup menu titled "Category actions".
- Menu items: "Edit"; "Move up" if not archived and index > 0; "Move down" if not archived and index < count-1 (index is the position in the displayed list); "Archive" or "Restore".
- Order is by `sortOrder` within the selected type. Archived rows are shown only when the toggle is on.
- **Editor** (`AlertDialog`, 183-332), title "New category" or "Edit category":
  - Text field "Name": autofocus, capitalize words, validator "Enter a category name" (trimmed empty).
  - "Icon" caption (13pt) above a Wrap of 18 44x44 buttons (spacing 8).
  - "Color" caption above 8 44x44 buttons containing 20px circle swatches.
  - Selected button: accent @18% fill and accent border. Unselected: surface fill and border colour.
  - Actions: Cancel and a filled "Add" or "Save". New type is the currently selected segment; type cannot be changed on edit.
  - Defaults: icon `square_grid_2x2`, colour `accent`.

**Provider semantics** (`category_provider.dart`):
- **Load** (32-51):
  - Decode the section (whole list falls back to seeds on any bad row or empty list). Normalise sort orders per type over ALL rows, archived included.
  - Call `_syncCompatibilityMaps` (rebuilds the global `expenseCategories` / `incomeCategories` maps used by pickers, active only).
  - Persist only if `jsonEncode` differs from stored, or the section was not a list.
- **Launch order** (`main.dart:258-286`): `categoryProvider.load()`, then `ensureLegacyCategories(transactions)`, then `ensureLegacyCategoryNames(recurring templates' categories plus categoryBudgetLimits keys typed expense)`.
  - `ensureLegacy` (71-112) adds a definition for each (type, name) not found (trimmed, case-insensitive): id via `_uniqueId`, icon `square_grid_2x2`, colour `accent`, sortOrder = count of that type (archived included), `isBuiltIn:false`. It then normalises and persists.
  - So Flutter materialises virtual categories at every launch; Swift's `pickerList` fakes them.
- **Add** (114-143):
  - Trim, and throw `ArgumentError` "Category name is required" if empty.
  - Throw "A category with this name already exists" if a same-type name matches case-insensitively (archived included).
  - Unknown icon becomes `square_grid_2x2`. New sortOrder is the count of that type including archived.
- **Update** (167-196): silent no-op if the id is unknown. Same two errors; the duplicate check excludes self (so a case-only rename is allowed), same type. Type and `isBuiltIn` unchanged.
- **Archive** (198-209): archiving the last active category of a type throws `StateError` "At least one category must remain active". Restore has no check. Archive never touches transactions, budgets, rules or templates.
- **Move** (211-224): the offset ±1 is applied within the full ordered list of that type (archived included), the result is clamped, and every sortOrder is renumbered 0..n-1.
  - Quirk: when archived rows are hidden, "Move up" can hop over an invisible archived row, so nothing appears to move. Fix this in Swift by moving relative to the visible list, or keep parity.
- **Unique id** (231-242): slug = trimmed, lowercased name with `[^a-z0-9]+` replaced by `-`, then leading/trailing `-` stripped. Candidate is `"{type}-{slug or 'category'}"`. If taken, the id becomes `"{type}-{uuid v4}"`. Non-ASCII drops out ("Café" gives "caf").
- **Error snackbar copy** (`_friendlyError`, 334-338): ArgumentError gives its message; StateError gives its message; anything else gives "Could not update this category".

**Cascade on rename** (`category_settings_page.dart:293-323`).

The order is: update the definition, then only if `newName.trim() != oldName`, run four rename passes, each with its own commit and no rollback:

1. **Transactions** (`transaction_model.dart` ~783-829):
   - Match `type == type && category == oldName` (exact, case-sensitive).
   - Set `category = new` and `updatedAt = DateTime.now()`. Nothing else changes.
   - Also syncs the widget.
2. **Budget limits** (expense type only):
   - `remove(old)`, then `putIfAbsent(new, oldLimit)` (appends at the END of the map).
   - If `new` already has a limit, the old limit is silently dropped.
3. **Recurring templates** (`recurring_transaction_model.dart:40-55`): `type == type && category == oldName` gets `copyWith(category: new)`.
4. **Rules** (`categorization_provider.dart:128-150`): any rule with `category == oldName` regardless of `transactionType`.
   - This is buggy: renaming income "Gift" also rewrites an expense-only "Gift" rule, and vice versa.
   - Recommendation: restrict to `rule.transactionType == nil || == type`.

Archive does no cascade at all. Swift must do all of the above in **one commit**: sections `categories, transactions, categoryBudgetLimits, recurringTransactions, categorizationRules` (Flutter uses up to 4 commits; a crash between them leaves a half-rename).

### 1.6 Tags and rules (`categorization_settings_page.dart`, `categorization_provider.dart`, `categorization_rule.dart`, `transaction_tag.dart`)

**Tag** JSON: `id (uuid v4), name (trimmed), colorToken ('accent')`. There is no UI for colour or rename.

**Tags & rules page** (plain AppBar "Tags & rules"; `ListView` padded 16):
- **Tags section:**
  - Header "Tags" (headingMedium) with an "ADD" `TextButton`.
  - Empty state `GlowCard`: "Add tags to group transactions across categories."
  - Otherwise a `GlowListCard` of `ListTile`s: label icon, name, trailing delete icon (tooltip "Delete {name}").
  - **Delete has no confirmation.**
- **New tag dialog:** title "New tag", hint "Travel planning", capitalize words, submit on Enter, buttons Cancel / Add.
  - Empty text is silently ignored.
  - Errors show as a snackbar with the ArgumentError message: "Tag name is required" or "A tag with this name already exists" (case-insensitive).
- **Merchant rules section:**
  - Header "Merchant rules" with "ADD".
  - Empty state: "Rules can automatically choose a category and tags from a merchant name."
  - Row title is `merchantPattern`. Subtitle is `"{matchType.name} · {category}"` plus `" · {n} tags"` when non-empty (e.g. "contains · Groceries · 2 tags"). Leading auto_awesome icon. Trailing delete icon "Delete rule", no confirm.
  - **No rule editing, no reorder, no enable toggle, no priority UI, no amount bounds UI.**
- **New merchant rule dialog** (128-260):
  - "Merchant text" (hint "Whole Foods", autofocus; the Add button silently does nothing if the trimmed text is empty).
  - "Type" dropdown (raw enum names expense, income; default expense).
  - "Match" dropdown (contains, startsWith, exact).
  - "Category" dropdown of active names for that type (`expenseCategories` / `incomeCategories`). Changing the type resets to the first.
  - `FilterChip`s for tags (only if tags exist).
  - Cancel / Add.

**Rule JSON** (`categorization_rule.dart:59-70`), key order: `id, merchantPattern, matchType, transactionType(null|'expense'|'income'), minimumAmount(null|double), maximumAmount, category, tagIds, priority(int, UI always 0), isEnabled`.
- The pattern is trimmed at construction.
- `fromJson` defaults: matchType `contains`, category "General", tagIds strings only, priority 0, isEnabled true.
- Swift must round-trip `minimumAmount`, `maximumAmount`, `priority`, `isEnabled` from backups and other sources even though the UI never sets them.

**Matching** (72-89), exact:
1. Return false if `!isEnabled` or the pattern is empty.
2. Return false if `transactionType != null && != type`.
3. Return false if `amount < minimumAmount`, or `amount > maximumAmount` (each check applies only if the bound is set).
4. Compare `description.trim().toLowerCase()` against `merchantPattern.toLowerCase()` using contains / startsWith / `==`, which are UTF-16 code-unit comparisons.
   - Swift: do NOT use `String.contains` or `==` (Character and canonical-equivalence semantics). Use UTF-16 arrays or `NSString.range(of:options:[.literal])`. Test with e + combining acute versus precomposed é.

**Priority order:** `rules` getter sorts by priority descending (26-30). Dart's sort is insertion sort (stable) up to 33 elements, so with the UI always writing 0 the order is insertion order up to 33 rules (from 34 it is the quicksort's order; `DartSort` reproduces it). `suggest` (152-167) returns the first match in that order.

**When rules run** (`transaction_form.dart:78-124`):
- Only inside the Add/Edit transaction form, on every change of the amount or description field, and once for a `prefill` (voice) transaction.
- The suggestion applies only if `categoryMap.containsKey(suggestion.category)`, i.e. the category is an active name of the form's type.
- On apply, it sets `category` and **clears the tag selection then replaces it with `rule.tagIds`**, overwriting manual tag picks.
- No match means no change.
- Amount is parsed with `double.tryParse(text) ?? 0`.
- **Never** applied: retroactively, on CSV import, on backup restore, on recurring generation, when opening an existing transaction for edit (until a field changes).

**Tag assignment in the transaction form** (`transaction_form.dart:346-379`):
- Caption "Tags" (13pt, semibold, secondary) above a Wrap of `FilterChip`s (label is the tag name). Shown only when tags exist.
- Selected state is a `Set` (insertion-ordered) saved as `tagIds: selectedTagIds.toList()` on both add and update.
- The edit form pre-fills the transaction's existing `tagIds`, orphans included.
- History filters by tag (`history_page.dart:1372`, chip row 1525+); that is another analyst's area.

**Delete tag** (71-91): remove the tag, then strip its id from every rule's `tagIds`, then persist tags and rules (two separate writes).
- Transactions keep the orphan id. Nothing reads orphans except that edits re-save them.

**Add rule** (93-98): `removeWhere(same id)`, then add. **Delete rule** has no side effects.

**Load quirk** (187-199): any malformed row makes the whole list empty, and the next write destroys it. Swift's lossless "unreadable rows kept verbatim" is safer.

### 1.7 CSV export and import

**Export** (`transaction_model.dart:995-1042`, `settings_page.dart:64-114`):
- Already byte-ported in `S:CSVExport.swift` (header, CRLF, `toStringAsFixed(2)`, date `yyyy-MM-dd`, sort by `date` ascending, file `transactions_yyyyMMdd_HHmmss.csv`).
- Share subject is "Budget Transactions Export".
- Flutter shows a green snackbar "Transactions exported successfully!" right after the share sheet returns, even if the user cancelled. On error: red "Error exporting transactions: {e}".
- The Swift MVP export uses the same file name and bytes, but has no busy state, no toast and no "All N transactions" subtitle.

**Import pipeline** (`settings_page.dart:116-214`, `transaction_model.dart:1044-1189`):

1. **Picker:** `FilePicker.pickFiles(type: custom, allowedExtensions: ['csv'], withData: true)`. Cancel or null bytes means silent return.
2. **Decode:** `utf8.decode(bytes, allowMalformed: true)`. Invalid bytes become U+FFFD; no error.
3. **BOM:** `utf8.decode` drops one leading EF BB BF and `parseTransactionsCsv` strips one more leading U+FEFF, so a double-BOM file passes (a third is removed by the header cell's `trim()`).
4. **Parse:**
   - csv 6.0.0 `CsvToListConverter(shouldParseNumbers: false, csvSettingsDetector: FirstOccurrenceSettingsDetector(eols: ['\r\n','\n']))`.
   - Field delimiter `,` and text delimiter `"` are fixed (defaults, no detector list for them).
   - **EOL** is whichever of `\r\n` or `\n` occurs first via `indexOf`; if neither occurs, it falls to the default `\r\n`. Mixed endings are therefore NOT normalised: bare `\n` in a CRLF file stays inside the field, and a bare `\r` remains before the LF if LF was detected. Fields are `.trim()`med afterwards, which hides that.
   - Quoted fields may contain newlines and doubled quotes `""`.
   - A quote in the middle of an unquoted field is literal (`_insideString`).
   - After a closing quote, further characters are appended and the field stays quoted, so a following `,` or line break is swallowed too until the next quote (`"abc"def,ghi\nx,y` is the single cell `abcdef,ghi\nx,y`).
   - An unterminated quote runs to EOF (`allowInvalid` defaults true, so no exception); a lone `"` as the whole last line adds no row.
   - A trailing empty line at EOF adds no row; an empty line in the middle yields a row `['']` (it still counts in the `Row N` numbering).
   - Port from `~/.pub-cache/hosted/pub.dev/csv-6.0.0/lib/src/csv_parser.dart` and `csv_settings_autodetection.dart`. Work in UTF-16 or unicode scalars, not `Character` ("\r\n" is one Character in Swift).
5. **Header:** the first row must have exactly 5 cells that, trimmed and lowercased, equal `date, type, category, description, amount`. Otherwise `FormatException('Not a valid transactions CSV export')`. An empty file also throws this.
6. **Rows** (data rows numbered from 2, `i+1`):
   - Skip rows whose cells are all blank.
   - `row.length != 5` gives the error "Row N: expected 5 columns but found K".
   - **Date:**
     - Trimmed, then `DateTime.tryParse`.
     - Fail on null, or if the text does not start with `DateFormat('yyyy-MM-dd').format(date)`. This rejects rollovers like 2026-02-30. Error: `Row N: invalid date "text"`.
     - Time-of-day and `Z` are accepted (`2026-02-15T10:30` keeps the time; `Z` yields a UTC value).
     - A plain `yyyy-MM-dd` gives local midnight.
   - **Type:** case-insensitive `income` or `expense`. Error: `Row N: invalid type "text"`.
   - **Category:** trimmed, must be non-empty. Error: "Row N: category is empty". It is NOT matched or normalised against existing definitions.
   - **Description:** trimmed; may be empty (no "Transaction" default).
   - **Amount:**
     - Trimmed, one leading `$` stripped.
     - If it contains a comma it must match `^\d{1,3}(,\d{3})+(\.\d+)?$`, else error, then commas are removed.
     - `double.tryParse`; null, non-finite or negative is an error `Row N: invalid amount "text"`. **Zero is accepted.**
     - Dart `double.tryParse` accepts `1e3`, `.5`, `5.`, `+5`, `0x1A`; Swift's `Double("…")` is close, and `DartNumbers.tryParseDouble` already exists internally.
7. **Dedupe:** multiset against EXISTING transactions only (not within the file).
   - Key: `yyyy-MM-dd|income|expense|category.trim()|description.trim()|amount.toStringAsFixed(2)`, using the row's local date fields.
   - Each existing occurrence cancels one incoming row (`duplicateCount++`); surplus copies import.
8. **No rows to import** (`settings_page.dart:141-166`; snackbar is red only if row errors exist):
   - errors > 0 and dups > 0: "No new transactions: {d} duplicates skipped, {e} rows could not be read".
   - errors > 0, no dups: "No transactions imported: {e} rows could not be read".
   - no errors, dups > 0: "All transactions in this file already exist".
   - none of the above: "No transactions found in this file".
9. **Confirm dialog:**
   - Title "Import {n} transactions?" (no singular form).
   - Content is null, or lines joined by `\n`: "{d} duplicates will be skipped" and "{e} rows could not be read".
   - Buttons Cancel / Import.
10. **Commit** (`importTransactions`, 1178-1189):
    - New `Transaction(...)` per row: fresh uuid v4, `createdAt = updatedAt = DateTime.now()` evaluated per valid row while parsing (duplicates included; values can repeat), `recurringTemplateId: null`, `tagIds: []`. Swift assigns the import time plus one microsecond per row instead (D6, PARITY_GAPS "CSV import").
    - Appended to the list in file order.
    - Duplicate ids are regenerated.
    - One `saveTransactions` (transactions section only).
    - Success snackbar (green): "Imported {n} transactions" or "Imported {n} transactions, {d} duplicates skipped".
11. **Errors:** any other exception gives a red "Could not import: {e}". `e` is `toString()`, so a FormatException prints as "Could not import: FormatException: Not a valid transactions CSV export". Swift can show the bare message.
12. No category definitions are created at import time. They appear at next launch via `ensureLegacyCategories`. Swift defines the imported rows' new names in the same commit, as that launch would (decided; PARITY_GAPS "CSV import").

### 1.8 Backup export and import (`backup.dart`, `settings_page.dart:279-577`)

**Envelope** (`encodeBackup`, 53-85): `JsonEncoder.withIndent('  ')` output.
- Top-level order: `schemaVersion (3), app ('budgie'), appVersion (PackageInfo.version), exportedAt (local toIso8601String), data`.
- `data` keys, in order:
  - transactions
  - netWorthEntries
  - categoryBudgetLimits
  - savingsGoals
  - recurringTransactions
  - themeMode ('light'|'dark'|'system'|null)
  - categories
  - transactionTags
  - categorizationRules
  - baseCurrencyCode
  - localeOverride
  - appLockEnabled
  - autoLockTimeoutSeconds
  - hideBalances
- Every list item uses the Dart model `toJson()` after model round-tripping. Each record is re-serialised from typed fields, so unknown keys and legacy shapes are normalised away; Swift's `raw` rows can differ in that case.
- **Swift `DartJSON` has no indented mode.** Add one matching Dart: 2-space indent, `"key": value`, `,\n`, `[]` and `{}` for empties, same string and number formatting.
- File name `budgie_backup_yyyyMMdd_HHmmss.json` in temp dir; share subject "Budgie Backup".
- The Flutter snackbar says "Backup exported" whether or not the user completed the share. On error: red "Could not export backup: {e}".

**Decode/validate** (`decodeBackup`, 90-170), in this exact order, since the first failing check determines the message:
1. Strip a U+FEFF BOM (`utf8.decode` already drops one, so one or two BOMs are accepted and three are not; verified). `jsonDecode` failure gives "This is not a valid Budgie backup file".
2. Not an object, or `schemaVersion` not an int, gives the same message.
3. `schemaVersion > 3` gives "This backup was made by a newer version of Budgie. Update the app and try again."
   - Any int ≤ 3 is accepted, including 0 and negatives; only schemas 1 (six `data` keys) and 3 ever existed; they differ only by missing keys.
4. `data` not an object gives "This backup file is missing its data."
5. Decode `categories`, `transactionTags`, `categorizationRules`.
   - A null section is an empty list.
   - A non-list, or any row failing the model `fromJson`, gives "This backup file is corrupt or incomplete." (the shared `_require` message).
6. Duplicate category ids, duplicate tag ids, duplicate rule ids, or any rule referencing an unknown tag id give the corrupt message.
7. If `categories` is non-empty, both an active income and an active expense category are required, else the corrupt message.
8. `localeOverride` must be null or a String, `appLockEnabled` and `hideBalances` null or bool, `autoLockTimeoutSeconds` null or num.
   - The timeout is `(num).toInt()` (fractions truncate) and must be `>= 0`; default 60.
9. Then the `BackupData(...)` arguments in source order:
   - transactions:
     - `type` must be exactly 'expense' or 'income'.
     - The model `fromJson` requires `date` to parse, `description` and `category` to be Strings, and `amount` to be a num.
     - `amount` must be finite.
     - `tagIds` may hold orphans.
   - netWorthEntries: `type` asset or liability, all snapshot amounts finite.
   - categoryBudgetLimits: a map of `num` values, all finite (zero and negative accepted here).
   - savingsGoals: target and current amounts finite.
   - recurringTransactions: `type` valid, amount finite, and monthly templates require `dayOfMonth` in 1..31. (Swift's existing parse also rejects an int-lexeme `amount`; Dart requires a double for recurring amounts.)
   - themeMode: `light`, `dark`, `system`, otherwise null.
   - currency: null gives USD; a non-string, or a trimmed length ≠ 3, gives "This backup has an invalid currency."; else `trim().toUpperCase()`.
10. A section that is present but not a list (or an item not a map) gives the corrupt message.

**Confirm dialog** (`_confirmRestore`, 525-577): title "Replace all data?", message "This will import {T} transactions, {N} net worth entries, {B} budgets, {G} goals and {R} recurring templates, replacing everything currently in Budgie. This cannot be undone." Buttons Cancel / Replace (danger colour, semibold).

**Replace semantics** (`settings_page.dart:421-475`), all-or-nothing intent but implemented as many commits:
1. One `AtomicFinancialStore.updateSections` with 10 sections, from the decoded backup:
   - transactions, netWorthEntries, `selectedNetWorthMonth` (the CURRENT in-memory value, not from the backup), categoryBudgetLimits (still including ≤0), savingsGoals, recurringTransactions, categories (possibly `[]`), transactionTags, categorizationRules, appSettings (5 keys).
   - Unknown sections are not touched (`Map.from(...)..addAll`).
2. Then each model re-persists, in order:
   - **Transactions:** duplicate ids get regenerated.
   - **Budgets:** limits ≤ 0 are removed.
   - **Net worth:** entries as decoded.
   - **Recurring:** replaced as decoded.
   - **Categories:** empty becomes built-ins; also re-validates duplicate ids and an active category per type.
   - **Tags/rules:** re-validated.
   - **App settings:** re-validated. Mirrors preferences: sets `base_currency_code`, sets/removes `locale_override`, sets `app_lock_enabled`, `auto_lock_timeout_seconds`, `hide_balances`.
   - **Theme:** set via preference only when the backup's `themeMode` is non-null.
   - **Recurring generator:** `TransactionGenerator.generateDueTransactions()` runs at the end. It can create up to 90 days of due rows immediately.
3. Widget cash flow is synced.
4. Green "Backup restored". A `FormatException` gives red "Could not import backup: {e.message}"; any other error gives red "Could not import backup: {e}".
5. **Side effect to flag:** restoring a schema-1 backup (no `categories`, tags, rules, currency, locale, lock, hide keys) resets those to defaults or built-ins. Custom categories, tags, rules and all settings are erased.
6. If the restored `appLockEnabled` is true, the gate locks the current session immediately.

### 1.9 Version row and "More"

Version row: see 1.1. Swift additionally has "Data diagnostics" (`DiagnosticsView`). Keep it, low-key, under About.

---

## 2. Layout and visual description (rebuildable)

**Flutter tokens** (`theme/app_colors.dart`, `widgets/glow_card.dart`, `design_system.dart`):

| Token | Dark | Light |
|---|---|---|
| Background | `0A0A12` | `F9FAFB` |
| Card | `13131F` | `FFFFFF` |
| Card border | white 7% (`0x12FFFFFF`) | `0x14101020` |
| Hairline | white 6% | `0x10101020` |
| Text primary | `F2F2FA` | `111827` |
| Text secondary | `9A9AB5` | `6B7280` |
| Text tertiary | `5C5C78` | `9CA3AF` |
| Segment track | `1B1B2C` | `E9E9F1` |
| Accent | `818CF8` | `6366F1` |
| Inactive icon (version row) | `8A8AA8` | `8A8AA8` |

Spacing: 4 / 8 / 16 / 24 / 32. Radii: 8 / 12 / 16 / 26 (cards).

**Fonts:** Gabarito (weights 400-900) and Spline Sans Mono (400/500/600). The TTFs are in `W/budget_app/assets/fonts/`. **Swift bundles no fonts** (no `UIAppFonts` in `S:project.yml` or `Info.plist`). Bundling them is required for a close match.

**Type styles:**
- pageTitle: Gabarito 26/800, letterSpacing -0.6.
- rowTitle: 15/600.
- rowSubtitle: 12/400.
- cardTitle: 17/700.
- eyebrow: Spline Mono 11/600, letterSpacing 2.4, uppercase.
- monoLink: Mono 11/600, letterSpacing 1.5.
- headingMedium: 22/600, letterSpacing -0.2.
- bodyMedium: 15/400.
- caption: 13/400.

**Root scroll** (`settings_page.dart:594-906`): `SingleChildScrollView`, bottom padding `max(20, safeBottom) + 96` (clears the floating dock), `SafeArea(bottom:false)`.
1. `BudgieHeader(title:'Settings')`: padding L20 T12 R20, title left, 36px spacer right.
2. Brand card at L20 T24 R20:
   - `GlowCard` radius 26, padding 20, 1px accent@30% border.
   - Gradient topLeft to bottomRight: `alphaBlend(accent@22%, card)` to `card`.
   - Content: 52x52 logo (radius 16, accent glow blur 24 @40%), 16 gap, "Budgie" (cardTitle 18/800, letterSpacing -0.3), 2 gap, tagline 13pt secondary.
3. Each section: eyebrow at padding L24 T28 R24 (tertiary), then `GlowListCard` at L20 T10 R20.
4. `GlowListCard`: radius 26, padding 8, rows separated by a 1px hairline inset 12 each side.
5. **Row** (1227-1310):
   - Padding V14 H12.
   - 40x40 tile (radius 14; tint = icon colour @14% or the override), icon 20 weight 500.
   - 12 gap; title above a 2px gap and 1-line ellipsised subtitle; 12 gap; trailing (chevron 20 in tertiary, or Switch.adaptive, or spinner).
   - Ink radius 18 on tap.
6. **Theme row:** same shape, subtitle "Light, dark, or match device", trailing `SegmentedPillControl`:
   - Track `1B1B2C` / `E9E9F1`, padding 3, radius 999.
   - Segment padding H12 V6, text rowSubtitle (600, or 700 selected).
   - Selected: accent fill with onAccent text (dark `0A0A12` / light white). Unselected: `8A8AA8` (dark) / `6B7280` (light).
   - 200 ms ease-out.

**Row icon tints:**
- accent: Categories, App lock, Recurring, Import CSV, Import backup.
- info/blue: Tags & rules, Number format, Lock delay.
- income/green: Currency, Export CSV, Export backup.
- warning/orange: Hide balances.
- Data rows use a 12% background override.

**Categories page:**
- Plain themed Scaffold.
- AppBar title "Categories".
- Pill and switch as in 1.5; cards 8 apart with 8px inner padding.
- Editor is a centred Material AlertDialog.

**Tags & rules page:**
- Plain AppBar "Tags & rules".
- `ListView` padded 16; section titles are headingMedium with a text-button "ADD" on the right; 8 gap; `GlowListCard`/`GlowCard`; 32 between the two sections.

**Snackbars:**
- Floating, radius 12, coloured fill: income green for success, expense red for errors.
- Neutral (no fill) for the CSV "no rows" message when there are no errors.
- Category and tag errors use the default fill.

**Swift mapping** (from the design spec, "native SwiftUI with Flutter palette"; this report reproduces the Flutter look):
- Build reusable `Card` (radius 26, border 1px `getCardBorder`), `ListCard` (padding 8, hairline separators inset 12), `IconTile(symbol:tint:)`, `Eyebrow`, `SegmentedPill`. These are likely shared with the other analysts.
- SF Symbol equivalents:

| Material Symbol | SF Symbol |
|---|---|
| category | `square.grid.2x2` |
| auto_awesome | `sparkles` |
| payments | `banknote` (or `dollarsign.circle`) |
| language | `globe` |
| lock | `lock` |
| timer | `timer` |
| visibility_off | `eye.slash` |
| repeat | `repeat` |
| file_download | `square.and.arrow.down` |
| file_upload | `square.and.arrow.up` |
| backup | `externaldrive` |
| settings_backup_restore | `clock.arrow.circlepath` |
| info | `info.circle` |
| dark_mode | `moon` |
| chevron_right | `chevron.right` |
| label | `tag` |
| delete | `trash` |
| check | `checkmark` |

---

## 3. Gap versus the Swift MVP

`S:Budgie/Views/SettingsView.swift`, `S:Budgie/Views/AppLock.swift`, `S:Budgie/App/AppModel.swift`.

| Area | Swift today | Missing / different |
|---|---|---|
| Layout | Native `Form` with Appearance / Currency / Security / Data / About | Brand card, eyebrows, icon tiles, `GlowListCard` look, dock padding |
| Theme | Picker System/Light/Dark, pref only | Segmented pill labelled Light/Dark/Auto, order Light, Dark, Auto |
| Currency | `Picker` with `"USD – US Dollar"` labels, `setBaseCurrency` writes pref + section | Row subtitle `"US Dollar (USD)"`, bottom-sheet pattern, checkmark |
| Number format | Not present | Locale picker, `setLocaleOverride`, pref remove on null |
| App lock | Toggle authenticates first then `setAppLockEnabled` | Subtitle logic, lock delay row + sheet + `setAutoLockTimeoutSeconds`, lock screen copy and cover text |
| Hide balances | Formatter honours it, no toggle | Toggle + `setHideBalances` |
| Categories | Read-only pickers via `CategoryCatalog.load` (no `isBuiltIn`) | Entire management UI, mutations, cascade, legacy materialisation, `serialize` case |
| Tags & rules | Not present; tags preserved on edited transactions | Tag/rule CRUD, matching engine, form integration (add `tagIds` to `Edit` and `addTransaction`), History tag filter (other analyst) |
| CSV export | Works, same bytes and file name | No busy state, no toast, no "All N transactions" subtitle |
| CSV import | Not present | Parser, dedupe, confirm, toasts, `importTransactions` |
| Backup export/import | Not present | Envelope encode/decode, pretty-printer, restore, dialogs |
| Version | "version (build)" | Flutter shows only the marketing version "Budgie X.Y.Z"; keep build in diagnostics |
| Toasts | `alert` only | Snackbar-like transient toast component |
| Category colours | `purple` = 8B5CF6 / A78BFA | Flutter purple = `818CF8` both modes |

---

## 4. BudgieCore additions and AppModel API

### 4.1 Cross-cutting helpers

- `DartString.trim` (Dart `String.trim` whitespace set: Unicode White_Space plus U+FEFF). Swift's `.whitespacesAndNewlines` does not include U+FEFF. Used for category, tag, rule, CSV and backup-currency trimming.
- `DartString.lowerCase` (full Unicode lowercasing), plus UTF-16 based `contains`, `hasPrefix` and equality for rule matching.
- `DartJSON.encodeIndented(_:)`, matching `JsonEncoder.withIndent('  ')`.
- `TransactionRecord.Edit` gains `tagIds: [String]`. `Edit.applying` should patch `tagIds` in `raw` (write the key if missing). `AppModel.addTransaction(..., tagIds:)` passes it to `data.addTransaction`, which already accepts it.

### 4.2 Category layer, `Domain/CategoryEditing.swift`

- Extend `CategoryInfo` (or add `CategoryRecord` with `raw: JSONObject`) with `isBuiltIn`. Seeds carry `true`. Preserve unknown keys in `raw` and write typed keys in Dart order.
- `FinancialData` holds `categoryRows`, `categoriesSection()`, and these throwing mutators: `addCategory(type:name:iconIdentifier:colorToken:id:)`, `updateCategory(id:name:iconIdentifier:colorToken:)`, `setCategoryArchived(id:_:)`, `moveCategory(id:offset:)`.
  - Errors: `CategoryEditError.nameRequired` ("Category name is required"), `.duplicateName` ("A category with this name already exists"), `.lastActive` ("At least one category must remain active"). Localised descriptions equal Flutter's copy.
  - `uniqueID(type:name:existing:)` implements the slug algorithm (scan scalars; keep a-z0-9, collapse runs, trim `-`).
- `FinancialData.ensureLegacyCategories(now:)` mirrors the launch pass. Sources are the three groups from 1.5 (transactions, templates, expense budget-limit keys). It also normalises sort orders (all rows, archived included). Returns whether it changed.
  - Swift should call it at bootstrap after load and persist `categories` only if the canonical JSON differs, exactly like Flutter. This also writes the seed list on a first-ever launch.
  - Otherwise the management page must show the virtual categories and materialise them on the first mutation.
- `FinancialData.renameCategoryCascade(type:oldName:newName:now:) -> [String]` returns the changed section names.
  - Transactions: patch `category` and `updatedAt` in `raw` only, exact match on type and name.
  - Budget limits: on the raw `categoryBudgetLimits` object, remove old key then append new key with the old value as `.double`. If the new key exists, drop the old limit.
  - Templates: patch `category`.
  - Rules: category rename. Recommended fix: only when `transactionType == nil || == type`. Flutter parity: category only.
  - Caller persists `[categories, transactions, categoryBudgetLimits, recurringTransactions, categorizationRules]` in one `persist`.
- `budgetLimits` must be re-derived after any change to `categoryBudgetLimits`, since it is currently computed only at load (`S:FinancialData.swift:120`). Safe-to-spend reads it.

### 4.3 Tags, rules and suggestions, `Domain/Categorization.swift`

- `TagRecord` (id, name, colorToken, raw) and `RuleRecord` (id, merchantPattern, matchType, transactionType?, min?, max?, category, tagIds, priority, isEnabled, raw).
- Typed views with unreadable rows kept verbatim, like the other sections.
- `FinancialData.addTag(name:colorToken:id:)` (throws "Tag name is required" or "A tag with this name already exists").
- `deleteTag(id:)`: removes the tag and its id from every rule's `tagIds`, and (recommended, invisible to Dart) leaves transactions untouched. Persists tags + rules.
- `addRule(_:)` (replace same id), `deleteRule(id:)`.
- `rulesByPriority` (priority descending with `DartSort`, Dart's tie order).
- `suggest(type:description:amount:) -> (category: String, tagIds: [String])?` implementing 1.6 exactly, including the active-category check the form performs. Expose `activeCategoryNames(for:)`.

### 4.4 CSV import, `Formatting/CSVImport.swift`

Implemented (`Formatting/CSVParser.swift`, `Formatting/CSVImport.swift`; Fixtures/csvimport):

- `CSVParser.parse(_ text: String) -> [[String]]`, a faithful port of csv 6.0.0 with the settings in 1.7 (first-occurrence EOL detection, quoted fields, quote-in-middle literal, no exception on unterminated quote), over UTF-16 code units.
- `CSVImport.decode(_ bytes: [UInt8]) -> String` (`utf8.decode(allowMalformed: true)`), and `CSVImport.parse(bytes:existing:calendar:)` / `parse(text:existing:calendar:) throws(CSVImport.Failure) -> Summary { drafts: [Draft], duplicateCount: Int, rowErrors: [String] }`. Pure; `existing` is the readable transactions.
  - Reuses `calendar.tryParse` for the date and `DartDouble.tryParse` for the amount.
  - Dedupe is a multiset keyed on `yyyy-MM-dd|type|category.trim()|desc.trim()|toStringAsFixed(2)` as UTF-16 code units (existing rows by their stored code units).
  - Header failure throws `.notATransactionsCSV`; `message` is "Not a valid transactions CSV export", `flutterDescription` Dart's `e.toString()`. `.unreadableFile` is Swift's (D6) for a file that cannot be read.
  - Copy: `Summary.emptyResultMessage`, `confirmTitle`, `confirmDetails`/`confirmMessage`, `successMessage`, `CSVImport.failureMessage(_:)` (`Message { text, tone: .neutral/.success/.error }`), `cancelButtonTitle`, `importButtonTitle`; D6 singular forms.
- `FinancialData.importTransactions(_ summary:now:newID:) -> CSVImportResult { data, imported, addedCategories, sections }`: pure; `createdAt` = `now` + i µs; the imported rows' new category names materialised; `sections` is the one commit (`transactions`, plus `categories` when it changed; empty for no drafts).

### 4.5 Backup envelope, `Formatting/BackupEnvelope.swift`

- `BackupEnvelope.encode(_ input:, appVersion:, exportedAt:) -> [UInt8]` produces indented JSON in the key order from 1.8.
  - Each list is serialised from typed records into canonical Dart `toJson` shape (not raw). Add `canonicalJSON()` on `TransactionRecord`, `NetWorthEntryRecord`, `SavingsGoalRecord`, `RecurringTemplate`, category, tag and rule types.
  - `exportedAt` uses `toIso8601String()` of the local wall clock.
- `BackupEnvelope.decode(_ bytes: Data) throws(BackupError) -> DecodedBackup`.
  - Implements the ordered checks in 1.8 and the exact messages: "This is not a valid Budgie backup file", the newer-version message, "This backup file is missing its data.", "This backup file is corrupt or incomplete.", "This backup has an invalid currency."
  - `DecodedBackup` exposes counts for the confirm dialog (transactions, net worth entries, budgets, goals, templates).
- `FinancialData.replacing(with: DecodedBackup, ...) -> (sections: [(String, JSONValue)], data: FinancialData)`. It applies the normalisation Flutter does after the first commit:
  - regenerate duplicate transaction ids,
  - drop budget limits ≤ 0,
  - empty categories become seeds,
  - `selectedNetWorthMonth` kept from the current data.
- Post-restore steps: run `RecurringGenerator.generateDue`, sync the widget, apply the theme preference if present, mirror the five settings preferences (including removing `locale_override` on null).

### 4.6 `AppModel` API additions

All `@MainActor`. Mutators return `Bool` (saved) and go through `persist`. Extend `serialize(_:)` to cover `categories`, `transactionTags`, `categorizationRules`, `categoryBudgetLimits`, `selectedNetWorthMonth`.

```swift
// Settings
func setLocaleOverride(_ locale: String?) async
func setHideBalances(_ on: Bool) async
func setAutoLockTimeout(_ seconds: Int) async       // pref .int + section; ignore < 0

// Categories
func categoryDefinitions(type: TransactionType, includeArchived: Bool) -> [CategoryInfo]
func addCategory(type: TransactionType, name: String, iconIdentifier: String, colorToken: String) async throws(CategoryEditError) -> Bool
func updateCategory(id: String, name: String, iconIdentifier: String, colorToken: String) async throws(CategoryEditError) -> Bool
func setCategoryArchived(id: String, _ archived: Bool) async throws(CategoryEditError) -> Bool
func moveCategory(id: String, offset: Int) async throws(CategoryEditError) -> Bool

// Tags and rules
var tags: [TagRecord] { get }
var rules: [RuleRecord] { get }
func addTag(name: String, colorToken: String = "accent") async throws(TagError) -> Bool
func deleteTag(id: String) async -> Bool
func addRule(_ draft: RuleDraft) async -> Bool
func deleteRule(id: String) async -> Bool
func suggestion(type: TransactionType, description: String, amount: Double) -> RuleSuggestion?

// Data movement
func exportBackup() throws -> URL                                       // temp file budgie_backup_<ts>.json, subject "Budgie Backup"
func decodeBackup(_ data: Data) throws(BackupError) -> DecodedBackup   // pure
func restoreBackup(_ backup: DecodedBackup) async -> Bool
func previewCSVImport(_ data: Data) throws(CSVImportError) -> CSVImportSummary   // pure
func importTransactions(_ drafts: [TransactionDraft]) async -> Bool
```

**File handling:**
- **Export:** keep the existing UIActivityViewController wrapper (`ActivityView` in `SettingsView.swift`, currently `private`; extract it) for CSV and backup. It gives "Save to Files", AirDrop, etc. and matches Flutter's `Share.shareXFiles`. `ShareLink` cannot lazily produce a file on demand. Alternatively `.fileExporter` with a `FileDocument`. Delete the temp file after dismiss, since the backup holds all financial data.
- **Import:** `.fileImporter(isPresented:allowedContentTypes:[.commaSeparatedText, UTType(filenameExtension:"csv")]` for CSV, and `[.json]` for backup.
  - `allowsMultipleSelection: false`. Wrap the read in `url.startAccessingSecurityScopedResource()` with `defer { stop }`.
  - Consider `NSFileCoordinator` for iCloud items not yet downloaded.
  - Read `Data`; do not pass URLs into the model.
- `fileImporter` inside the `UIHostingController` scene works. It runs out of process and normally does not flip the scene inactive, so the privacy cover should not trigger. The share sheet also stays in-process.

---

## 5. SwiftUI view breakdown and build sequence

**Files** (under `S:Budgie/Views/More/` unless noted; shared components may belong to another analyst):
- `MoreView.swift`: root scroll. `BrandCard`, `SectionEyebrow`, `ListCard`, `SettingsRow` (icon tile, title, subtitle, trailing).
- `ThemeRow` with `SegmentedPill`.
- `ChoiceSheet.swift`: generic bottom sheet (`.sheet`, detents `.medium/.large`, drag indicator, title 22/600, checkmark rows). Used by currency, locale and lock delay. Also holds the `currencies`, `locales` and lock-delay tables.
- `CategorySettingsView.swift`: pill, "Show archived" toggle, `CategoryRow` (card + `Menu` with Edit / Move up / Move down / Archive-Restore).
- `CategoryEditorSheet.swift`: name field with "Enter a category name" validation, `IconPickerGrid` (18), `ColorSwatchRow` (8), Cancel / Add-Save. Shows error text from `CategoryEditError`.
- `TagsAndRulesView.swift`: `TagRow`, `RuleRow`, `NewTagAlert` (an `.alert` with a `TextField`), `RuleEditorSheet` (merchant text, type, match, category picker, tag chips, Add disabled while blank).
- `TagChipRow.swift`: reusable tag `FilterChip`-style wrap for the transaction form and rule editor.
- `DataTransfer.swift`: `@Observable DataTransferController` with a busy enum (exporting / importing / backingUp / restoring) that disables the four rows, plus the `Toast` model. Contains `CSVImportFlow` and `BackupFlow` (picker → decode → confirm → commit → toast).
- `ImportConfirmDialog` and `RestoreConfirmDialog`: exact copy from 1.7 and 1.8.
- `ToastOverlay.swift`: floating capsule, income or expense colour, auto-dismiss.
- `ShareSheet.swift`: extracted from `SettingsView`.
- `AppLock.swift`: add lock screen copy and "App preview hidden"; consider counting `.inactive` time.
- `Theme.swift`: fix `purple`; consider bundled fonts and `UIAppFonts`.
- `SettingsView.swift`: replace with `MoreView`; keep `DiagnosticsView` under About.
- `BudgieCore/Domain/…` per section 4, with tests.

**Build order and effort:**

| # | Step | Effort |
|---|---|---|
| 1 | Shared visual components (ListCard, IconTile, Eyebrow, SegmentedPill, ChoiceSheet, Toast); fonts; fix `purple`; extract ShareSheet | M |
| 2 | Settings root parity: brand card, all rows and copy, Number format, Lock delay, Hide balances, `AppModel` setters, busy states, Version row | M |
| 3 | Category core (model with `isBuiltIn`, mutators, `ensureLegacy`, cascade, one-commit persist, `serialize` cases, `budgetLimits` re-derivation) plus parity tests | L |
| 4 | Category UI (page, editor, menu, error copy) | M |
| 5 | Tags and rules core (records, matching, suggestion) plus tests | M |
| 6 | Tags and rules UI, and transaction-form integration (`tagIds` in `Edit` and `addTransaction`, suggestion on field change, tag chips) | M |
| 7 | CSV parser and import core plus adversarial-corpus tests | M |
| 8 | CSV import UI and export polish | S |
| 9 | Backup core (`DartJSON` indent, canonical `toJson` for each record, encode, decode with ordered validation) plus fixtures | L |
| 10 | Restore (one-commit replace, generator, widget, prefs mirror, pre-restore safety copy) and its UI | M |
| 11 | Lock-screen fidelity and small copy fixes | S |
| 12 | Parity-harness additions (below) | M-L |

**Parity-test notes** (extend `native/ParityHarness/parity/logic_fixtures_test.dart` and `verify_swift_output_test.dart`):
- **Backup encode:** for each store fixture scenario, Dart `encodeBackup` with fixed `appVersion` and `exportedAt` (via `parityNow()`). Swift must match the bytes.
- **Backup decode:**
  - Dart and Swift must agree on accept/reject and message for adversarial inputs: BOM, wrong schema types, schema 0 and 4, duplicate ids, orphan rule tag, missing active category, bad currency, wrong section types, monthly template with `dayOfMonth` 0 or 32, NaN amounts.
  - On accept, the restore payload (canonical sections) must equal what Dart writes.
- **Swift-written backups load in Dart:** feed to `decodeBackup` and the full restore chain.
- **CSV:** corpus of tricky files (mixed EOL, quoted newlines, doubled quotes, lone quote, `"abc"def`, blank lines, 4 and 6 columns, dates 2026-02-30, 2026-9-1, T10:30, Z, amounts `$1,234.50`, `1,23`, `-0`, `0`, `1e3`, `.5`, `5.`, `NaN`, `0x1A`, U+FFFD bytes). Compare the transactions list, duplicate count and error strings. Include multiset dedupe cases, and a file exported by Swift's own CSV export.
- **Rules:** match vectors including type null/expense/income, min/max boundaries, empty pattern, disabled rule, decomposed vs precomposed é, `İ` and `ß` lowercasing, whitespace-padded description.
- **Categories:** random operation sequences (add, rename, archive, move, ensureLegacy) applied to Flutter `CategoryProvider` plus the three model `renameCategory` passes, then compare canonical sections with Swift (excluding rules-cascade type restriction if deliberately fixed, and record that difference).
  - Slug/unique-id vectors: "Café", "!!!", collisions.
  - Budget-key rename order and collision drop.
- **Store round-trip:** after each Swift mutation, `verify_swift_output` must load the store through the real Dart models with no rejected rows.

---

## 6. Risks and open questions

**Data-loss risks:**
- **Restore is destructive.** It replaces everything and cannot be undone in Flutter.
  - Swift's store keeps one prior generation as `.backup.json`, which the very next commit (for example the post-restore generator) overwrites.
  - Recommend a pre-restore safety copy of the primary store file (for example `Application Support/pre-restore/<ts>/`), invisible to Dart. Confirm with the user.
- **Restore commit strategy.**
  - Option A: `store.updateSections` first, swap memory only on success (nothing changes on failure).
  - Option B: swap memory first and use the tracker (banner on failure).
  - Option A is safer for a destructive replace. It bypasses the tracker, so an `AppModel`-internal path is needed and any pending unsaved sections must be cleared or superseded.
  - Flutter uses about 10 commits with no rollback, so either option is an improvement.
- **Schema-1 backups reset settings, categories, tags and rules.** Parity or skip absent keys? (Skipping is safer; it changes the outcome, not the file format.)
- **Backup with `appLockEnabled:true`** locks immediately after restore. On a device with no passcode Swift lets the user in; Flutter shows "Disable App Lock".
- **Import size and iCloud:** no size cap in Flutter; a huge or not-yet-downloaded iCloud file can fail or stall. UTF-8 with `allowMalformed` silently replaces bad bytes, which can alter descriptions.
- **Cascade correctness:**
  - Case-sensitive exact match for transactions, templates and budgets, but case-insensitive for the duplicate check (so `groceries` can't be added if `Groceries` exists; a case-only rename is allowed and cascades).
  - Budget-limit collision drops the old limit silently.
  - Rules ignore type (Flutter bug).
  - Dart commits piecemeal; Swift must be one commit or a crash can leave inconsistent names.
  - `budgetLimits` is a load-time snapshot in Swift and must be refreshed after rename and restore.
- **Legacy materialisation writes the `categories` section at launch** in Flutter. If Swift does not, an unmigrated Flutter user's first Swift category edit writes a fuller list than they saw (virtual names appear). Decide whether Swift bootstrap writes it.
- **Lossless philosophy vs Dart load:** Dart drops all tags/rules if any row is bad; Swift keeps unreadable rows. Note in PARITY_GAPS.
- **Orphan tag ids:** parity leaves them on transactions; cleaning would alter rows and `updatedAt`. Decision needed. Recommendation: leave (also keeps Flutter and Swift identical).
- **Persistence of new mutators:** every new mutator must extend `serialize(_:)`. Otherwise `PersistenceTracker.retry` re-persists stale JSON.

**Open questions for the user:**
1. Fix the rules-cascade type bug in Swift (rename only rules whose type is nil or matches), or copy Flutter exactly?
2. Delete tag: leave orphan `tagIds` on transactions (Flutter) or clean them?
3. Move up/down: keep Flutter's index-in-full-list quirk, or move relative to the visible list? Drag-to-reorder instead?
4. Restore strategy A vs B, and add the pre-restore safety copy?
5. Restore of a schema-1 backup: reset settings/categories/tags/rules like Flutter, or leave absent keys unchanged?
6. Should the widget mask amounts when Hide balances is on? Flutter does not.
7. Keep Swift's authenticate-before-enabling App Lock (differs from Flutter, which locks immediately), and its no-passcode fall-through?
8. The user calls this the "More tab": does the plan replace the "Settings" tab, and where does Recurring live? The Flutter Settings page hosts the Recurring row under DATA (excluded here).
9. CSV import and backup errors: show Flutter's literal strings (including the "FormatException: " prefix in "Could not import: …") or the cleaner bare message?
10. Bundle Gabarito and Spline Sans Mono for a close match? Licence check on the TTFs in `budget_app/assets/fonts/`.

**Minor observations for other analysts:**
- The Flutter unsaved banner copy is "Some changes are not saved to this device yet." in danger colour with a cloud_off icon (`widgets/unsaved_changes_banner.dart`). Swift's is "Some changes aren't saved yet." in a `.bar` background.
- The Flutter banner watches only the transaction and recurring models; category, tag, rule and settings save failures in Flutter are unhandled exceptions. Swift's tracker covers them all.
