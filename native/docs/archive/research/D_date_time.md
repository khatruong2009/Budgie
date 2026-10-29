> Archived; paths refer to the `flutter-final` tag.

# D. Date and time semantics (Flutter -> SwiftUI parity)

Scope: `budget_app/lib` at commit b69008d (branch claude/swiftui-mvp-migration-71aa05).
Status tags: VERIFIED = read in code and/or executed with `dart run`; INFERRED = reasoned, not executed.
Paths below are relative to `budget_app/lib/` unless noted. Abbreviations: NWE = net_worth_entry.dart, TM = transaction_model.dart, TG = transaction_generator.dart, RT = recurring_transaction.dart, RTM = recurring_transaction_model.dart, STS = safe_to_spend.dart, RTF = recurring_transaction_form.dart.

Empirical runs: Dart SDK from /Users/khatruong/Documents/flutter/bin/dart, `TZ=<zone> dart run`. Throwaway scripts (x.dart, sim.dart, b.dart, c.dart) are in a `mktemp -d` dir outside the repo; the relevant snippets are reproduced inline below. Zones exercised: America/New_York (primary; 2026 DST: forward Sun Mar 8 02:00, back Sun Nov 1 02:00), UTC, Asia/Tokyo, Asia/Kolkata, Europe/London, Australia/Sydney, Australia/Lord_Howe, America/Sao_Paulo.

---------------------------------------------------------------------------------------------------

## 0. Headline findings (read this first)

1. Every date in the app is a **local wall-clock `DateTime` with no offset**. There is no UTC anywhere (VERIFIED: `grep toUtc|DateTime.utc|isUtc lib/` returns nothing). Persistence is `toIso8601String()` of a local DateTime, e.g. `2026-03-08T00:00:00.000`, which has no offset. Re-parsing in a new zone preserves the wall-clock digits, not the instant (VERIFIED, section 4).
2. Recurrence uses `from.add(Duration(days: 7|14))` for weekly/biweekly (TG:71-73). That is +168h / +336h of elapsed time, NOT +7 calendar days. In DST zones the wall-clock time drifts by 1 hour after a transition, and after fall-back a midnight occurrence lands at 23:00 on the PREVIOUS calendar day (VERIFIED, section 3.4: NY weekly Sunday chain becomes Saturday 23:00 from Nov 7). A Swift port using `Calendar.date(byAdding: .day, value: 7)` will NOT reproduce this. Decision needed: replicate or fix (the Flutter behaviour is a latent bug).
3. Monthly recurrence remembers the template `dayOfMonth` and clamps to the target month's last day; it does NOT drift (31 -> 28 -> 31, VERIFIED). But the FIRST occurrence is `startDate` verbatim, even if `startDate.day != dayOfMonth`, and every monthly step after the first resets time-of-day to 00:00.
4. `dayOfWeek` on weekly/biweekly templates is stored and shown in the UI but never used by any generation or projection code (VERIFIED by grep). Cadence is entirely determined by `startDate`'s weekday.
5. Editing a recurring template resets `nextOccurrence` to `startDate` and `isActive` to true (RTF:658-674 builds a fresh `RecurringTransaction` without those fields; RT:35-36). Next generation run then re-creates every occurrence in the 90-day window again. There is NO dedup by `recurringTemplateId` anywhere (VERIFIED, simulated in section 3.7). This is an existing duplicate-transaction bug the port should decide about.
6. `Duration.inDays` truncates and `DateTime.difference` is elapsed time, so midnight-to-midnight day counts across spring-forward are one short (VERIFIED: NY `DateTime(2026,3,15).difference(DateTime(2026,3,1)).inDays == 13`). Affects `SavingsGoal.daysRemaining` (savings_goal.dart:60-65) and `SafeToSpendCalculator.daysRemaining` (STS:131-138).
7. Net-worth snapshot timestamps are compared by exact `DateTime ==` (NWE:219, TM:670) and carry microseconds when created from `DateTime.now()` (VERIFIED microsecond field non-zero; ISO output has 6 fractional digits). Swift `Date` round-tripping via a millisecond ISO formatter will break snapshot replace/delete-by-recordedAt.
8. `TransactionModel.selectedMonth` is initialised to un-normalised `DateTime.now()` (TM:152) and is not persisted; all consumers only read `.year`/`.month`.

---------------------------------------------------------------------------------------------------

## 1. Month normalization and "selected month"

### 1.1 Canonical form
Months are normalised to `DateTime(year, month)` = first day of month at 00:00:00.000 local. Key sites (all VERIFIED read):

| Site | What it builds |
|---|---|
| TM:231-234 `selectMonth(date)` | `selectedMonth = DateTime(date.year, date.month)` |
| TM:236-243 `selectNetWorthMonth` | `_selectedNetWorthMonth = DateTime(date.year, date.month)`, then persists `toIso8601String()` (TM:252-253) |
| TM:404-410 load | parses stored ISO with `DateTime.tryParse`, rebuilds `DateTime(y, m)`; if unparsable, keeps the default set at TM:153-154 (current month) |
| TM:152 | `DateTime selectedMonth = DateTime.now();` NOT normalised (has day and time) |
| TM:153-154 | `_selectedNetWorthMonth = DateTime(DateTime.now().year, DateTime.now().month)` |
| TM:184 | `_monthKey(d) = d.year * 12 + d.month` (integer bucket key for the ledger) |
| TM:729-736 `getAvailableMonths` | inverse of `_monthKey`: `year=(key-1)~/12; DateTime(year, key - year*12)`. VERIFIED: 2026*12+12 -> 2026-12-01; 2027*12+1 -> 2027-01-01 |
| TM:523 / 699 | previous month: `DateTime(month.year, month.month - 1)` (relies on month underflow, see 5.2) |
| TM:1266-1279 `getRollingCashFlowTrend` | `start = DateTime(now.year, now.month - months + 1)`; month i = `DateTime(start.year, start.month + index)` |
| TM:1285-1290 YoY | `DateTime(y - 1, m)` |
| history_page.dart:50, 160, 172 | previous-year month; rolling 12: `DateTime(sel.year, sel.month - 11 + index)` |
| spending_page.dart:458, 472 | `selectedBudgetMonth`, previous month with `month - 1` |
| spending_page.dart:536-539 | month picker: `selectMonth(DateTime(selectedMonth.year, index + 1))` (picks month within the CURRENTLY selected year); `currentMonthIndex = DateTime.now().month - 1` (spending_page.dart:50) is only the initial wheel position |
| category_page.dart:80 | previous month `month - 1` |
| insights/insight_engine.dart:58-59, 115, 152, 228, 307, 372 | normalised month, `DateTime(y, m+1, 0).day` days-in-month, `month - offset` |
| STS:66-67 | `normalizedMonth = DateTime(y,m)`, `monthEnd = DateTime(y, m+1, 0)` (last day, 00:00) |
| net_worth_page.dart:413-415 | `cutoff = DateTime(anchor.year, anchor.month - (months-1))`; compares `DateTime(p.date.year,p.date.month).isBefore(cutoff)` |
| net_worth_page.dart:2246, 2505 | entry-form month `DateTime(y, m)`; picker `firstDate: DateTime(1970)`, `lastDate: DateTime(now.year, now.month + 1, 0)` (last day of current month) |
| history_page.dart:1824-1825 | pickers `firstDate: DateTime(2000)`, `lastDate: DateTime(now.year + 10, 12, 31)` |
| transaction_form.dart:391-392 | picker `firstDate: DateTime(2000)`, `lastDate: DateTime.now()` (no future dates) |
| savings_goals_page.dart:1060-1063, 1189-1190 | default target date `DateTime(now.year, now.month + 6, now.day)` (month overflow-normalised, e.g. Aug 31 + 6 -> "Feb 31" -> Mar 3); picker `DateTime(now.year - 1)` .. `DateTime(now.year + 20)` |
| voice_expense_service.dart:189-193 | `DateTime(today.year, today.month, today.day - maxSpokenDateLookbackDays)` (day underflow normalised) |
| savings_goal.dart:52-64; TM:883 | day-normalised `DateTime(y,m,d)` |

### 1.2 What "selected month" means
- `selectedMonth` (TM:152) drives Spending/History/Category screens: `totalIncome`/`totalExpenses` (TM:263-269), `currentMonthTransactions`, `getMonthlySummary` (TM:966) all do `_monthLedger()[_monthKey(month)]`, i.e. bucket = local calendar year*12+month of `transaction.date`. VERIFIED.
- It is in-memory only. `serializeSection` (TM:246-262) persists only `selectedNetWorthMonth`; `selectedMonth` is not a persisted section. VERIFIED. On every cold start it is "now" (un-normalised). The port should default to the current month.
- Because `_monthKey` ignores day/time, the un-normalised initial value is harmless. VERIFIED (all readers use `.year`/`.month`, or re-normalise, e.g. spending_page.dart:458).
- `selectedNetWorthMonth` is separate, persisted as an ISO string of a first-of-month DateTime (`2026-03-01T00:00:00.000`), reloaded at TM:404-410. Included in the backup path (TM:1225-1230 region persists all sections).
- Bucketing uses the transaction's stored local calendar date. A transaction stamped 23:00 on the 31st stays in that month; one stamped 00:30 on the 1st is in the new month. Consequence for DST-shifted recurrences: see 3.4.

### 1.3 Ledger `now`
Anything that means "today" uses `DateTime.now()` inline (TM:49, 318, 452, 554, 1271, 1443, 1481; STS receives `asOf` as a parameter; insight_engine receives `now`). `TransactionGenerator` reads `DateTime.now()` internally (TG:19) and is NOT clock-injectable. The port should inject a clock.

---------------------------------------------------------------------------------------------------

## 2. Net-worth helpers (NWE) and snapshot semantics

All VERIFIED (read). Examples computed by hand from the code and consistent with the executed 2026-03 runs.

### 2.1 Helper functions

| Function (NWE line) | Algorithm | Example |
|---|---|---|
| `netWorthMonthKey(d)` (9-12) | `DateFormat('yyyy-MM').format(DateTime(d.year, d.month))` | 2026-03-05 14:00 -> `"2026-03"` |
| `netWorthDayKey(d)` (14-17) | `DateFormat('yyyy-MM-dd').format(DateTime(y,m,d))` | -> `"2026-03-05"` |
| `netWorthMonthFromKey(k)` (19-22) | `k.split('-')`; `DateTime(int.parse(p0), int.parse(p1))` | `"2026-03"` -> 2026-03-01 00:00 |
| `netWorthDayFromKey(k)` (24-31) | split, `DateTime(y,m,d)` | `"2026-03-05"` -> 2026-03-05 00:00 |
| `formatNetWorthMonth(d)` (33-36) | `DateFormat('MMMM y')` | "March 2026" |
| `endOfNetWorthMonth(m)` (38-41) | `DateTime(m.year, m.month + 1).subtract(Duration(milliseconds: 1))` | March 2026 -> `2026-03-31 23:59:59.999`; Dec 2026 -> `2026-12-31 23:59:59.999` (month 13 normalises) |
| `endOfNetWorthDay(d)` (43-46) | `DateTime(y, m, d + 1).subtract(Duration(milliseconds: 1))` | 2026-03-08 -> `2026-03-08 23:59:59.999` (VERIFIED in NY, DST day) |

Notes:
- The keys use `DateFormat` with the default locale. `Intl.defaultLocale` is `en_US` in the probe (VERIFIED `Intl.defaultLocale=en_US`); the app never sets `Intl.defaultLocale`/calls `initializeDateFormatting` (grep VERIFIED) and MaterialApp has no localizationsDelegates (main.dart:54-60). INFERRED: keys are therefore always ASCII digits. The port must use fixed POSIX-style formatting for keys (NOT a user-locale DateFormatter); `netWorthMonthFromKey` `int.parse` would crash on localised digits.
- Keys are derived in memory only (`NetWorthSnapshot.monthKey`/`dayKey`, NWE:52-53); they are not stored. `fromJson` also reads a LEGACY `monthKey` field (NWE:73).
- `endOfNetWorthMonth` is "next month 00:00 minus 1 ms", computed in elapsed time. In NY the result for March/Nov (transition months) is still `23:59:59.999` on the last day (VERIFIED for Mar 8/Nov 1 end-of-day; end-of-March printed `2026-03-31 23:59:59.999`).
- Swift note: `endOfNetWorthMonth` maps to "start of next month minus 1 ms". A `.999`-ms sentinel is used as a stored timestamp (see 2.3), so the port must preserve exactly ms precision here.

### 2.2 Snapshot model and (de)serialisation
- `NetWorthSnapshot{recordedAt: DateTime, amount: double}` (NWE:48-105). `toJson`: `{'recordedAt': recordedAt.toIso8601String(), 'amount': amount}` (NWE:101-104).
- `fromJson` (NWE:71-99) fallback ladder:
  1. `recordedAt` non-empty -> `DateTime.parse(recordedAt)` (throws on bad input).
  2. else legacy `monthKey`: `month = netWorthMonthFromKey(key)`; `updatedAt = DateTime.tryParse(legacyUpdatedAt)`; use `updatedAt` only if same year+month as the key, else use `month` (first of month, 00:00).
  3. else `updatedAt` present -> `DateTime.parse`, else `DateTime.now()`.
- `NetWorthEntry`: `createdAt` defaults `DateTime.now()` (NWE:121); `fromJson` requires `createdAt` (NWE:131, `DateTime.parse`); `snapshots` default empty. `createdAt` is never used for lookups.
- ISO precision: Dart prints 3 fractional digits when microsecond == 0 and 6 digits otherwise (VERIFIED: `2026-03-08T01:30:15.123456`, `...15.120`, `...15.000001`, `2026-03-31T23:59:59.999`). `DateTime.now()` on macOS has non-zero microseconds (VERIFIED `2026-09-28T16:59:31.713165`). INFERRED same on iOS.

### 2.3 How snapshots are keyed and looked up

Snapshots are a per-entry list, not a map. No month key is stored. Two lookup styles:

1. **By calendar month (exact bucket)** `snapshotForMonth(month)` (NWE:164-179): among snapshots whose `recordedAt.year == month.year && recordedAt.month == month.month` (local fields), return the one with the latest `recordedAt` (`isAfter`). `hasSnapshotForMonth` = non-null. Used for "was this account updated this month" (`getUpdatedNetWorthEntryCountForMonth`, TM:581-585) and `carryNetWorthMonthForward`.
2. **By instant, carry-forward** `latestSnapshotThrough(date)` (NWE:181-195): among snapshots with `!recordedAt.isAfter(date)` (so `<= date`), the latest. `amountAt(date)` = that amount or null (NWE:197). `amountForMonth(month)` = `amountAt(endOfNetWorthMonth(month))` (NWE:201-203).

**Carry-forward is implicit and unbounded.** Any snapshot from ANY earlier month satisfies `<= endOfMonth`, so an account with a single January snapshot shows its January balance in every later month through today and beyond (VERIFIED by reading; also pinned by test 'carried balances...' which asserts `hasNetWorthDataForMonth(feb)` true and `getUpdatedNetWorthEntryCountForMonth(feb) == 0`). An account has NO value (null -> excluded/0) only in months before its first snapshot.

Model-level use (TM):
- `getNetWorthEntriesForMonth` (TM:483-505): include entry iff `amountForMonth(month) != null`; sort by amount DESC then name lowercased ASC.
- `_sumNetWorthEntriesForMonth` (TM:1326-1330 -> `_sumNetWorthEntriesAtDate`): sum `entry.amountAt(endOfMonth) ?? 0` per type.
- `getNetWorthChangeForMonth` (TM:518-529): null if no entry has a snapshot IN the month (`getUpdatedNetWorthEntryCountForMonth == 0`); null if previous month has no data (`hasNetWorthDataForMonth`); else `netWorth(month) - netWorth(prev)`.
- `getStaleNetWorthEntryCountForMonth` (TM:531-539): entries whose latest snapshot through end of month exists and whose snapshot's `monthKey != netWorthMonthKey(month)` (i.e. carried from an earlier month).
- `getNetWorthAvailableMonths` (TM:553-571): set of month keys = current month key + selected NW month key + every snapshot's month key; parsed back with `netWorthMonthFromKey` and sorted newest first. So future selected months appear; months in between with no snapshot do not.
- `getNetWorthHistory({limit=24})` (TM:541-551 -> `_buildNetWorthHistoryPoints` TM:1361-1420): collects distinct snapshot **day keys** across all entries. Sorts keys descending. Buckets by month. If total points > limit, compresses OLDEST months first (ascending month key) into a single month point (drops `bucket.length - 1` points per compressed month, skipping months with 1 point) until count <= limit. Emits points in bucket-iteration (newest-first) order and finally `.take(limit)`. Day points: `date = midnight of day`, `effectiveDate = endOfNetWorthDay(day)`. Month points: `date = effectiveDate = endOfNetWorthMonth(month)` (23:59:59.999), granularity `month`. Each point's assets/liabilities/counts come from `amountAt(effectiveDate)` across all entries (i.e. carry-forward is applied inside history).
- `_defaultSnapshotDateForMonth(month)` (TM:1441-1449): if `month` is the current calendar month -> `DateTime.now()` (full time and microseconds); otherwise `endOfNetWorthMonth(month)` (`.999`).
- `addNetWorthEntry` / `updateNetWorthEntry` (TM:585-655): effective month = param `month` ?? `_selectedNetWorthMonth`; `recordedAt` param ?? default above. `updateNetWorthEntry` calls `withSnapshot(date, amount)`.
- `withSnapshot` (NWE:209-226): keeps only snapshots whose `recordedAt != new.recordedAt` (removes exact-equal timestamps), appends the new one, sorts ascending by `recordedAt`. Consequence (INFERRED from code, consistent with tests): saving a PAST month twice replaces the same `.999` end-of-month snapshot; saving the CURRENT month again adds a new snapshot each time (new `now` each time), giving multiple same-day/same-month history points (test 'same-month net worth updates create separate history points').
- `deleteNetWorthSnapshot` (TM:657-695): removes snapshots with `recordedAt == given` (exact `DateTime ==`, which compares microsecond instant AND the isUtc flag).
- `carryNetWorthMonthForward(month)` (TM:697-727): for each entry lacking a snapshot IN `month`, take `latestSnapshotThrough(endOfNetWorthMonth(month - 1))`; if found, `withSnapshot(_defaultSnapshotDateForMonth(month), thatAmount)`. Returns true if anything changed. Entries whose first snapshot is later than the previous month end are skipped.
- Legacy migration `_migrateLegacyNetWorthIfNeeded` (TM:1473-1510): creates "Starting Assets"/"Starting Liabilities" entries with a single snapshot at `DateTime.now()`, only when `netWorthEntries` section is empty and legacy prefs > 0.

### 2.4 Swift implications
- Snapshot `recordedAt` needs a lossless round trip (microseconds) or a change of identity for replace/delete. Plan: store as ISO string exactly as read, or compare truncated to ms consistently, but ONLY if the migration guarantees old files remain readable (old data can contain 6-digit fractions).
- `<= endOfMonth` uses `isAfter` on instants; equal instants are included (`!isAfter`). VERIFIED semantics: `a.isAfter(a) == false`.

---------------------------------------------------------------------------------------------------

## 3. Recurring generation (TG, RT, RTM)

### 3.1 Data
`RecurringTransaction` (RT:10-36): `startDate`, `nextOccurrence` (defaults to `startDate`, RT:31/36), `dayOfMonth` (monthly, 1-31), `dayOfWeek` (weekly/biweekly, 1-7 Monday-Sunday, RT:20 comment; sourced from `DateTime.weekday`, RTF:36), `isActive` (default true, JSON default true, RT:70). Pattern enum: `weekly`, `biweekly`, `monthly` serialised as `.name` (RT:45).
JSON dates: `startDate.toIso8601String()`, `nextOccurrence.toIso8601String()` (RT:46-47), parsed with `DateTime.parse` (RT:66-67).

### 3.2 When generation runs (VERIFIED)
- App launch: main.dart:293-297 (`_initializeApp`), after loading models.
- Manual button on Recurring page: recurring_transactions_page.dart:126-131.
- Immediately after ADDING a template (not editing): RTF:686-690, NOT awaited.
- After backup restore: settings_page.dart:472-475.

### 3.3 Algorithm (TG:18-62), VERIFIED read
```
now = DateTime.now()                                   // TG:19
due = recurringModel.getDueRecurringTransactions(now)  // RTM:106-112
for each due template: await _generateMissedTransactions(t, now)
```
`getDueRecurringTransactions(asOf)`: `isActive && (nextOccurrence.isBefore(asOf) || isSameDay(nextOccurrence, asOf))` (RTM:108-110). `isSameDay` compares local year/month/day (RT:181-183). So a nextOccurrence LATER TODAY (e.g. today 23:00 while now is 10:30) counts as due.

```
maxLookback = upTo.subtract(Duration(days: 90))         // TG:34  (upTo = now, keeps time-of-day)
current = t.nextOccurrence
while (current.isBefore(upTo) || isSameDay(current, upTo)):   // TG:38
    if (current.isAfter(maxLookback) || isSameDay(current, maxLookback)):  // TG:40
        addTransaction(type, description, amount, category, current, recurringTemplateId: t.id)  // TG:42-49
    current = _calculateNextOccurrence(t, current)      // TG:53
t' = t.copyWith(nextOccurrence: current); updateRecurringTransaction(t.id, t')   // TG:57-61
```
- Loop upper bound is inclusive by calendar day: an occurrence at 23:00 today, with `now` = 10:30, is generated (VERIFIED sim: `[2026-06-15 23:00]` generated, next = `2026-07-15 00:00`).
- Lower bound is inclusive by calendar day of `maxLookback`: with now = 2026-06-15 10:30, maxLookback = 2026-03-17 10:30. Occurrences on 03-16 23:59 excluded; 03-17 00:00, 03-17 10:29, 03-17 10:30, 03-17 10:31 and later included (VERIFIED, table in b.dart output). In effect the window is "calendar date >= (today - 90 days as elapsed time)".
- Because `maxLookback` uses elapsed 90*24h from a time-of-day timestamp, in DST zones it can land on a different calendar day than `today - 90 calendar days`. VERIFIED (NY): now 2026-03-20 00:30 -> maxLookback `2025-12-19 23:30` (calendar day 19, whereas calendar-90 = Dec 20). So an occurrence on Dec 19 is (wrongly by 1 day) included; similar 1-day shifts exist in London/Sydney/Lord_Howe outputs.
- Occurrences older than the lookback are SKIPPED, not generated, but the cursor still advances through them (loop keeps stepping). The template's `nextOccurrence` ends up strictly after today's calendar day (loop exit means `current` is neither before `upTo` nor same day, i.e. `current` is a later calendar day; VERIFIED sim: next = 2026-07-10 etc.).
- `generateTransaction(current)` (RT:104-113) builds a throwaway `Transaction` (own UUID) only to copy fields; the generator then calls `addTransaction` which builds ANOTHER `Transaction` with a NEW UUID, `createdAt = updatedAt = DateTime.now()` (transaction.dart:34-46), `tagIds` empty. So the persisted generated transaction has `date = current` exactly, `recurringTemplateId = template.id`, `createdAt` = generation time. The generator ignores the `Future<bool>` results of `addTransaction` (TG:42) and `updateRecurringTransaction` (TG:58-61): a failed save is not retried by the generator and the cursor still advances (in memory; the persistence-status banner covers retries per AGENTS.md).
- Persistence of `nextOccurrence`: one `updateRecurringTransaction` call at the END of each template's loop (TG:57-61), which replaces the list element, `notifyListeners()`, and saves the whole `recurringTransactions` section atomically (RTM:22-31, 74-79). Transactions are saved one by one (TM:275-297) BEFORE the cursor update.

### 3.4 Cursor advance: exact arithmetic

Weekly: `from.add(const Duration(days: 7))` (TG:71). Biweekly: `from.add(const Duration(days: 14))` (TG:73). `DateTime.add` adds ELAPSED time, not calendar days. `RT.calculateNextOccurrence` (RT:75-84), `STS._nextOccurrence` (STS:167-186) and RTF preview (RTF:728, 732) use identical math (four copies of the logic: TG, RT, STS, RTF).

Monthly (TG:81-97; identical copies at RT:87-101, RTF:747-761):
```
nextMonth = from.month + 1; nextYear = from.year
if nextMonth > 12: nextMonth = 1; nextYear++
daysInMonth = DateTime(nextYear, nextMonth + 1, 0).day     // day 0 of the following month = last day of nextMonth
actualDay   = dayOfMonth > daysInMonth ? daysInMonth : dayOfMonth
return DateTime(nextYear, nextMonth, actualDay)             // time-of-day reset to 00:00
```
The input `dayOfMonth` is always the TEMPLATE's stored `dayOfMonth` (TG:75), never `from.day`, so the original day is remembered and there is no drift.

Empirical (VERIFIED, `sim.dart`, TZ=America/New_York; monthly cases are TZ independent):
```
dom=31 from Jan 31 2026: 2026-01-31 2026-02-28 2026-03-31 2026-04-30 2026-05-31 2026-06-30 2026-07-31 2026-08-31 2026-09-30 2026-10-31 2026-11-30 2026-12-31 2027-01-31 2027-02-28
dom=30 from Jan 30:      2026-01-30 2026-02-28 2026-03-30 2026-04-30
start Jan 15, dom=31:    2026-01-15 2026-02-28 2026-03-31 2026-04-30      (first occurrence is startDate, NOT dom)
monthly start with time: 2026-01-31 14:32:11.123 -> 2026-02-28 00:00:00.000
```
Out-of-range `dayOfMonth` (only reachable via JSON; backup.dart:215-222 rejects <1 or >31 for monthly on restore): dom=0 -> previous-month-end style result `2026-01-31 00:00` (VERIFIED: `DateTime(2026,2,0)`, day 0 overflow, NOT clamped at low end), dom=-1 -> `2026-01-30`, dom=32 -> `2026-02-28`. Missing `dayOfMonth` on a monthly template crashes (`dayOfMonth!`, TG:75).

Does `DateTime(2026,2,31)` overflow? YES: VERIFIED `DateTime(2026,2,31) => 2026-03-03 00:00:00.000`. The generator avoids this by clamping first (TG:93-94), so it never constructs an overflowing date.

Weekly/biweekly DST behaviour (VERIFIED, NY 2026):
```
DateTime(2026,3,8).add(Duration(days:1))        => 2026-03-09 01:00:00.000    (spring forward day: +24h is +25 wall hours)
DateTime(2026,3,8,12).add(Duration(days:1))     => 2026-03-09 12:00:00.000    (noon starts after the gap, no shift)
DateTime(2026,11,1).add(Duration(days:1))       => 2026-11-01 23:00:00.000    (fall back: still the same calendar day!)
DateTime(2026,3,9).subtract(Duration(days:1))   => 2026-03-07 23:00:00.000
weekly chain from Mar 1 00:00: 03-01 00:00 | 03-08 00:00 | 03-15 01:00 | 03-22 01:00 ...   (permanent +1h until fall)
weekly chain from Oct 25 00:00: 10-25 | 11-01 00:00 | 11-07 23:00 | 11-14 23:00              (previous calendar day!)
```
Generated sequence (sim, weekly from Sun Oct 18 00:00, now Nov 30): `Sun 10-18 00:00 | Sun 10-25 00:00 | Sun 11-01 00:00 | Sat 11-07 23:00 | Sat 11-14 23:00 | Sat 11-21 23:00 | Sat 11-28 23:00`. So in a DST zone weekly midnight templates jump to Saturday 23:00 after fall-back (and a template that falls on the 1st of a month would land in the PREVIOUS month bucket). Biweekly from Mon Feb 23: `02-23 00:00 | 03-09 01:00 | 03-23 01:00 | 04-06 01:00 | 04-20 01:00`.

Other zones (VERIFIED weekly midnight chain):
- UTC, Asia/Tokyo, Asia/Kolkata, America/Sao_Paulo (no DST in 2026): no drift, always 00:00.
- Europe/London: 04-05 01:00 after spring; `10-31 23:00` (Saturday) after fall back on Oct 25.
- Australia/Sydney: DST ends Apr 5 (fall back): `04-11 23:00` (Saturday) onwards; Oct 4 start restores 00:00 chain on Oct 11.
- Australia/Lord_Howe (30-minute shift): `23:30`/`00:30` drift.

Because time-of-day survives weekly steps, a weekly template created from the form default (`startDate = DateTime.now()`, RTF:34) keeps that time-of-day (with microseconds) forever: VERIFIED sim `2026-06-01 14:32:11.123456, 06-08 14:32:11.123456...`. A date-picker-chosen start (RTF:478-485) is midnight. Noon-ish times do not cross the calendar day on DST shift, midnight ones do.

### 3.5 What date/time is stamped on generated transactions
`Transaction.date = current` (the cursor value) verbatim: first occurrence keeps `startDate`'s time-of-day (now-with-time if the form default was used, midnight if picked); weekly/biweekly keep that time (DST-shifted); monthly after the first step is 00:00:00.000. Lists sort by calendar day then `createdAt` (transaction.dart:70-79), so time-of-day mostly matters for month bucketing and CSV/`isAfter` comparisons.

### 3.6 isActive / paused templates
- Generation skips inactive templates entirely (RTM:108, VERIFIED sim: `inactive: 0`, `next stays 2026-06-01`). The cursor does NOT advance while inactive.
- STS skips inactive templates (STS:95).
- There is NO UI to toggle `isActive`: the only references are the model field, JSON, the two filters above, and settings_page.dart:592 (count). `isActive` can only be false via a restored/hand-edited JSON. So "paused" is effectively unreachable in the app UI (VERIFIED grep of `isActive`).
- If a template is ever re-activated after a long pause, the loop walks from the old cursor; occurrences older than 90 days are skipped, newer ones are backfilled.
- Editing a template resets `isActive` to true (see 3.7).

### 3.7 Idempotency and duplicates
Normal case (VERIFIED sim: `rerun: 0`): after a run, `nextOccurrence` is in the future by calendar day, so a second run generates nothing. Dedup by `recurringTemplateId` does not exist (VERIFIED: the field is only written at TG:48/RT:111/TM:290 and read at TM:455 and insights/insight_engine.dart:263 for "recurring change" insights; never used to prevent generation).

Duplicate-creating paths (all INFERRED from code; the edit-reset scenario reproduced in sim):
1. **Template edit resets the cursor.** RTF:658-674 constructs the replacement `RecurringTransaction(id: templateToEdit?.id, ..., startDate: startDate, ...)` without `nextOccurrence`/`isActive`; RT:35-36 sets `nextOccurrence = startDate`. RTM:22-31 replaces the stored template. The next launch/Generate run re-creates everything from `startDate` through today within the 90-day window. Sim: monthly start May 10, first run made `[May 10, Jun 10]`; after simulated edit-reset the re-run produced `[May 10, Jun 10]` again (duplicates).
2. **Crash/kill between transaction saves and cursor save.** Transactions are persisted one at a time (TM:275-297) before the single cursor update (TG:57-61). A termination in between leaves generated rows and an old cursor; the next launch regenerates them.
3. **Overlapping runs.** `generateDueTransactions()` from the add-form is fire-and-forget (RTF:690) and can overlap with the launch run or the manual button; both read the same stale `nextOccurrence` while awaiting saves. Low probability.
4. **Restore from backup** then generate (settings_page.dart:472): cursor is as of export; the intended behaviour, and the test pins it (see section 7).
5. Deleting a generated transaction does NOT cause regeneration (cursor already past it).

Swift recommendation: keep cursor-based generation, but consider (a) preserving `nextOccurrence`/`isActive` on edit unless startDate changed, and (b) committing rows + cursor in one atomic write. That is a behaviour change from Flutter; flag it in the plan.

### 3.8 Safe-to-spend projection (STS:153-186) uses the same cursor arithmetic
`_remainingOccurrences` walks from `nextOccurrence` with `guard < 400`, yields occurrences `isAfter(asOf)` up to `monthEnd`; monthly step uses `recurring.dayOfMonth ?? occurrence.day` with `.clamp(1, lastDay)` (STS:177-184; here a 0 or negative `dayOfMonth` would clamp to 1, unlike the generator). Weekly/biweekly use `Duration(days: 7|14)` like the generator, so the DST drift exists there too. `monthEnd` is 00:00 of the last day (STS:67), so an occurrence on the last day at 01:00 (post-DST-shift or time-of-day) is `isAfter(monthEnd)` and is dropped by the `while (!occurrence.isAfter(monthEnd))` guard (STS:160). VERIFIED by reading; INFERRED impact (only when the last-day occurrence carries a time-of-day).

---------------------------------------------------------------------------------------------------

## 4. Time zone behaviour

- No UTC anywhere in the app (VERIFIED grep: no `toUtc`, `DateTime.utc`, `isUtc`, `.utc` in lib/). Every `DateTime` is created via `DateTime(...)`, `DateTime.now()`, `DateTime.parse/tryParse` of offset-less strings, or a `showDatePicker` result (local midnight).
- Serialisation: `toIso8601String()` of a local DateTime emits no offset (VERIFIED `2026-03-08T01:30:00.000`). Only UTC DateTimes would emit `Z` (VERIFIED `DateTime.utc(...).toIso8601String()` -> `...000Z`); none are created by the app. Files written: transaction `date/createdAt/updatedAt` (transaction.dart:93-97), NW snapshot `recordedAt` and entry `createdAt` (NWE:102, 145), RT `startDate/nextOccurrence` (RT:46-47), goals (savings_goal.dart `targetDate/createdAt/completedAt`), `selectedNetWorthMonth`, store header `writtenAt` (atomic_financial_store.dart:552).
- Parsing offset-less strings yields LOCAL DateTimes with the same wall-clock digits (VERIFIED). So after the user travels (or the device zone changes), all stored dates keep the same wall-clock date/time and therefore the same month/day buckets. What changes is the absolute instant: `millisecondsSinceEpoch`, comparisons against `DateTime.now()` (e.g. `isAfter(now)`, generator due checks, `createdAt` ordering ties), and DST-gap/overlap resolution (below). Nothing is "re-interpreted" into a different calendar day, except in the DST gap/overlap cases.
- DST gap (nonexistent local time), VERIFIED NY:
  - `DateTime.parse('2026-03-08T02:30:00.000')` -> `2026-03-08 03:30:00.000` (shifted forward one hour; the stored string is not rewritten until the model re-saves). Also `DateTime(2026,3,8,2,30)` constructs `03:30`. Same result for `'2026-03-08 02:30:00'`.
  - `'2026-03-08T24:00:00'` -> `2026-03-09 00:00:00.000` (Dart accepts hour 24 as next day).
- DST overlap (ambiguous), VERIFIED NY:
  - `DateTime.parse('2026-11-01T01:30:00.000')` -> `2026-11-01 01:30:00.000` with offset `-4:00` (the FIRST/EDT occurrence).
  - The SECOND occurrence (01:30 EST, instant `06:30Z`) prints `2026-11-01T01:30:00.000` too, and `DateTime.parse(iso)` of it returns the FIRST instant: `parse(iso)==original` is `true` for the first instant and `false` for the second. So a timestamp created during the repeated hour does not round-trip; it moves back 1 hour of real time. Only matters for ordering `createdAt` ties and NW snapshot `==` matching (rare, once per year, 1 hour).
- Dates with explicit offsets (only possible from external input such as CSV/JSON/LLM text): `DateTime.parse('2026-03-08T02:30:00.000Z')` -> UTC DateTime (`isUtc=true`), `'...-05:00'` -> converted to UTC (`2026-03-08 07:30:00.000Z`). VERIFIED. A UTC DateTime read into a model would bucket by its UTC `.year/.month/.day` and re-serialise with `Z`. No app code guards against this. `Transaction.fromJson` (transaction.dart:102) uses `DateTime.parse(json['date'])`, so a backup with `Z` dates would produce UTC transactions. INFERRED risk, not seen in files the app writes.
- `writtenAt` is local wall-clock ISO with microseconds, informational.

---------------------------------------------------------------------------------------------------

## 5. Dart `DateTime` vs Swift `Date`/`Calendar`: divergences that matter

Everything marked VERIFIED was executed (NY unless noted).

### 5.1 Model
- Dart `DateTime` is a value with (instant, isUtc flag). Fields `.year/.month/.day/.hour` are computed in the local zone (or UTC if `isUtc`). Equality `==` compares instant AND isUtc: `DateTime(2026,3,8,12) == DateTime.utc(2026,3,8,12)` is `false`; `a == a.toUtc()` is `false` even for the same moment; `isAtSameMomentAs` is `true`; `compareTo` returns 0 (VERIFIED). `isBefore/isAfter` compare instants and are strict: `a.isAfter(a) == false`, `a.isBefore(a.toUtc()) == false` (VERIFIED).
- Swift `Date` is an absolute instant (Double seconds, sub-microsecond). No local/UTC flag; field extraction is via `Calendar`+`TimeZone`. Store local wall-clock strings and reconstruct with `Calendar.current` at read time.

### 5.2 Constructor overflow / underflow (lenient normalisation)
`DateTime(y, m, d, h, ...)` normalises out-of-range components (VERIFIED):
- `DateTime(2026,2,31)` -> `2026-03-03`
- `DateTime(2026,1,0)` -> `2025-12-31` (day 0 = last day of previous month)
- `DateTime(2026,13,1)` -> `2027-01-01`; `DateTime(2026,0,1)` -> `2025-12-01`; `DateTime(2026,-1,1)` -> `2025-11-01`
- `DateTime(2026,3,0).day` -> 28; `DateTime(2024,3,0).day` -> 29; `DateTime(2026,13,0)` -> `2026-12-31`
- `DateTime(2026,1,1,25)` -> `2026-01-02 01:00`
Everything in section 1.1 relies on this (`month - 1`, `month + 1`, day 0). In Swift, `DateComponents` with invalid values can return nil/`Date` from `Calendar.date(from:)` for out-of-range day in strict cases (INFERRED: Foundation `Calendar.date(from:)` is lenient for months/days by default, but the port should use explicit `Calendar.date(byAdding: .month, ...)` and `range(of: .day, in: .month, for:)` and not rely on overflow). Also `DateTime(99,1,1)` gives year 0099, not 1999 (VERIFIED); `DateFormat('yyyy-MM-dd').format(DateTime(12345,3,5))` -> `12345-03-05`.
- `netWorthMonthFromKey('2026-13')` would silently be 2027-01; a Swift port must decide whether to validate.
- CSV import parses with `DateTime.tryParse` (TM:1087) then guards against overflow with a round-trip text check (TM:1088-1093): `'2026-02-30'` -> parsed as `2026-03-02` (VERIFIED), then rejected because `'2026-02-30'.startsWith('2026-03-02')` is false. Note the check is `startsWith`, so `'2026-03-08T02:30:00'` and `'2026-03-08 anything'` pass. `DateTime.tryParse(' 2026-03-08')` (leading space) -> null; `'2026-3-8'` -> null; `'20260308'` -> valid (VERIFIED). The CSV path trims first (TM:1086).

### 5.3 Duration arithmetic and calendar days
- `DateTime.add/subtract(Duration(days: n))` = n*24h elapsed (VERIFIED, 3.4). Swift `Date.addingTimeInterval(86400*n)` behaves the same; `Calendar.date(byAdding: .day, value: n, to:)` does NOT (keeps wall-clock time). To reproduce Flutter exactly use TimeInterval math; to fix, use Calendar.
- Sites using `Duration(days:)`: TG:34, 71, 73; STS:173, 175, 190; RTF:115, 483-485, 506-507, 728, 732; local_insights_section.dart:23, 82 (30-day snooze); app_privacy_gate.dart:65-78 (elapsed time); main.dart:401 (deep link dedupe window).
- `subtract(Duration(milliseconds: 1))` is used for end-of-month/day (NWE:38-46). VERIFIED results at NY transition boundaries were still `23:59:59.999` of the intended day.
- `difference()` returns elapsed `Duration`; `.inDays` truncates toward zero (VERIFIED: `Duration(hours: 36).inDays == 1`, `Duration(hours: -36).inDays == -1`, `Duration(hours: -23).inDays == 0`).
  - DST off-by-one, VERIFIED NY: `DateTime(2026,3,15).difference(DateTime(2026,3,1))` = `335:00:00` -> `inDays == 13` (should be 14). `DateTime(2026,11,15).difference(DateTime(2026,11,1))` = `337:00:00` -> `inDays == 14` (fall back adds an hour, truncation hides it). `DateTime(2026,3,31).difference(DateTime(2026,3,8)).inDays == 22` (calendar days = 23). Same pattern in Sydney (`Oct 10 - Sep 26 = 13`) and London (`Apr 12 - Mar 29 = 13`).
  - Call sites: savings_goal.dart:64 (`daysRemaining`), STS:131-138 (`daysRemaining = monthEnd.difference(midnight(asOf)).inDays + 1` -> one day short when a spring-forward falls between asOf and month end, i.e. asOf on/before Mar 8 in the US), insights/insight_engine.dart:340-341 (`targetDate.difference(createdAt).inDays`, `today.difference(createdAt).inDays`; createdAt carries time-of-day, so results are effectively floors of elapsed 24h periods), savings_goals_page.dart:256-262 (uses milliseconds ratio for a progress bar, unaffected).
  - Swift: `Calendar.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day` gives calendar-day counts (DST safe). Parity vs bug-compat is a decision; test expectations at safe_to_spend_test.dart pin `daysRemaining == 17` for Jul 15 -> Jul 31 (no DST in July, so both approaches agree there).

### 5.4 Parsing and formatting
- `DateTime.parse` of strings without offset -> LOCAL wall-clock (VERIFIED). With `Z` or `+hh:mm` -> UTC DateTime. Accepts `T` or space separator, date-only, `yyyyMMdd`, hour 24; rejects leading whitespace and non-padded `2026-3-8` (VERIFIED). Fractional seconds beyond 6 digits are truncated (VERIFIED `.1234567` -> `.123456`). Swift `ISO8601DateFormatter` requires a timezone designator unless configured with `.withInternetDateTime` off and uses different option sets; it does not accept 6 fractional digits with `.withFractionalSeconds` (ms only in practice). Plan a custom parser (or `DateFormatter` with `en_US_POSIX`, local tz) for offset-less strings with 3 or 6 fractional digits; test against real store files.
- `toIso8601String()`: local -> `yyyy-MM-ddTHH:mm:ss.SSS` when microsecond == 0, `.SSSSSS` otherwise; UTC adds `Z` (VERIFIED). Swift needs custom formatting to reproduce (3 vs 6 digits) if files must remain byte-compatible; round-trip compatibility matters more than byte equality.
- `DateFormat` outputs (en_US, VERIFIED): `yMMMd` -> `Mar 5, 2026`; `MMMd` -> `Mar 5`; `yMMMM` -> `March 2026`; `'MMMM y'` -> `March 2026`; `"MMM ''yy"` -> `Mar '26`; `jm` -> `2:05 PM` where the space before PM is U+202F (VERIFIED codepoints `32 3a 30 35 202f 50 4d`); `yMMMd().add_jm()` -> `Mar 5, 2026 2:05 PM` (U+202F); `'MMM dd, yyyy'` -> `Mar 05, 2026`; `'EEEE, MMM dd, yyyy'` -> `Thursday, Mar 05, 2026`; `'yyyyMMdd_HHmmss'` -> `20260305_140509`.

### 5.5 Weekday numbering
Dart `DateTime.weekday`: Monday=1 ... Sunday=7 (VERIFIED: 2026-03-08 Sunday -> 7, 2026-03-09 Monday -> 1; constants `DateTime.monday==1`, `sunday==7`). `RecurringTransaction.dayOfWeek` stores that value (RTF:36, 435; RT:20). Foundation `Calendar.component(.weekday)` is Sunday=1 ... Saturday=7. If the port ever reads/writes `dayOfWeek`: `dart = (swift + 5) % 7 + 1`; `swift = dart % 7 + 1`. JSON compatibility requires the Dart numbering. (No code uses `dayOfWeek` for computation, 3.4.) The recurring-form day picker uses `dayOfWeek - 1` as a list index (RTF:430) with `_getDaysOfWeek()` (RTF:776-786, VERIFIED Monday-first order Monday..Sunday).

### 5.6 Other
- Microseconds: Dart carries microsecond precision; `DateTime.now()` has non-zero microseconds (VERIFIED). `updateTransaction` bumps `updatedAt` by `Duration(microseconds: 1)` when `now` is not after the existing value (TM:458-460), so the port needs microsecond-capable timestamps or a different tie-break.
- Same-instant tie-breaks: `Transaction.compareNewestFirst` uses local calendar day, then `createdAt`, then `id` (transaction.dart:70-76, 78-79).
- Sorting uses `compareTo` on instants: `withSnapshot` sorts by `recordedAt` (NWE:223), CSV export sorts by `date` (TM:1006-1007 region), history/insights by `date`.
- `DateTime.now()` is captured repeatedly and independently in one build pass (e.g. TM:154 default, TM:554). Not an issue functionally.
- Year handling: `DateTime(year)` with year < 100 is year 0-99, not 19xx/20xx (VERIFIED).
- `DateTime(2018,11,4)` in America/Sao_Paulo (midnight doesn't exist) -> `2018-11-04 01:00` (VERIFIED), day preserved. Not relevant for 2026 but relevant for historical data in such zones. `Calendar.startOfDay` in Swift returns the first valid moment of the day similarly.

---------------------------------------------------------------------------------------------------

## 6. Empirical runs (raw outputs, all `TZ=America/New_York` unless noted)

```
DateTime(2026,2,31)                         => 2026-03-03 00:00:00.000
DateTime(2026,1,0)                          => 2025-12-31 00:00:00.000
DateTime(2026,13,1)                         => 2027-01-01 00:00:00.000
DateTime(2026,0,1)                          => 2025-12-01 00:00:00.000
DateTime(2026,-1,1)                         => 2025-11-01 00:00:00.000
DateTime(2026,3,0).day / DateTime(2024,3,0).day => 28 / 29
DateTime(2026,3,8).add(Duration(days:1))    => 2026-03-09 01:00:00.000
DateTime(2026,3,8,12).add(Duration(days:1)) => 2026-03-09 12:00:00.000
DateTime(2026,3,1,9,30).add(Duration(days:14)) => 2026-03-15 10:30:00.000
DateTime(2026,10,28,12).add(Duration(days:7)) => 2026-11-04 11:00:00.000
DateTime(2026,11,1).add(Duration(days:1))   => 2026-11-01 23:00:00.000
DateTime(2026,11,1).subtract(Duration(days:1)) => 2026-10-31 00:00:00.000
DateTime(2026,3,9).subtract(Duration(days:1))  => 2026-03-07 23:00:00.000
DateTime(2026,3,15).difference(DateTime(2026,3,1)) => 335:00:00.000000  inDays=13
DateTime(2026,11,15).difference(DateTime(2026,11,1)) => 337:00:00.000000 inDays=14
DateTime(2026,3,31).difference(DateTime(2026,3,8)).inDays => 22
toIso8601String: local 2026-03-08T01:30:00.000 | micros 2026-03-08T01:30:15.123456 | utc 2026-03-08T01:30:00.000Z | now 2026-09-28T16:59:31.713165
DateTime.parse('2026-03-08T02:30:00.000')   => 2026-03-08 03:30:00.000 (offset -4:00)  [gap shifted forward]
DateTime.parse('2026-03-08T03:30:00.000')   => 2026-03-08 03:30:00.000 (same instant as above)
DateTime.parse('2026-11-01T01:30:00.000')   => 2026-11-01 01:30:00.000 (offset -4:00, first occurrence)
DateTime.parse('2026-03-08')                => 2026-03-08 00:00:00.000 (offset -5:00)
DateTime.parse('...Z') / '...-05:00'        => UTC DateTime (isUtc=true)
DateTime.parse('2026-02-30')                => 2026-03-02 00:00:00.000
DateTime.parse('2026-13-01')                => 2027-01-01 00:00:00.000
DateTime.tryParse(' 2026-03-08') / '2026-3-8' => null
ambiguous 01:30 second instant: iso identical, parse(iso) returns FIRST instant (roundtrip equal: true / false)
weekday 2026-03-08 (Sun)=7, 2026-03-09 (Mon)=1
local==utc same wall: false; isBefore equal instant: false; a==a.toUtc(): false; isAtSameMomentAs: true; compareTo: 0
Duration(hours:-36).inDays=-1; Duration(hours:36).inDays=1; Duration(hours:-23).inDays=0
```
Generator simulation (`sim.dart`, verbatim copies of TG:65-97 and TG:29-62 loop) outputs are quoted in 3.3, 3.4, 3.7.

---------------------------------------------------------------------------------------------------

## 7. Tests: date behaviours currently pinned

### 7.1 test/recurring_transaction_test.dart (VERIFIED read; pure model tests, no generator)
- 'calculate next weekly occurrence': `nextOccurrence(2024-01-01).calculateNextOccurrence() == DateTime(2024,1,8)` (test:56-70). NOTE: run in the test host's zone; midnight to midnight across a January week has no DST, so it does not exercise the drift.
- Biweekly: `2024-01-01 -> 2024-01-15` (72-86).
- Monthly: `2024-01-15 -> 2024-02-15` (88-102).
- Day 31 into February of a leap year: `2024-01-31 (dom 31) -> 2024-02-29` (104-119). No non-leap test, no follow-up month test, no drift test.
- Year boundary: `2024-12-15 -> 2025-01-15` (121-135).
- JSON round trip preserves `startDate`, `nextOccurrence` (DateTime equality on midnight values), `dayOfMonth`, `isActive` (28-54); `isActive` defaults to true (7-26).
- `generateTransaction(DateTime(2024,2,1)).date == DateTime(2024,2,1)` and copies `recurringTemplateId = recurring.id` (137-156).
- NOT covered: generator loop, 90-day lookback boundaries, DST, monthly with `startDate.day != dayOfMonth`, edit-reset, `isActive=false`, dedup.

### 7.2 Other tests touching recurrence dates
- test/recurring_transaction_model_backup_restore_test.dart:70-110 (VERIFIED read): with `today = midnight(now)`, weekly template with `startDate = nextOccurrence = today - 10 days`; after `generateDueTransactions()` expects exactly 2 generated transactions (day -10 and day -3), all with `recurringTemplateId == 'rec-restored'`, and template `nextOccurrence.isAfter(now)`. Uses real `DateTime.now()`, so it is only stable while no DST transition falls in the 10-day window in the runner's zone (INFERRED: could flake in DST zones; would still produce 2 rows, but the `isAfter(now)` assertion holds because next is a future calendar day).
- test/backup_test.dart:406 area: comment states generator dereferences `dayOfMonth` for monthly templates (validation test; not a date arithmetic pin).
- test/safe_to_spend_test.dart: month 2026-07, asOf 2026-07-15; monthly templates on 07-20 and 07-22 count as upcoming; `daysRemaining == 17`; future-dated (07-25) transactions are not actual; passes `dayOfWeek: DateTime.monday` (unused by the calculator).
- test/transaction_ordering_test.dart: same-day ordering uses calendar day first, then `createdAt`; `23:30` yesterday sorts below midnight today; equal timestamps break by id.

### 7.3 test/transaction_model_net_worth_test.dart (VERIFIED read)
- 'manual asset and liability balances': `selectMonth(2026-03)` + NW month March; entries added with `month: March` (default snapshot date = end of March, `.999`, since March 2026 is not the current month) give `totalAssets 1000`, `totalLiabilities 400`, `netWorth 600`; transactions dated 2026-03-15/16 fall into the selected month (`totalIncome 250`, `totalExpenses 100`).
- 'monthly balances can be carried forward': January `.999` snapshots carried to February via `carryNetWorthMonthForward(feb)` (returns true), manual mortgage update in February to 149500 -> `getTotalAssetsForMonth(feb) 200000`, liabilities 149500, net 50500, tracked count 2, updated count 2, stale count 0.
- 'available months stay newest-first when an older month is selected': uses `DateTime.now()`; expects exactly `[current, previous, older]` (each `DateTime(y, m - k)`), proving month underflow normalisation and that current month is always included plus selected NW month plus snapshot months.
- 'carried balances do not create synthetic month-end history points': one snapshot at 2026-01-20 09:00; selecting February gives `hasNetWorthDataForMonth(feb)==true`, `getUpdatedNetWorthEntryCountForMonth(feb)==0`, history has exactly 1 point with `date == DateTime(2026,1,20)` (midnight day key), `netWorth 5000`, and `getNetWorthChangeForMonth(feb) == null`.
- 'monthly change uses recorded balances from the previous month': June 200000 (06-20 09:00), July 210000 (07-20 09:00) -> change for July = 10000.
- 'same-month updates create separate history points': snapshots 03-10 09:00 and 03-25 17:00 -> history dates `[2026-03-25, 2026-03-10]` (newest first, midnight), net `[1400, 1000]`, counts `[1,1]`/`[0,0]`, granularity `day`; `getNetWorthForMonth(march) == 1400`.
- 'older daily points compress into monthly snapshots when history is crowded': snapshots 01-02, 01-10, 01-20, 02-05, 02-18, 03-08 (all 09:00) with `limit: 4` -> 4 points: `2026-03-08` (day), `2026-02-18` (day), `2026-02-05` (day), `DateTime(2026,1,31,23,59,59,999)` (month granularity, net 1200 = value as of 01-20). Pins the oldest-first compression rule and the `.999` month-point date.
- 'individual net worth snapshots can be deleted': deleting by exact `recordedAt` (2026-03-01 09:00) leaves 1500 (pins exact `DateTime ==` deletion; the test uses whole-second values).
- 'legacy baseline values migrate into tracked accounts': prefs `starting_assets 3200`, `starting_liabilities 900` -> two entries; created at `DateTime.now()` so they count in the current month; note `model.totalAssets` uses the initial `_selectedNetWorthMonth` (current month) here.

### 7.4 Untested date areas (port risk)
Generator DST behaviour, 90-day boundaries, edit-reset duplicates, `netWorthMonthFromKey` malformed input, legacy snapshot decoding (`monthKey`/`updatedAt`), 6-digit microsecond round trips, CSV date guards beyond what test/transaction_model_csv_import_test.dart covers (not analysed here), `daysRemaining` in DST months, travel/zone change.

---------------------------------------------------------------------------------------------------

## 8. Port checklist (date-specific)

1. Choose bug-compat vs fix for: (a) weekly/biweekly `+168h/+336h` DST drift (3.4), (b) `daysRemaining` DST truncation (5.3), (c) edit-reset duplicate generation (3.7). Recommendation: fix (a) and (b) with Calendar day arithmetic, but record the decision; generated dates on non-DST zones are identical either way.
2. Parse/format persisted dates with a custom local-time ISO handler supporting 3 or 6 fractional digits and optional `Z`/offset (treat as UTC then convert); preserve microseconds for `recordedAt`, `createdAt`, `updatedAt`.
3. Use fixed-locale formatting for `yyyy-MM`/`yyyy-MM-dd` keys and CSV dates; user-locale only for display.
4. Keep the exact end-of-month sentinel (`next month start - 1 ms`) and the `<=` (not `<`) instant comparison for carry-forward.
5. `dayOfWeek`: keep the Dart 1=Monday..7=Sunday encoding in JSON.
6. Inject a clock everywhere `DateTime.now()` is used; the generator is currently non-injectable.
7. `selectedMonth` starts as the current month, not persisted; `selectedNetWorthMonth` persisted as first-of-month ISO string.
8. Do not rely on Swift `Calendar.date(from:)` overflow tolerance; write explicit month-add and last-day-of-month helpers matching sections 1.1/3.4.
