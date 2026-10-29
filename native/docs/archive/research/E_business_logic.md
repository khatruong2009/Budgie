> Archived; paths refer to the `flutter-final` tag.

# E. Business logic (Flutter source of truth for the SwiftUI port)

All paths are relative to `budget_app/` unless prefixed. "VERIFIED" = read in source, or reproduced by running the real Dart code (scratch scripts run with `dart --packages=budget_app/.dart_tool/package_config.json`, TZ=America/New_York and UTC). "INFERRED" = follows from code but not executed or depends on stored data / runtime I could not observe.

Global facts that every section depends on:

- Money is `double` everywhere; nothing is rounded on storage, on summation, or in the totals (VERIFIED: `lib/transaction.dart:14`, `lib/transaction_model.dart:213-222`). Rounding happens only at display (intl) and at CSV export (`toStringAsFixed(2)`), and those two round DIFFERENTLY (see 6.4).
- Dates are naive local `DateTime` (no zone stored; `toIso8601String()` on a local value has no offset) (VERIFIED: `lib/transaction.dart:93`). A "day" is the device-local calendar day at evaluation time.
- Transactions created through the form carry a time-of-day: `DateTime selectedDate = DateTime.now();` (`lib/transaction_form.dart:41`), save passes it unchanged (`:464`, `:484`). Picking a date via the picker yields midnight (`:390-397`). Recurring-generated rows and voice rows are midnight (`lib/transaction_generator.dart:41`; comment at `lib/transaction.dart:66-69`). So a ledger has mixed midnight / non-midnight timestamps. This matters for section 1.

---

## 1. Safe-to-spend

Source: `lib/safe_to_spend.dart` (whole file, 200 lines). Caller: `lib/spending_page.dart:462-469`. UI: card `lib/spending_page.dart:1222-1328`, sheet `:362-446`, footer `:350-360`. Tests: `test/safe_to_spend_test.dart`.

### 1.1 Inputs (VERIFIED `spending_page.dart:462-469`)

```
calculate(
  transactions:          transactionModel.transactions            // ALL transactions, list order
  recurringTransactions: recurringModel.recurringTransactions     // ALL templates
  categoryBudgetLimits:  transactionModel.categoryBudgetLimits    // Map<String,double>, insertion order
  savingsGoals:          transactionModel.savingsGoals
  month:                 DateTime(selectedMonth.year, selectedMonth.month)   // the month chosen on the Spending tab pill, NOT necessarily today's month
  asOf:                  DateTime.now()
  includeExpectedIncome: true (default, never overridden in lib/)
  reserveSuggestedGoalContributions: true (default)
)
```

`selectedMonth` starts as `DateTime.now()` (`transaction_model.dart:152`) and changes with `selectMonth` (`:231-234`). It is not persisted (only `selectedNetWorthMonth` is).

### 1.2 Formula (VERIFIED `safe_to_spend.dart:29-49`, `:66-150`)

```
normalizedMonth = DateTime(month.year, month.month)             // 1st, 00:00 local
monthEnd        = DateTime(month.year, month.month + 1, 0)      // last day, 00:00 local (NOT end of day)
effectiveAsOf   = clampDate(asOf, normalizedMonth, monthEnd)

clampDate(v, start, end):                                       // :188-193
   date = DateTime(v.y, v.m, v.d)                               // strips time
   if date <  start -> start - 1 day     (day before the month)
   if date >  end   -> end
   else date

actualIncome / actualExpenses / actualCategoryExpenses[cat]:    // :74-89
   for t in transactions (list order):
      skip if t.date not in (year,month) of normalizedMonth  OR  t.date.isAfter(effectiveAsOf)
      income  -> actualIncome  += amount
      expense -> actualExpenses += amount; actualCategoryExpenses[t.category] += amount

expectedIncome / upcomingRecurringExpenses / upcomingByCategory: // :91-110
   for r in recurringTransactions where r.isActive:
      for occ in remainingOccurrences(r, effectiveAsOf, monthEnd) where occ in month:
         income  -> expectedIncome += r.amount               (only if includeExpectedIncome)
         expense -> upcomingRecurringExpenses += r.amount; upcomingByCategory[r.category] += r.amount

remainingOccurrences(r, asOf, monthEnd):                        // :153-165
   occ = r.nextOccurrence; guard = 0
   while !occ.isAfter(monthEnd) && guard < 400:
      if occ.isAfter(asOf): yield occ
      occ = next(r, occ); guard++
   next: weekly  -> occ.add(Duration(days: 7))     (168 hours, NOT calendar days)
         biweekly-> occ.add(Duration(days: 14))
         monthly -> day = r.dayOfMonth ?? occ.day; DateTime(nextMonth.y, nextMonth.m, clamp(day, 1, lastDayOfNextMonth))   // midnight

flexibleBudgetReserve:                                          // :112-119
   for (cat, limit) in categoryBudgetLimits (map order):
      if limit <= 0: continue
      remaining = limit - (actualCategoryExpenses[cat] ?? 0) - (upcomingByCategory[cat] ?? 0)
      if remaining > 0: flexibleBudgetReserve += remaining

plannedGoalContributions:                                       // :121-129
   if reserveSuggestedGoalContributions && !isBeforeMonth(normalizedMonth, DateTime(asOf.year, asOf.month)):
      for g in savingsGoals where !g.isCompleted: += g.suggestedMonthlyContribution

daysRemaining:                                                  // :131-138
   if asOf is in month : monthEnd.difference(DateTime(asOf.y, asOf.m, asOf.d)).inDays + 1
   else if asOf < month : monthEnd.day          (whole month; e.g. future month)
   else                 : 0                     (past month)

projectedIncome  = actualIncome + expectedIncome
totalReserved    = upcomingRecurringExpenses + flexibleBudgetReserve + plannedGoalContributions
safeToSpend      = projectedIncome - actualExpenses - totalReserved     (may be negative; no floor, no rounding)
isOverCommitted  = safeToSpend < 0
overCommitment   = isOverCommitted ? -safeToSpend : 0
dailyAllowance   = (daysRemaining <= 0 || safeToSpend <= 0) ? 0 : safeToSpend / daysRemaining
```

`SavingsGoal.suggestedMonthlyContribution` (`lib/savings_goal.dart:67-79`): 0 if completed or remaining<=0; else `monthsRemaining = (target.year-now.year)*12 + target.month - now.month + 1` using the CURRENT clock (not asOf); if `monthsRemaining <= 1` returns `remainingAmount`, else `remainingAmount / monthsRemaining` (note: a past-due goal has monthsRemaining <= 1 so its whole remaining amount is reserved). `isCompleted = targetAmount > 0 && currentAmount >= targetAmount` (`:49`), `remainingAmount = max(target-current, 0)` (`:44-47`). VERIFIED.

### 1.3 Answers to the specific questions

- Does today count in days remaining? YES. `+1` includes the asOf day (VERIFIED, test `safe_to_spend_test.dart:63`: asOf Jul 15 -> 17 days; Jul 31 -> 1 day, reproduced).
- Current month only? No. Any selected month works. Past month: `daysRemaining = 0`, all in-month transactions are "actual" (subject to the midnight quirk below), no upcoming recurring (nothing is after monthEnd), goals NOT reserved (month is before asOf's month). Future month: `effectiveAsOf` = day before the month, so ZERO actuals, all recurring occurrences in that month reserved, goals reserved, `daysRemaining = monthEnd.day` (reproduced: Sept 2026 -> 30). VERIFIED.
- Which transactions count as actual? Same year+month as `month` AND `date <= effectiveAsOf` (future-dated rows excluded; test `:130-149`). Income and expense only; the transaction's `recurringTemplateId` is irrelevant.
- Recurring upcoming? Only ACTIVE templates; only occurrences strictly AFTER `effectiveAsOf` (an occurrence dated exactly today at 00:00 is NOT upcoming; it is presumed already generated as a real transaction) and on/before `monthEnd` and inside the month. Expected income counted the same way. Expenses feed `upcomingByCategory`, which reduces the flexible budget reserve so a category is not double counted.
- Budgets: only limits > 0; reserve is the unspent remainder floored at 0 PER CATEGORY, summed. Uncategorised-budget spending is not reserved. The loop iterates ALL stored limits, including categories no longer in `expenseCategories` (the Spending tab only lists categories in `expenseCategories`, `spending_page.dart:112-124`, so a stale limit is invisible in the UI but still reserved). VERIFIED by reading; the mismatch is INFERRED to be reachable after a category rename/archive.
- No income: `projectedIncome = 0` -> `safeToSpend = -(actualExpenses + reserved)` <= 0 -> over-committed if anything is spent/reserved; if everything is 0 then safeToSpend = 0, `isOverCommitted=false`, allowance 0, card shows "Safe to spend $0". VERIFIED.
- End of month: on the last day `daysRemaining = 1`. Never shows "closed out" for the current month; "closed out" is only for past months (`days <= 0`).
- Rounding: NONE inside the calculator; all doubles. Display rounding is `MoneyFormatter` (0 decimals on the card, 2 in the sheet).

### 1.4 Display rules (VERIFIED `spending_page.dart`)

Card (`:1232-1255`): title `isOver ? 'Projected shortfall' : 'Safe to spend'`; amount `MoneyFormatter.format(isOver ? overCommitment : safeToSpend, decimalDigits: 0)`. Subtitle: `days <= 0` -> `'This month is already closed out'`; else `isOver` -> `'Add income or reduce planned spending'`; else `'<format(dailyAllowance, 0dp)>/day for <N days left|1 day left>'`. Note `0 <= safeToSpend` includes exactly 0 -> "Safe to spend $0 ... $0/day".

Sheet (`:362-446`): rows in order, with `positive` flag deciding sign shown via `MoneyFormatter.formatSigned(displayValue, plusForPositive: positive && !emphasized)` (`:1348`, `:1366-1369`): 
- "Income recorded" +actualIncome (positive -> `+$x`)
- "Income still expected" +expectedIncome
- "Expenses recorded" -actualExpenses (shown as `-$x`; a zero shows `$0.00`, no sign because `value < 0` is false for `-0.0`)
- "Upcoming recurring bills" -upcomingRecurringExpenses
- "Flexible budget reserve" -flexibleBudgetReserve
- "Suggested goal contributions" -plannedGoalContributions
- divider, then emphasized row `isOver ? 'Projected shortfall' : 'Safe to spend'` with value `isOver ? overCommitment : safeToSpend`, `positive: true`, `emphasized: true` (so NO `+`).
Footer (`:350-360`): `days <= 0` -> `'This month is already closed out.'`; over -> `'Add income or reduce planned spending to close the shortfall · <N days remaining|1 day remaining>'`; else `'<format(dailyAllowance) 2dp> per day · <N days remaining|1 day remaining>'`.
Sheet subtitle strings: `:388-396`.

### 1.5 PARITY HAZARDS in safe-to-spend (all reproduced by running the Dart calculator)

1. **Same-day timestamps are silently dropped from actuals.** `transaction.date.isAfter(effectiveAsOf)` compares against a MIDNIGHT `effectiveAsOf`. A transaction dated today with any time-of-day (the form default, `transaction_form.dart:41`) is "after" and is excluded. Reproduced: asOf 2026-07-15 10:30, expenses at Jul 15 00:00 (10), Jul 15 09:00 (20), Jul 14 23:59 (40) -> `actualExpenses = 50` (the 09:00 row is dropped). Same for a past month: a row on the last day at 12:00 is dropped (`actualExpenses = 0`). The Spending-tab monthly totals (`totalIncome/Expenses`) DO include those rows, so the tab is internally inconsistent. The native port must decide: replicate (bit-identical) or fix (compare by calendar day). I recommend fixing with a documented divergence, but that is the caller's call.
2. **DST off-by-one in `daysRemaining`.** `monthEnd.difference(midnight(asOf)).inDays` counts elapsed 24h units. In a spring-forward month before the switch, `inDays` truncates: TZ=America/New_York, asOf Mar 1 -> 30 (calendar answer 31); Mar 8 -> 23 (24); Mar 9 -> 23. UTC gives 31/24/23. Fall-back months are fine (Nov 1 -> 30). To replicate in Swift use `end.timeIntervalSince(startOfDay) / 86400` truncated, in the device time zone; `Calendar.dateComponents([.day])` will differ.
3. **Weekly/biweekly recurrence drifts across DST** because it adds 168/336 hours (`safe_to_spend.dart:173-175`, same in `transaction_generator.dart:71` and `recurring_transaction.dart:78-80`). America/New_York from 2026-02-22 00:00: `... 03-08 00:00, 03-15 01:00, 03-22 01:00 ...`; from 2026-10-25: `11-01 00:00, 11-07 23:00, 11-14 23:00`. Consequences: (a) an occurrence on the last day at 01:00 is `isAfter(monthEnd)` (midnight) and drops out of the month; (b) after fall-back the date itself shifts to the previous day. Replicate with `Date.addingTimeInterval(7*86400)`, not `Calendar.date(byAdding:.day)`.
4. `nextOccurrence` may carry a time-of-day if the user accepted the default start date (`recurring_transaction_form.dart:34` `startDate = DateTime.now()`); same-day-at-time occurrence counts as upcoming (`isAfter(midnight asOf)`) while the generator will also turn it into a real transaction on next launch (`isSameDay`). INFERRED (depends on stored data).
5. Goal reserve uses the wall clock (`savings_goal.dart:72`), not `asOf`; so unit tests with a fixed `asOf` are clock-dependent for goals.
6. Sum order: actuals are summed in `transactions` list order; reserve in `categoryBudgetLimits` insertion order (map decoded from the JSON section, `transaction_model.dart:413-417`). Doubles are not associative; keep the same order to get bit-identical sums.
7. `guard < 400` loop cap (weekly from a `nextOccurrence` > ~7.7 years earlier stops before reaching the month). Edge case only.

---

## 2. Insights engine (out of MVP; summary)

Source: `lib/insights/insight_engine.dart`; UI `lib/widgets/local_insights_section.dart`; shown on the Cash Flow (History) tab (`lib/history_page.dart:80`). Test: `test/insight_engine_test.dart`. Pure function of (transactions, budget limits, goals, selectedMonth, now, excludedIds, limit=3). VERIFIED.

Candidates are concatenated in this order (`:60-89`), then filtered by `excludedIds`, sorted by severity (urgent 0, warning 1, positive 2, info 3) then `id` ascending (string compare), and `take(3)` (`:91-103`).

| Type (enum `:4-14`) | Rule (lines) | Severity | id |
|---|---|---|---|
| possibleDuplicate (`:390-422`) | in selected month, same `type + slug(description) + amount.toStringAsFixed(2) + midnight ISO date`; every 2nd+ occurrence emits one | warning | `duplicate:<key>` |
| budgetPace (`:106-145`) | only if selected month == now's month and limits non-empty; per limit>0: `spent>=25`, `used=spent/limit>=0.65`, `used > elapsed+0.15` where `elapsed = min(max(now.day,1),daysInMonth)/daysInMonth` | urgent if used>=1 else warning | `budget-pace:<slug(cat)>:<y>-<m>` |
| goalBehindSchedule (`:333-362`) | non-completed goals; `duration=(target-createdAt).inDays>0`, `elapsed=(today-createdAt).inDays>=14`, `expected=clamp(elapsed/duration,0,1)`, emit if `progress+0.1 < expected` | urgent if target before today else warning | `goal-behind:<slug(goalId)>` |
| recurringAmountChange (`:257-295`) | group by `recurringTemplateId`, sort date desc, compare latest vs previous; skip if `change.abs()<0.05 && diff.abs()<5` | warning if up else positive | `recurring-change:<slug(templateId)>:<y>-<m>` |
| negativeCashFlow (`:364-388`) | last 3 months (incl. selected) all have income>0 and net<0 | urgent | `negative-flow:<y>-<m>` |
| monthlySpendingChange (`:147-180`) | >=3 expenses in both this and previous month, previousTotal>=50, `abs(change)>=0.2` | warning up / positive down | `monthly-change:<y>-<m>` |
| unusualTransaction (`:182-221`) | newest-first expenses of the month; history = earlier expenses in same category not in this month with amount>0; needs >=4; `amount>=50 && amount>=2.5*median`; emits at most ONE (returns) | warning | `unusual:<slug(cat)>:<yyyy-mm-dd>:<amount 2dp>` |
| savingsRateTrend (`:223-255`) | income>0 in both months; `abs(rateDelta)>=0.08` | warning down / positive up | `savings-rate:<y>-<m>` |
| consistentlyUnderBudget (`:297-331`) | limit>0; each of previous 3 months has spend>0 and ratio<0.7 | positive | `under-budget:<slug(cat)>:<y>-<m>` |

`slug` = trim, lowercase, replace `[^a-z0-9]+` with `-`, strip leading/trailing `-` (`:457-461`).

**Persisted data** (VERIFIED `local_insights_section.dart:21-22, 74-95`): stored in `SharedPreferences` (NOT the atomic store): `local_insights_dismissed_v1` = string list of insight ids (sorted), `local_insights_snoozed_v1` = JSON object `{id: ISO8601 until}` (snooze 30 days; excluded while `until.isAfter(now)`). Note ids embed year-month so a dismissal is per-month for most types. Not in `StorageKeys` and not in the backup (INFERRED: I did not audit `backup.dart`).

---

## 3. Categorization rules (summary)

Source: `lib/categorization_rule.dart`, `lib/categorization_provider.dart`, `lib/transaction_tag.dart`; used only by the transaction form (`lib/transaction_form.dart:78, 108`). Test: `test/categorization_rule_test.dart`. VERIFIED.

- Match (`categorization_rule.dart:72-89`): false if disabled or `merchantPattern.isEmpty` (pattern is trimmed at construction, `:31`); false if `transactionType != null && != type`; false if `amount < minimumAmount` or `amount > maximumAmount` (inclusive bounds); then `candidate = description.trim().toLowerCase()`, `pattern = merchantPattern.toLowerCase()`; `contains` (default) / `startsWith` / `exact` (`==`). NO regex, no word-boundary logic. Case-insensitivity is Dart `toLowerCase()` (Unicode simple lowercase; use `lowercased()` in Swift, be aware of locale-insensitive behavior).
- Priority (`categorization_provider.dart:26-30, 152-167`): rules sorted by `priority` DESC (Dart `List.sort`, unstable for > 32 elements; ties in priority have an implementation-defined order); `suggest()` returns the FIRST match (`CategorizationSuggestion(rule)`: category + tagIds). Default priority 0.
- Application: form only, on description/amount change and on prefill; applies only if `categoryMap.containsKey(suggestion.category)` for the current type; it REPLACES `category` and replaces the selected tags with the rule's `tagIds` (`transaction_form.dart:78-89, 108-121`). `parsedAmount = double.tryParse(text) ?? 0`. Rules are never applied retroactively or on import/recurring generation (INFERRED from grep: only two callers of `.suggest(`).
- Persisted: `FinancialSections.transactionTags` (list of `{id,name,colorToken}`) and `FinancialSections.categorizationRules` (list of `{id, merchantPattern, matchType: contains|startsWith|exact, transactionType: income|expense|null, minimumAmount, maximumAmount, category, tagIds, priority, isEnabled}`) via `AtomicFinancialStore.updateSection` (`categorization_provider.dart:169-181`); legacy fallback `SharedPreferences` keys `transaction_tags_v1`, `categorization_rules_v1` (`storage_keys.dart:69-70`). Unknown `matchType` decodes to `contains`; missing `category` -> `'General'`. `renameCategory` and tag deletion rewrite rules. Tag names unique case-insensitively (`:60-63`).

---

## 4. Totals and aggregations

Central code: `TransactionModel._monthLedger()` (`lib/transaction_model.dart:199-228`). VERIFIED.

### 4.1 Monthly ledger
- Key = `date.year * 12 + date.month` of the stored local `date` (`:184`). One pass over `transactions` in LIST order. Per month: `transactions` (list order), `income += amount`, `expenses += amount` (expense), `categoryExpenses[category] += amount` (expense only; key is the raw category string, case-sensitive, untrimmed). Cache invalidated on every `notifyListeners()` (`:193-197`).
- `totalIncome` / `totalExpenses` = ledger of `selectedMonth` or 0 (`:263-270`). Net/cash flow = `income - expenses` (`getMonthlySummary` `:966-976` returns `{income, expenses, net}`; the hero computes it again `spending_page.dart:1105`).
- No rounding, no filtering by "future date": ALL transactions in the month count, including future-dated rows (differs from safe-to-spend).
- Sum order = insertion order of the persisted array. Keep the same order in Swift for identical doubles.

### 4.2 Spending tab (VERIFIED `spending_page.dart`)
- Hero `CASH FLOW`: `cashFlow = income - expenses`; shows `abs()` with 2 decimals; labels `SAVED THIS MONTH` (>0) / `SHORT THIS MONTH` (<0) / `BREAKING EVEN` (==0) (`:1105-1131`); subline `'<format(income,0dp)> in   ·   <format(expenses,0dp)> out'` (three spaces around the dot, `:1192`).
- Gauge: `value = income <= 0 ? 0 : spent/income`; bar clamps to 0..1 (`glow_progress_bar.dart:47`); labels `SPENT`/income at 0dp (`:1398-1401`).
- Flow chips: `_percentDelta(current, previous)` = `previous==0 ? (current==0 ? null : 100) : (current-previous)/previous*100` (`:339-345`); label `null -> 'No <PrevMonth> data'` else `'<+ if >=0><delta.toStringAsFixed(1)>% vs <PrevMonth>'` (`:1487-1492`). Previous month = `DateTime(y, m-1)` from `selectedMonth`. Month names via `DateFormat.MMMM()` (en_US, see 6.6).
- Budget rows: for each `expenseCategories` key with `limit > 0` (`:107-124`): `spent = ledger.categoryExpenses[cat] ?? 0` of the SELECTED month; sorted `spent` DESC (`compareTo`) then category name ASC using Dart `String.compareTo` (UTF-16 code unit order, CASE-SENSITIVE, unlike other sorts) (`:126-133`). Row: `remaining = limit - spent`; `isOverBudget = remaining < 0` (`:1963-1965`); `progress = spent/limit` (bar clamped); status color: over -> danger; `progress >= 0.85` -> warning; else income (`:1672-1683`). Chip: over -> `'<fmt(abs(remaining))> over'`, else `'<fmt(remaining)> left'` where `fmt` = `MoneyFormatter.format(v, decimalDigits: v.abs() >= 100 ? 0 : 2)` (`:1695-1700`); subtitle `'<fmt(spent)> of <fmt(limit)>'`.
- Recent activity: `getRecentTransactions(3)` = newest-first sort (section 8) `take(3)` (`transaction_model.dart:986-992`). Row amount: `formatSigned(isExpense ? -amount : amount, plusForPositive: true)` -> `-$5.00` / `+$5.00` (`spending_page.dart:1760-1763`); empty description shown as `'Transaction'`.
- Budget limit editor parse: `rawValue.replaceAll(RegExp(r'[^0-9.]'), '')` then `double.tryParse` (`spending_page.dart:848-853`); save requires `> 0` (`:858`); prefilled with `MoneyFormatter.formatNumber(limit, decimalDigits: 2)` (`:838`) which is locale-formatted (e.g. `1.234,50` under de_DE) and would then be parsed with the digits-and-dot regex -> a comma-locale round trip is broken in Flutter (INFERRED; hazard only if you copy this behavior).
- Model rules for limits: `setCategoryBudgetLimit` trims the name, `limit <= 0` removes (`transaction_model.dart:750-767`); load drops `limit <= 0` (`:413-417`).

### 4.3 Categories tab (VERIFIED `category_page.dart`)
- `expensesPerCategory = getCategoryExpensesForMonth(month)` (ledger map, insertion order); `total = fold(0.0, +)` over `map.values` (`:61-64`); per category `percentage = total>0 ? amount/total*100 : 0`; records sorted by `amount` DESC via unstable `List.sort` (`:114-115`), so equal amounts have implementation-defined order (INFERRED unstable: Dart uses insertion sort only for <= 32 elements, dual-pivot quicksort above). Top 6 (`_maxVisibleCategories`, `:34`) individually, remainder aggregated as "Other" slice; row subtitle `'<n> transaction(s) · <pct.toStringAsFixed(0)>%'` then ` · over limit` if `amount > limit` else ` · <fmt(limit,0dp)> limit` (`:297-305`).
- Previous-month total is `null` (delta pill hidden) when the previous month has NO transactions at all; otherwise sum of that month's expenses (`:83-87`). Delta pill text: `category_donut_chart.dart:436` (`'<abs pct 0dp>% vs <month>'`).
- Month list = `getAvailableMonths()`: distinct months that have >= 1 transaction, newest first (`transaction_model.dart:729-737`). A month with only income still appears; the tab shows "No Expenses" when expense total == 0 (`category_page.dart:219`).
- Category detail page total = fold over that category+month rows, sorted newest-first (`category_transactions_page.dart:44-50`).

### 4.4 Transactions ("History") list and Cash Flow tab
- `TransactionPage` (`lib/transaction_page.dart`): month selector over `getAvailableMonths()` (default = newest month WITH data, `:33-35`), `_MonthlySummaryCard` (income, expenses, net via `formatSigned(net)`), list = `getTransactionsForMonth(month)` sorted `Transaction.compareNewestFirst`, grouped by day using a `Map<String,...>` keyed by `DateFormat.yMMMd().format(date)` (en_US e.g. `Jul 28, 2026`) in first-seen order (`:137-149`). Because the list is pre-sorted, groups appear newest-day first. Group key is a formatted string, so two dates with the same formatted text would merge (not possible within one month).
- Cash Flow tab: `getNetCashFlowHistory()` = for each available month oldest->newest `{net, income, expenses}` (`transaction_model.dart:1253-1264`); the range picker takes months `<= selectedMonth`, last N (3/6/12; default 6) (`history_page.dart:126-141`); `avgSavings = (sum income - sum expenses)/count`, `savingsRate = totalIncome>0 ? totalSavings/totalIncome*100 : 0`, shown `toStringAsFixed(0)%` and avg via `formatSigned(v, decimalDigits: 0)` (`:143-152, 185-187, 234`). NOTE: only months WITH data count in the N and the average denominator (gap months are skipped), while the 12-month trend/YoY use fixed calendar months (`:170-181`). YoY delta: `previous==0 -> null ('new')`, else `(cur-prev)/prev*100` with `toStringAsFixed(1)` (`:191-204`).
- Full filterable list (`history_page.dart:1350-1391`): newest-first, description `toLowerCase().contains(query)`, type, category (exact), tag, date range compared by date-only, min/max amount inclusive; pages of 50 (`_visibleTransactionCount`, `:1269, 2108`).
- `TransactionModel.getYearOverYearComparison`, `getCategoryBudgetProgressForMonth`, `getCashFlowStatistics`, `getRollingCashFlowTrend` exist but have NO callers in `lib/` outside the model (VERIFIED by grep; only tests use them). Behavior is in `transaction_model.dart:71-130, 839-866, 1266-1324` if wanted (progress sort: over-budget first, then `progress` DESC, then case-insensitive name).
- Running balances: none. There is no per-transaction or cumulative balance anywhere in `lib/` (VERIFIED by grep). Net worth is independent of transactions.

### 4.5 Net worth totals (`net_worth_entry.dart`, `transaction_model.dart:176-179, 483-585, 1326-1341`)
- Selected month = `_selectedNetWorthMonth`, default current month, persisted as ISO string in section `selectedNetWorthMonth` (`:153-154, 236-243, 404-411`).
- `totalAssets = sum over entries of type asset of entry.amountAt(endOfMonth(selectedMonth)) ?? 0`, liabilities likewise; `netWorth = totalAssets - totalLiabilities` (liabilities stored as positive numbers). `endOfNetWorthMonth(m) = DateTime(y, m+1) - 1ms` (`net_worth_entry.dart:38-41`).
- `amountAt(date)` = the amount of the snapshot with the greatest `recordedAt` such that `recordedAt <= date` (i.e. balances CARRY FORWARD across months; an account with no snapshot on/before the month end contributes 0 and is excluded from that month's lists) (`:181-199`). `snapshotForMonth` (exact month, latest in month) is used only for "updated" counts and carry-forward (`:164-179`).
- Fold: `entries.where(type).map(amountAt ?? 0).fold(0.0, +)` in `_netWorthEntries` list order (`transaction_model.dart:1333-1341`).
- Month change = `netWorth(month) - netWorth(month-1)`, null if no entry has an actual snapshot IN the month or the previous month has no tracked entry (`:518-529`). Hero delta pill: `percent = |change| / |netWorth - change| * 100` with `toStringAsFixed(1)`, or `'+—'`/`'-—'` when the base is <= 0.001 (`net_worth_page.dart:341-347`). Hero digits use a hard-coded `'$'` prefix and 0 decimals (`net_worth_page.dart:296-300`), i.e. it IGNORES the currency setting (VERIFIED).
- Account list order within a month: amount DESC then name lowercased ASC (`transaction_model.dart:494-501`).
- Net-worth is likely post-MVP; history-point logic is `:541-551, 1361-1439` if needed.

---

## 5. CSV export and import

### 5.1 Export (VERIFIED `lib/transaction_model.dart:994-1040`; UI `lib/settings_page.dart:64-114`, row at `:773`)

```dart
rows.add(['Date', 'Type', 'Category', 'Description', 'Amount']);
final sortedTransactions = List<Transaction>.from(transactions);
sortedTransactions.sort((a, b) => a.date.compareTo(b.date));      // oldest first
for (final transaction in sortedTransactions) {
  rows.add([
    DateFormat('yyyy-MM-dd').format(transaction.date),
    transaction.type == TransactionTyp.income ? 'Income' : 'Expense',
    transaction.category,
    transaction.description,
    transaction.amount.toStringAsFixed(2),
  ]);
}
final csv = const ListToCsvConverter().convert(rows);
final tempDir = await getTemporaryDirectory();
final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
final filePath = '${tempDir.path}/transactions_$timestamp.csv';
await File(filePath).writeAsString(csv);
await Share.shareXFiles([XFile(filePath)], subject: 'Budget Transactions Export', sharePositionOrigin: ...);
```

Exact bytes (csv package 6.0.0, `pubspec.lock`; converter source `~/.pub-cache/hosted/pub.dev/csv-6.0.0/lib/list_to_csv_converter.dart:88-124, 146-207`, defaults `csv.dart:16-24`). Reproduced by running the real converter:

- Columns/header: `Date,Type,Category,Description,Amount` (5 columns, that order, header text exactly as shown, always emitted even with zero transactions: output is just the header line).
- Field delimiter `,`; text delimiter `"`; **row separator `\r\n` (CRLF)** written BETWEEN rows; **NO trailing newline** after the last row (reproduced: `endsWith('\n') == false`). **No BOM** (`writeAsString` default UTF-8, no BOM added). Import strips a BOM if present (`:1046`) but export never writes one.
- Quoting rule (`_containsAny(value, [fieldDelimiter, textDelimiter, textEndDelimiter, eol])`, checks each CHARACTER of the delimiters/eol independently): a field is wrapped in `"..."` iff it contains `,` or `"` or `\r` or `\n`. Embedded `"` is doubled (`""`). Reproduced:
  - `Salary, bonus` -> `"Salary, bonus"`
  - `Book "Dart"` -> `"Book ""Dart"""`
  - `line1\nline2` -> quoted, newline kept as a raw LF inside quotes
  - lone `\r` -> quoted
  - `=SUM(A1)` -> `=SUM(A1)` UNQUOTED and unescaped (no formula-injection protection; no leading `'`, `+`, `-`, `@` handling)
  - leading/trailing spaces preserved and NOT quoted (`  padded ` stays as is)
  - tab is NOT quoted; empty string -> empty field (`,,`); non-ASCII/emoji written raw as UTF-8; the category and description are written untrimmed
  - null is not possible (description is non-null; the form substitutes `'Transaction'` when empty).
- Number formatting: `amount.toStringAsFixed(2)`: always exactly 2 decimals, `.` separator, NO thousands separators, no currency symbol, `-` prefix for negatives (`-0.00` for tiny negatives), never exponent notation below 1e21 (at >= 1e21 Dart prints `1e+21`; unreachable in practice). `toStringAsFixed` rounds the EXACT binary value and ties (exactly representable halves such as `0.125`) round AWAY from zero: `0.125 -> 0.13`, `2.5.toStringAsFixed(0) -> 3`, `0.015 -> 0.01`, `0.005 -> 0.01`, `1.005 -> 1.00`, `3.005 -> 3.00`. `String(format: "%.2f")` on Apple platforms rounds exact ties half-EVEN (`0.125 -> 0.12`), so it is NOT byte-identical; use a round-half-away-from-zero on the exact decimal expansion (e.g. `Decimal(string:)` from the shortest repr is NOT equivalent either; safest is to implement via `NSDecimalNumber(value:)` with the double's exact expansion or a manual digit routine and test the vectors above).
- Date column: `DateFormat('yyyy-MM-dd')` of the stored local DateTime -> `2026-01-05` (ASCII digits under the effective en_US locale).
- Type column: `Income` / `Expense` (capitalised).
- Order: `a.date.compareTo(b.date)` on the FULL timestamp (moment ordering, ascending). Dart `List.sort` is not stable for > 32 elements (insertion sort <= 32, dual-pivot quicksort above; `dart-sdk/lib/internal/sort.dart:16-18, 61`), so rows with IDENTICAL timestamps may come out in a different order than the Swift stable `sort`. Byte parity is guaranteed only when timestamps are distinct or n <= 32 (INFERRED for the > 32 tie case). Note many rows can tie because recurring/picker/voice dates are midnight.
- File name: `transactions_<yyyyMMdd_HHmmss>.csv` from local `DateTime.now()`, e.g. `transactions_20260728_143005.csv`, in the app temp dir (`getTemporaryDirectory()`), not the documents folder; never cleaned up by the app (INFERRED).
- Share mechanism: `share_plus` `Share.shareXFiles([XFile(path)], subject: 'Budget Transactions Export', sharePositionOrigin: <button rect for iPad popover>)` -> the iOS share sheet (`UIActivityViewController`). Snackbar on success: `'Transactions exported successfully!'`; on failure: `'Error exporting transactions: $e'` (`settings_page.dart:86, 99`). Mime type is inferred from the `.csv` extension by share_plus (INFERRED).
- Exports ALL transactions (not filtered by month/selection); does not include id, tags, `recurringTemplateId`, createdAt/updatedAt.

### 5.2 Import (summary; VERIFIED `transaction_model.dart:1042-1193`, `settings_page.dart:116-214`, tests `test/transaction_model_csv_import_test.dart`)
- File picker: extension `csv`, bytes decoded `utf8.decode(bytes, allowMalformed: true)` (`settings_page.dart:126-138`).
- Strip leading U+FEFF; parse with `CsvToListConverter(shouldParseNumbers: false, csvSettingsDetector: FirstOccurrenceSettingsDetector(eols: ['\r\n','\n']))` (delimiter `,` and quote `"` are defaults; EOL = whichever of CRLF/LF occurs first in the file). Header must be exactly 5 columns whose trimmed lowercase text is `date,type,category,description,amount` in order, else `FormatException('Not a valid transactions CSV export')` (also thrown for empty content).
- Per data row (numbered from 2): all-blank rows skipped; `row.length != 5` -> error `Row N: expected 5 columns but found M`; date via `DateTime.tryParse(trimmed)` and must satisfy `dateText.startsWith(yyyy-MM-dd of parsed)` else `Row N: invalid date "x"` (rejects 2026-02-30 / month 13); type trimmed, case-insensitive `income|expense` else `Row N: invalid type "x"`; category trimmed and non-empty else `Row N: category is empty`; description trimmed (may be empty; NOT replaced by `'Transaction'`); amount: trimmed, optional single leading `$` removed, if it contains `,` it must match `^\d{1,3}(,\d{3})+(\.\d+)?$` (then commas stripped) else `Row N: invalid amount "x"`; `double.tryParse`, must be finite and `>= 0`.
- New `Transaction`: fresh UUID, `createdAt=updatedAt=now`, `date` = parsed date (midnight if plain `yyyy-MM-dd`), no tags, no recurring link.
- Dedupe: multiset against EXISTING transactions only (not within the file) using key `yyyy-MM-dd|income/expense|category.trim()|description.trim()|amount.toStringAsFixed(2)` (`:1243-1250`); each existing occurrence cancels one parsed row.
- Commit: `importTransactions` appends, regenerates any colliding id, saves, notifies (`:1178-1193`). UI shows a confirm dialog first (`settings_page.dart:170`); messages at `:141-193`.

---

## 6. Money formatting

Source: `lib/money_formatter.dart` (64 lines), `lib/app_settings_provider.dart`, settings UI `lib/settings_page.dart:661-690, 919-961, 1038-1061`. Package: `intl 0.20.2` (`pubspec.yaml:36`; source read at `~/.pub-cache/hosted/pub.dev/intl-0.20.2/lib/src/intl/number_format.dart`).

### 6.1 Settings and storage (VERIFIED)
- `baseCurrencyCode`: default `'USD'`; choices (`settings_page.dart:1038-1050`): USD, CAD, EUR, GBP, AUD, JPY, CNY, INR, KRW, MXN, BRL. Setter uppercases/trims, requires length 3 (`app_settings_provider.dart:58-67`).
- `localeOverride`: default `null` ("Match device"); choices (`:1052-1061`): en_US, en_CA, en_GB, en_AU, de_DE, fr_FR, es_ES, ja_JP (label sheet title "Number format"). Stored as the raw underscore string.
- `hideBalances`: bool default false. Also `appLockEnabled`, `autoLockTimeoutSeconds` (default 60; choices 0/30/60/300/900).
- Storage: primary = `FinancialSections.appSettings` object `{baseCurrencyCode, localeOverride, appLockEnabled, autoLockTimeoutSeconds, hideBalances}` in the atomic store (`app_settings_provider.dart:158-169`); ALSO mirrored to `SharedPreferences` keys `base_currency_code`, `locale_override`, `app_lock_enabled`, `auto_lock_timeout_seconds`, `hide_balances` (`storage_keys.dart:56-66`). Load prefers the atomic section value, falls back to prefs, then defaults (`:38-52`). Loading pushes into `MoneyFormatter.configure` (`:150-156`); before load, `MoneyFormatter` is USD / null locale / not hidden.
- Currency is a DISPLAY setting only: no conversion, stored amounts are unitless doubles.

### 6.2 API (VERIFIED `money_formatter.dart`)
```
format(value, decimalDigits: 2, compact: false):
   if hideBalances -> '••••'   (U+2022 x4)
   compact -> NumberFormat.compactSimpleCurrency(locale, name: currency, decimalDigits).format(value)
   else    -> NumberFormat.simpleCurrency(locale, name: currency, decimalDigits: decimalDigits).format(value)
formatSigned(value, decimalDigits: 2, plusForPositive: false):
   hideBalances -> '••••'
   sign = value < 0 ? '-' : (plusForPositive && value > 0 ? '+' : '')
   sign + format(abs(value), decimalDigits)          // ASCII hyphen-minus, sign BEFORE the currency symbol even in suffix locales: '-1.234,56 €'
formatNumber(value, decimalDigits: 2) -> NumberFormat.decimalPatternDigits(locale, decimalDigits).format(value)   // no currency symbol; used only to prefill the budget-limit field
```
`decimalDigits` is ALWAYS passed explicitly by callers (default 2; 0 on cards; 1 for compact net worth), which OVERRIDES the currency's natural digits: JPY/KRW still print 2 decimals at the default (reproduced: `ja_JP JPY 1234.56 -> ¥1,234.56`). `format` (unsigned) of a negative number gives `-$5.00` (prefix `-` from the locale's negative pattern).

### 6.3 Symbol, placement, grouping (VERIFIED by reading `number_symbols_data.dart` and running)
- Locale resolution: `locale: null` -> `Intl.getCurrentLocale()` -> `Intl.defaultLocale ?? 'en_US'`. Nothing in `lib/` sets `Intl.defaultLocale` or calls `findSystemLocale`/`initializeDateFormatting`, and `flutter_localizations` is not a dependency (grep of `lib/` and `pubspec.yaml`), and `MaterialApp(locale:)` (`main.dart:60`) does not touch intl. Therefore "Match device" formats as **en_US regardless of device region** (running the package printed `Intl.getCurrentLocale() == en_US`). INFERRED at runtime (I did not run on-device; a plugin setting `Intl.defaultLocale` is not evidenced). `de_DE` resolves to the `de` symbols, `fr_FR` to `fr`, `ja_JP` to `ja`.
- Currency SYMBOL comes from a locale-independent table, keyed by ISO code (`number_format.dart:373`, `constants.dart` `simpleCurrencySymbols`): USD `$`, CAD `$`, AUD `$`, MXN `$`, EUR `€`, GBP `£`, JPY `¥`, CNY `¥`, INR `₹`, KRW `₩`, BRL `R$`. So CAD under en_US prints `$` (not `CA$`); USD under de_DE prints `1.234,56 $`.
- Pattern comes from the LOCALE, not the currency (VERIFIED):
  | locale | decimal | group | positive pattern | negative |
  |---|---|---|---|---|
  | en_US, en_CA, en_GB, en_AU | `.` | `,` | `¤#,##0.00` -> `$1,234.56` | `-$1,234.56` |
  | ja | `.` | `,` | `¤#,##0.00` | `-¥1,234.56` |
  | de, es | `,` | `.` | `#,##0.00 ¤` -> `1.234,56 €` (U+00A0 before symbol) | `-1.234,56 €` |
  | fr | `,` | U+202F (narrow NBSP) | `#,##0.00 ¤` -> `1 234,56 €` | `-1 234,56 €` |
  Reproduced: `fr_FR EUR -1234.56 -> codeUnits [45,49,8239,50,51,52,44,53,54,160,8364]`. Grouping size 3 everywhere (INR does NOT get lakh grouping: locale, not currency, drives grouping). No minimum-grouping-digits rule (es shows `1.234,56`).
- Zero digits: `format(1234.5, 0)` -> `$1,235`.
- Compact (`compact: true`, used only in Net Worth chips `net_worth_page.dart:2954-2958`): `compactSimpleCurrency(decimalDigits: 1)`: `1234567 -> $1.23M`, `1234 -> $1.23K`, `999 -> $999`, `1.5e9 -> $1.5B`, `formatSigned`-style negative handled manually (`'-' + compact(abs)`); note decimalDigits 1 does NOT yield `$1.2M` (compact rounds to significant digits, reproduced `1.23M`), so do not assume `%.1f`.
- Negative zero / tiny negatives (reproduced): `format(-0.001)` and `format(-0.0)` both give `-$0.00` (intl keys off `isNegative`, which is true for `-0.0`). `formatSigned(-0.001)` also gives `-$0.00` (`-0.001 < 0` is true), but `formatSigned(-0.0)` gives `$0.00` (`-0.0 < 0` is false, then `format(abs)`). Swift: use `x.sign == .minus` for `format`, `x < 0` for `formatSigned`.

### 6.4 Rounding algorithm (VERIFIED `number_format.dart:693-766`) - NOT the same as `toStringAsFixed`
For a value `x` and `d` digits: sign handled first (`isNegative` -> negative prefix), then on `|x|`: `integerPart = floor(|x|)`; `fraction = |x| - integerPart` (double subtraction); `remaining = (fraction * 10^d).round()` where Dart `num.round()` is round-half-AWAY-from-zero on the floating-point PRODUCT; if `remaining >= 10^d` carry +1 into the integer part. So the tie is decided by the rounded double product, not the exact decimal. Reproduced differences between display (intl) and CSV (`toStringAsFixed(2)`):

| value | intl 2dp (display) | toStringAsFixed(2) (CSV/dedupe) |
|---|---|---|
| 0.015 | `$0.02` | `0.01` |
| 0.995 | `$1.00` | `0.99` |
| 0.125 | `$0.13` | `0.13` |
| 1.005 | `$1.00` | `1.00` |
| 2.675 | `$2.67` | `2.67` |
| 1234.5 (0dp) | `$1,235` | `1235` |
| 2.5 (0dp) | `$3` | `3` |

Swift port: implement `floor`, `frac = |x| - floor`, `Int((frac * pow(10, d)).rounded(.toNearestOrAwayFromZero))`, carry, then group digits. `NumberFormatter` (ICU, exact-decimal half-even by default) will NOT match on ties like 0.015/0.995. Also for |x| > 2^52 intl pads with zeros (irrelevant for real budgets); values >= ~9.2e18 print garbage (`1e21 -> $922,337,203,685,477,580,700.00`).

### 6.5 Other display formats (VERIFIED)
- Percent strings use `toStringAsFixed(1)` or `(0)` (Dart, exact-decimal half-away): spending delta `spending_page.dart:1492`, YoY `history_page.dart:203`, savings rate `:234`, net worth `net_worth_page.dart:345, 1144, 1207`, category `category_page.dart:299`, donut `category_donut_chart.dart:370, 436`. Category percent rows are per-row rounded, so they may not sum to 100.
- Net worth edit fields use `NumberFormat('#,##0.##')` with default locale (`net_worth_page.dart:2241, 2509`), and the hero uses a literal `$` (see 4.5). `transaction_form.dart:61,71` prefill uses `amount.toStringAsFixed(2)`. `hideBalances` masks `format`/`formatSigned` only (not percentages, not raw text fields, and NOT the net worth hero: `net_worth_page.dart` has zero references to `hideBalances`, VERIFIED by grep, and the hero is not routed through `MoneyFormatter`).
- The Spending hero digits are assembled from `_HeroAmountFormat` (prefix/suffix from formatting 0, group/decimal separators from the locale symbols) and animated (`spending_page.dart:1059-1089, 1172-1185`); the static label under it is the `MoneyFormatter.format(cashFlow.abs())` string.

### 6.6 Dates in display strings
`DateFormat.MMMM()`, `yMMMM()`, `yMMMd()`, `MMMd()`, `"MMM 'yy"`, `'MMM dd, yyyy'` all resolve to en_US month names/order because the intl default locale is never changed (INFERRED as in 6.3). If the port localizes dates, that is a deliberate divergence.

---

## 7. Budget reports (`test/transaction_model_budget_reports_test.dart`)

Tests assert (VERIFIED):
1. `getCategoryBudgetProgressForMonth(month)` returns one `CategoryBudgetProgress` per stored limit (only `Eating Out` with limit 400); `spent` = that category's expenses in the month (125; the 40 'Transportation' expense is ignored), `limit` 400, `remaining = limit - spent = 275`; persisted section `categoryBudgetLimits == {'Eating Out': 400.0}` (`:18-51`). Formulas: `remaining = limit - spent`, `progress = limit <= 0 ? 0 : spent/limit`, `isOverBudget = limit > 0 && spent > limit` (`transaction_model.dart:71-85`); UI has its own copy (`spending_page.dart:1948-1968`, `isOverBudget = remaining < 0`, equivalent for limit > 0).
2. Monthly totals and category spending are recomputed after `updateTransaction` (5 -> 8) and after `deleteTransactionById` (-> 0); `getRecentTransactions(3)` reflects it (`:53-75`).
3. Limits load from legacy prefs JSON, dropping `<= 0` (`'Ignored': 0` is removed) (`:77-90`).
4. Year-over-year: Jan 2025 expenses 1200+200=1400 vs Jan 2026 1300+300=1600 -> `difference 200`, `percentChange = 200/1400*100 ~ 14.285` (`0` if both 0; `100` if previous is 0 and current > 0), categories sorted by combined total DESC then case-insensitive name (`Housing` first) (`:92-133`; impl `transaction_model.dart:87-130, 1285-1299`).
5. Savings goals: add (name/target/date), `allocateToSavingsGoal` accumulates `currentAmount` clamped at >= 0, `progress = clamp(current/target, 0, 1)` (0.25 at 1250/5000), completes when `current >= target` and stamps `completedAt`; persisted and reloaded (`:135-162`; impl `transaction_model.dart:868-963`, `savings_goal.dart`).

Only (1)-(3) and the goal logic are reachable from the UI; the YoY comparison object has no UI caller (the History tab builds its own YoY from `getMonthlySummary`, `history_page.dart:49-51, 278-355`).

---

## 8. Transaction ordering (`test/transaction_ordering_test.dart`)

Single comparator (VERIFIED `lib/transaction.dart:70-79`):

```dart
static int compareNewestFirst(Transaction a, Transaction b) {
  final dayCompare = _dayKey(b.date).compareTo(_dayKey(a.date));   // calendar day DESC (time stripped)
  if (dayCompare != 0) return dayCompare;
  final createdCompare = b.createdAt.compareTo(a.createdAt);        // createdAt DESC (full timestamp)
  if (createdCompare != 0) return createdCompare;
  return b.id.compareTo(a.id);                                      // id DESC, Dart String.compareTo (UTF-16 code units)
}
_dayKey(v) = DateTime(v.year, v.month, v.day)
```

Sort keys in priority: (1) local calendar day of `date`, newest first; (2) `createdAt` newest first; (3) `id` descending as a total tie-break (UUID v4 strings are lowercase hex + dashes, so code-unit order equals plain lexicographic). Because id is unique the comparator is a total order, so the unstable Dart sort cannot produce differing results (VERIFIED by reasoning; only duplicate ids would tie, and the loader regenerates duplicate ids, `transaction_model.dart:373-377`).

Tests (`transaction_ordering_test.dart`): same-day rows order by createdAt desc (Groceries 18:05 > Lunch createdAt 12:40 with date at midnight > Coffee 09:15) - note it is `createdAt`, not the `date`'s time, that decides same-day order; a later day always wins regardless of time (Today midnight before Yesterday 23:30); identical `date`+`createdAt` fall back to id, giving the same result for either input order.

Users of it: recent activity (`transaction_model.dart:979-992`), history list and its month groups (`transaction_page.dart:137-139`), full history (`history_page.dart:1352` via `getAllTransactionsSorted`), category detail (`category_transactions_page.dart:44`), History preview (`history_page.dart:403-405`). `getTransactionsForMonth` returns ledger (persisted) order, unsorted. Other orders: CSV export by `date` ascending only (section 5); budget rows by spent desc then name (4.2).

`createdAt` semantic: set at creation (`transaction.dart:35`), preserved on edit (`transaction_model.dart:453-461`); for legacy rows lacking it, `createdAt = date` (`transaction.dart:103`), so legacy same-day rows order by their date's time.

---

## Unverified / not determined
- Runtime device-locale behavior of intl (assumed en_US always; no on-device run).
- Whether `backup.dart` includes insight dismiss/snooze prefs (not audited).
- Order of ties for `List.sort` beyond documented unstable > 32 elements (Category tab sort, CSV export with identical timestamps, rule priority ties) is implementation-defined; not reproduced with a > 32-element experiment.
- Behavior for extremely large values (>= 2^53) in intl.
- Insight rule copy/wording is quoted from source but no numeric test vectors were run (out of MVP).
