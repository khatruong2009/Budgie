// Emits native/Fixtures/goals/ : the Goals tab's model behaviour and display
// values, from the real Dart code.
//
// tz/<zone>/mutations.json: scenarios of real TransactionModel goal
// mutations (add, update through the page's edit path, delete, allocate)
// through a real AtomicFinancialStore (files in a temp directory) with a
// pinned clock, recording after every call whether the store was written,
// the stored `savingsGoals` section and the model's memory. Dates are built
// from local components on both sides, so DST gaps and repeated hours
// resolve the same way.
//
// tz/<zone>/derived.json: a table of goals (read with SavingsGoal.fromJson)
// against a table of pinned "now" values: progress, percent, overdue,
// status, suggested contribution, pace copy; per goal the completion copy
// and `willComplete`; the page's sort and summary over several lists.
//
// Formulas private to the page's State classes in savings_goals_page.dart
// are copied verbatim below, each citing its source lines; they call the
// real model.

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/parity_clock.dart';
import 'package:budget_app/savings_goal.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

String get zoneDir => 'goals/tz/${parityTz.replaceAll('/', '_')}';

// --- Copied verbatim from savings_goals_page.dart (private members) --------

enum GoalStatus { onTrack, behind, complete }

/// SG:154-162 `_sortedGoals`.
List<SavingsGoal> sortedGoals(List<SavingsGoal> goals) {
  return List<SavingsGoal>.from(goals)
    ..sort((a, b) {
      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }
      return a.targetDate.compareTo(b.targetDate);
    });
}

/// SG:246-267 `_statusFor` (`DateTime.now()` is the pinned clock).
GoalStatus statusFor(SavingsGoal goal) {
  if (goal.isCompleted) {
    return GoalStatus.complete;
  }
  if (goal.isOverdue) {
    return GoalStatus.behind;
  }

  final now = parityNow();
  final start = goal.createdAt;
  final totalSpan = goal.targetDate.difference(start).inMilliseconds;
  if (totalSpan <= 0) {
    // Same-day (or inverted) deadline: only on track once fully funded.
    return goal.progress >= 1.0 ? GoalStatus.onTrack : GoalStatus.behind;
  }

  final elapsed = now.difference(start).inMilliseconds;
  final expected = (elapsed / totalSpan).clamp(0.0, 1.0);
  return goal.progress + 1e-9 >= expected
      ? GoalStatus.onTrack
      : GoalStatus.behind;
}

/// SG:271-281 `_paceCopyFor`.
String paceCopyFor(SavingsGoal goal) {
  final date = DateFormat.MMMd().format(goal.targetDate);
  final monthly = MoneyFormatter.format(
    goal.suggestedMonthlyContribution,
    decimalDigits: 0,
  );
  if (statusFor(goal) == GoalStatus.behind) {
    return '$date · bump to $monthly/mo to catch up';
  }
  return '$date · $monthly/mo keeps you on pace';
}

/// SG:888-890 (`_SavingsGoalCard`, completed sub-copy).
String fullyFunded(SavingsGoal goal) {
  final date = DateFormat.MMMd().format(goal.completedAt ?? goal.targetDate);
  return 'Fully funded on $date — nice work';
}

/// SG:620-631 and 664 (`_SavingsGoalsSummary.build`) over the page's
/// sorted list.
Map<String, Object?> summary(List<SavingsGoal> goals) {
  final totalSaved = goals.fold<double>(
    0,
    (sum, goal) => sum + goal.currentAmount,
  );
  final totalTarget = goals.fold<double>(
    0,
    (sum, goal) => sum + goal.targetAmount,
  );
  final completedCount = goals.where((goal) => goal.isCompleted).length;
  final totalProgress =
      (totalTarget <= 0 ? 0.0 : totalSaved / totalTarget).clamp(0.0, 1.0);
  final percentLabel = '${(totalProgress * 100).round()}%';
  String caption() =>
      'of ${MoneyFormatter.format(totalTarget, decimalDigits: 0)} · '
      '$completedCount of ${goals.length} complete';
  final captions = <String>[];
  for (final (currency, locale, hidden) in formatterConfigs) {
    MoneyFormatter.configure(
        currencyCode: currency, locale: locale, hideBalances: hidden);
    captions.add(caption());
  }
  MoneyFormatter.configure(currencyCode: 'USD');
  return {
    'order': goals.map((g) => g.id).toList(),
    'totalSaved': bitsHex(totalSaved),
    'totalTarget': bitsHex(totalTarget),
    'completedCount': completedCount,
    'count': goals.length,
    'progress': bitsHex(totalProgress.toDouble()),
    'percent': percentLabel,
    'captions': captions,
  };
}

// ---------------------------------------------------------------------------

const formatterConfigs = <(String, String?, bool)>[
  ('USD', null, false),
  ('EUR', 'de_DE', false),
  ('USD', null, true),
];

Map<String, Object?> goalMemory(SavingsGoal g) => {
      'id': g.id,
      'name': g.name,
      'targetAmount': bitsHex(g.targetAmount),
      'currentAmount': bitsHex(g.currentAmount),
      'targetDate': iso(g.targetDate),
      'createdAt': iso(g.createdAt),
      'completedAt': g.completedAt == null ? null : iso(g.completedAt!),
    };

List<Map<String, Object?>> memory(TransactionModel model) =>
    [for (final g in model.savingsGoals) goalMemory(g)];

/// Resolves a goal reference: an int indexes the current goals, a string
/// is used as is.
String resolveId(TransactionModel model, Object? ref) =>
    ref is int ? model.savingsGoals[ref].id : ref as String;

Future<Map<String, Object?>> runScenario(Map<String, Object?> scenario) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('goals_fixture');
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final store = AtomicFinancialStore.instance;
  var clock = local(scenario['launch'] as List);
  pinClock(clock);
  final initial = scenario['initial'] as Map<String, Object?>;
  if (initial.isNotEmpty) {
    await store.updateSections(initial);
  }
  final model = TransactionModel();
  await model.getTransactions();
  final loaded = memory(model);
  final loadedSection =
      (await store.read()).sections[FinancialSections.savingsGoals];

  final steps = <Map<String, Object?>>[];
  for (final op in (scenario['ops'] as List).cast<List>()) {
    if (op[0] == 'clock') {
      clock = local(op[1] as List);
      pinClock(clock);
      steps.add({'op': 'clock', 'now': iso(clock)});
      continue;
    }
    final before = (await store.read()).revision;
    final step = <String, Object?>{'op': op[0], 'now': iso(clock)};
    switch (op[0]) {
      case 'add':
        final count = model.savingsGoals.length;
        final target = (op[2] as num).toDouble();
        final date = local(op[3] as List);
        step.addAll({
          'name': op[1],
          'targetAmount': bitsHex(target),
          'targetDate': iso(date),
        });
        await model.addSavingsGoal(
            name: op[1] as String, targetAmount: target, targetDate: date);
        step['newId'] = model.savingsGoals.length > count
            ? model.savingsGoals.last.id
            : null;
      case 'edit':
        // The page's edit path (SG:283-329): the form's result applied to the
        // goal it showed via copyWith, then updateSavingsGoal.
        final id = resolveId(model, op[1]);
        final name = op[2] as String;
        final target = (op[3] as num).toDouble();
        final current = (op[4] as num).toDouble();
        final shown = model.savingsGoals.where((g) => g.id == id).firstOrNull ??
            SavingsGoal(
                id: id,
                name: 'Stale',
                targetAmount: 1,
                targetDate: local([2026, 1, 1]));
        final date = op[5] == 'keep' ? shown.targetDate : local(op[5] as List);
        step.addAll({
          'id': id,
          'name': name,
          'targetAmount': bitsHex(target),
          'currentAmount': bitsHex(current),
          'targetDate': iso(date),
        });
        await model.updateSavingsGoal(
          shown.copyWith(
            name: name,
            targetAmount: target,
            currentAmount: current,
            targetDate: date,
            completedAt: current >= target
                ? shown.completedAt ?? parityNow()
                : null,
          ),
        );
      case 'delete':
        final id = resolveId(model, op[1]);
        step['id'] = id;
        await model.deleteSavingsGoal(id);
      case 'allocate':
        final id = resolveId(model, op[1]);
        final amount = (op[2] as num).toDouble();
        final shown = model.savingsGoals.where((g) => g.id == id).firstOrNull;
        step.addAll({
          'id': id,
          'amount': bitsHex(amount),
          // SG:350, on the goal as shown before the dialog.
          'willComplete': shown == null
              ? null
              : !shown.isCompleted && amount >= shown.remainingAmount,
        });
        await model.allocateToSavingsGoal(id, amount);
      default:
        throw ArgumentError('unknown op ${op[0]}');
    }
    final snapshot = await store.read();
    final section = snapshot.sections[FinancialSections.savingsGoals];
    step.addAll({
      'wrote': snapshot.revision != before,
      'section': section == null ? null : jsonEncode(section),
      'memory': memory(model),
      'hasUnsavedChanges': model.hasUnsavedChanges,
    });
    steps.add(step);
  }
  final result = {
    'name': scenario['name'],
    'launch': iso(local(scenario['launch'] as List)),
    'byteComparable': scenario['byteComparable'],
    'initial': initial.isEmpty ? null : jsonEncode(initial),
    'loaded': loaded,
    'loadedSection': loadedSection == null ? null : jsonEncode(loadedSection),
    'steps': steps,
  };
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  return result;
}

final scenarios = <Map<String, Object?>>[
  {
    // Every mutation on data the Dart model wrote itself: Swift's in-place
    // patch must produce the same bytes after every step.
    'name': 'canonical',
    'byteComparable': true,
    'launch': [2026, 3, 10, 9, 15, 30, 250, 7],
    'initial': <String, Object?>{},
    'ops': [
      ['add', 'Vacation', 5000.0, [2026, 12, 1]],
      ['allocate', 0, 1250.0],
      ['allocate', 0, 3750.0],
      ['add', '  Emergency fund  ', 0.1 + 0.2, [2026, 9, 15, 18, 45, 12, 5, 9]],
      ['add', '   ', 100.0, [2026, 5, 1]],
      ['add', '\u{FEFF}', 100.0, [2026, 5, 1]],
      ['add', 'Zero', 0.0, [2026, 5, 1]],
      ['add', 'Negative', -5.0, [2026, 5, 1]],
      ['add', 'Big', 1e21, [2030, 1, 1]],
      ['add', 'Tiny', 1e-7, [2026, 3, 10, 23, 59]],
      ['add', 'Café ☕️ "quoted"', 1200.0, [2025, 12, 31]],
      ['clock', [2026, 3, 10, 9, 15, 31, 0, 1]],
      ['allocate', 1, 0.1],
      ['allocate', 1, 0.2],
      ['allocate', 1, -0.05],
      ['allocate', 1, 0.0],
      ['allocate', 1, -0.0],
      ['allocate', 'missing-id', 5.0],
      ['allocate', 3, 1e-7],
      ['allocate', 4, -50.0],
      ['edit', 0, 'Vacation 2027', 6000.0, 5000.0, 'keep'],
      ['edit', 0, ' Vacation 2027 ', 6000.0, 6000.0, [2027, 6, 15, 14, 30]],
      ['clock', [2026, 3, 11, 8]],
      ['edit', 0, 'Vacation 2027', 6500.0, 7000.0, 'keep'],
      ['edit', 0, '  ', 6500.0, 7000.0, 'keep'],
      ['edit', 0, 'X', 0.0, 1.0, 'keep'],
      ['edit', 'missing-id', 'Ghost', 10.0, 1.0, [2026, 6, 1]],
      ['edit', 2, 'Big', 1e21, -0.0, 'keep'],
      ['edit', 2, 'Big', 1e21, -25.0, 'keep'],
      ['edit', 2, 'Big', 1e21, 33.333, 'keep'],
      ['delete', 'missing-id'],
      ['delete', 3],
      ['add', 'After delete', 250.5, [2026, 4, 30]],
      ['allocate', 4, 1000.0],
      ['allocate', 4, 1000.0],
      ['edit', 4, 'After delete', 250.5, 0.0, 'keep'],
      ['delete', 0],
      ['delete', 0],
      ['delete', 0],
      ['delete', 0],
      ['add', 'Fresh start', 10.0, [2026, 3, 11]],
    ],
  },
  {
    // Data another writer produced: unknown keys, int and string amounts,
    // negative amounts, date-only and UTC dates, dates that fall back to
    // "now", a blank name, reordered keys and a duplicated id. Dart rewrites
    // it; Swift patches it. Memory must agree after every step (bytes differ
    // by design).
    'name': 'foreign',
    'byteComparable': false,
    'launch': [2026, 6, 15, 12],
    'initial': <String, Object?>{
      'savingsGoals': [
        {
          'id': 'g-int',
          'name': ' Trip ',
          'targetAmount': 1200,
          'currentAmount': 300,
          'targetDate': '2026-12-01T00:00:00.000',
          'createdAt': '2026-01-05T10:00:00.000',
          'completedAt': null,
          'color': 'teal',
        },
        {
          'id': 'g-str',
          'name': 'Car',
          'targetAmount': '8000.50',
          'currentAmount': 'abc',
          'targetDate': '2027-01-01',
          'createdAt': '2026-02-01T09:00:00Z',
          'note': {
            'x': [1, 2.50]
          },
        },
        {
          'extra': true,
          'completedAt': '2026-05-01T08:00:00.000',
          'currentAmount': 900.0,
          'targetAmount': 800.0,
          'name': '',
          'id': 'g-reordered',
          'targetDate': '2026-05-31T00:00:00.000Z',
        },
        {
          'id': 'g-neg',
          'name': 'Neg',
          'targetAmount': -10,
          'currentAmount': -5.5,
          'targetDate': 'garbage',
          'createdAt': '',
        },
        {
          'id': 'g-dup',
          'name': 'Dup A',
          'targetAmount': 100.0,
          'currentAmount': 10.0,
          'targetDate': '2026-08-01T00:00:00.000',
          'createdAt': '2026-01-01T00:00:00.000',
          'completedAt': null,
        },
        {
          'id': 'g-dup',
          'name': 'Dup B',
          'targetAmount': 200.0,
          'currentAmount': 20.0,
          'targetDate': '2026-09-01T00:00:00.000',
          'createdAt': '2026-01-02T00:00:00.000',
          'completedAt': null,
        },
      ],
    },
    'ops': [
      ['allocate', 'g-int', 900.0],
      ['allocate', 'g-str', 100.0],
      ['edit', 'g-reordered', 'Reordered', 800.0, 900.0, 'keep'],
      ['allocate', 'g-neg', 5.0],
      ['allocate', 'g-dup', 50.0],
      ['delete', 'g-dup'],
      ['edit', 'g-str', 'Car', 8000.5, 8000.5, 'keep'],
      ['allocate', 'g-int', -1200.0],
    ],
  },
  {
    // DST: America/New_York skips 02:00-03:00 on 2026-03-08 and 2027-03-14
    // and repeats 01:00-02:00 on 2026-11-01; America/Santiago skips
    // 00:00-01:00 on 2026-09-06 and repeats 23:00-24:00 on 2026-04-04;
    // Australia/Lord_Howe skips 02:00-02:30 on 2026-10-04 and repeats
    // 01:30-02:00 on 2026-04-05. Elsewhere (Asia/Kolkata, UTC) these are
    // ordinary times.
    'name': 'dst',
    'byteComparable': true,
    'launch': [2026, 9, 6, 0, 30],
    'initial': <String, Object?>{},
    'ops': [
      ['add', 'Gap day', 100.0, [2026, 9, 6]],
      ['add', 'Fall back', 200.0, [2026, 4, 4, 23, 30]],
      ['add', 'Spring NY', 300.0, [2026, 3, 8, 2, 30]],
      ['add', 'Fall NY', 400.0, [2026, 11, 1, 1, 30]],
      ['allocate', 0, 100.0],
      ['edit', 1, 'Fall back', 200.0, 50.0, [2027, 4, 3, 23, 30]],
      ['clock', [2026, 11, 1, 1, 30]],
      ['allocate', 3, 400.0],
      ['edit', 2, 'Spring NY', 300.0, 300.0, [2027, 3, 14, 2, 30]],
      ['delete', 0],
      ['add', 'Repeated hour', 50.0, [2026, 11, 1, 1, 59]],
      ['add', 'Spring LH', 60.0, [2026, 10, 4, 2, 15]],
      ['add', 'Fall LH', 70.0, [2026, 4, 5, 1, 45]],
    ],
  },
];

/// Goals for the derived table. Each is a stored row: dates given as local
/// components become Dart's local ISO strings, strings are used as is.
final derivedGoals = <Map<String, Object?>>[
  {'id': 'a', 'name': 'Year', 'targetAmount': 1200.0, 'currentAmount': 100.0,
   'targetDate': [2026, 12, 1], 'createdAt': [2026, 1, 1, 9]},
  {'id': 'b', 'name': 'Month', 'targetAmount': 1000.0, 'currentAmount': 500.0,
   'targetDate': [2026, 3, 31], 'createdAt': [2026, 3, 1, 12]},
  {'id': 'c', 'name': 'Target day', 'targetAmount': 100.0, 'currentAmount': 99.99,
   'targetDate': [2026, 3, 15], 'createdAt': [2026, 3, 1]},
  {'id': 'd', 'name': 'Created today for today', 'targetAmount': 50.0,
   'currentAmount': 0.0, 'targetDate': [2026, 3, 15],
   'createdAt': [2026, 3, 15, 10, 30]},
  {'id': 'e', 'name': 'Created after target', 'targetAmount': 100.0,
   'currentAmount': 10.0, 'targetDate': [2026, 3, 1], 'createdAt': [2026, 4, 1]},
  {'id': 'f', 'name': 'Over-funded', 'targetAmount': 100.0, 'currentAmount': 150.0,
   'targetDate': [2026, 6, 1], 'createdAt': [2026, 1, 1],
   'completedAt': [2026, 2, 2, 8]},
  {'id': 'g', 'name': 'Zero target', 'targetAmount': 0.0, 'currentAmount': 50.0,
   'targetDate': [2026, 6, 1], 'createdAt': [2026, 1, 1]},
  {'id': 'h', 'name': 'Strings', 'targetAmount': '300', 'currentAmount': '75.5',
   'targetDate': [2026, 7, 4], 'createdAt': [2026, 2, 1, 7, 45, 0, 0, 12]},
  {'id': 'i', 'name': 'Ints', 'targetAmount': 400, 'currentAmount': 100,
   'targetDate': [2026, 9, 6], 'createdAt': [2026, 3, 8, 3]},
  {'id': 'j', 'name': 'UTC', 'targetAmount': 250.0, 'currentAmount': 60.0,
   'targetDate': '2026-03-15T00:00:00.000Z', 'createdAt': '2026-01-01T00:00:00.000Z'},
  {'id': 'k', 'name': 'Santiago gap', 'targetAmount': 100.0, 'currentAmount': 50.0,
   'targetDate': [2026, 9, 6], 'createdAt': [2026, 9, 5, 23, 30]},
  {'id': 'l', 'name': 'NY gap', 'targetAmount': 100.0, 'currentAmount': 50.0,
   'targetDate': [2026, 3, 9], 'createdAt': [2026, 3, 7, 12]},
  {'id': 'm', 'name': 'Same date as a', 'targetAmount': 500.0, 'currentAmount': 0.0,
   'targetDate': [2026, 12, 1], 'createdAt': [2026, 5, 1]},
  {'id': 'n', 'name': 'Float remainder', 'targetAmount': 0.1 + 0.2,
   'currentAmount': 0.1, 'targetDate': [2026, 4, 1], 'createdAt': [2026, 3, 1]},
  {'id': 'o', 'name': 'Exact', 'targetAmount': 100.0, 'currentAmount': 100.0,
   'targetDate': [2026, 3, 15], 'createdAt': [2026, 1, 1]},
  {'id': 'p', 'name': 'Half percent', 'targetAmount': 200.0, 'currentAmount': 1.0,
   'targetDate': [2027, 3, 15], 'createdAt': [2026, 1, 1]},
  {'id': 'q', 'name': 'Negative', 'targetAmount': -5, 'currentAmount': -1.0,
   'targetDate': [2026, 3, 16], 'createdAt': [2026, 3, 15]},
  {'id': 'r', 'name': 'Done, no stamp', 'targetAmount': 10.0, 'currentAmount': 10.0,
   'targetDate': [2026, 1, 20], 'createdAt': [2026, 1, 1]},
  // Exactly half funded over 10 days (no DST in either zone): on pace at
  // the midpoint, behind 1 ms later; 0.5 ms later truncates to on pace.
  {'id': 's', 'name': 'Boundary', 'targetAmount': 100.0, 'currentAmount': 50.0,
   'targetDate': [2026, 1, 11], 'createdAt': [2026, 1, 1]},
  // Short of the midpoint by less than the 1e-9 tolerance.
  {'id': 't', 'name': 'Epsilon', 'targetAmount': 100.0,
   'currentAmount': 49.99999995, 'targetDate': [2026, 1, 11],
   'createdAt': [2026, 1, 1]},
  // Lord Howe's 30-minute changes (ordinary times elsewhere).
  {'id': 'u', 'name': 'Lord Howe gap', 'targetAmount': 100.0, 'currentAmount': 20.0,
   'targetDate': [2026, 10, 4, 2, 15], 'createdAt': [2026, 4, 5, 1, 45]},
  {'id': 'v', 'name': 'Lord Howe fold', 'targetAmount': 100.0, 'currentAmount': 20.0,
   'targetDate': [2026, 4, 5, 1, 45], 'createdAt': [2026, 4, 4, 12]},
  // Santiago's repeated hour (ordinary times elsewhere).
  {'id': 'w', 'name': 'Santiago fold', 'targetAmount': 100.0, 'currentAmount': 20.0,
   'targetDate': [2026, 4, 5], 'createdAt': [2026, 4, 4, 23, 30]},
];

final derivedNows = <List<int>>[
  [2026, 1, 1, 9],
  [2026, 1, 6],
  [2026, 1, 6, 0, 0, 0, 0, 500],
  [2026, 1, 6, 0, 0, 0, 1],
  [2026, 3, 1],
  [2026, 3, 8, 3],
  [2026, 3, 14, 23, 59, 59, 999],
  [2026, 3, 15],
  [2026, 3, 15, 10, 30],
  [2026, 3, 15, 23, 59],
  [2026, 3, 16],
  [2026, 6, 15, 12],
  [2026, 9, 5, 23, 59],
  [2026, 9, 6, 0, 30],
  [2026, 9, 6, 12],
  [2026, 4, 4, 23, 30],
  [2026, 4, 5, 1, 45],
  [2026, 10, 4, 2, 15],
  [2026, 12, 1],
  [2026, 12, 2],
  [2027, 2, 1],
];

Map<String, Object?> storedRow(Map<String, Object?> spec) => {
      for (final e in spec.entries)
        e.key: e.value is List ? iso(local(e.value as List)) : e.value,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('goal mutations', () async {
    final out = <Map<String, Object?>>[];
    for (final scenario in scenarios) {
      out.add(await runScenario(scenario));
    }
    pinClock(null);
    writeJson('$fixturesRoot/$zoneDir/mutations.json', {
      'tz': parityTz,
      'scenarios': out,
    });
  });

  test('derived values', () {
    final rows = derivedGoals.map(storedRow).toList();
    // fromJson reads no clock for these rows (every date is present).
    pinClock(local([2020, 1, 1]));
    final goals = rows.map(SavingsGoal.fromJson).toList();
    final perGoal = <Map<String, Object?>>[];
    for (var i = 0; i < goals.length; i++) {
      final goal = goals[i];
      final remaining = goal.remainingAmount;
      final amounts = <double>[
        remaining, remaining - 0.01, remaining + 0.01, 25, 100, 0.1, 1e-7
      ];
      final atNows = <Map<String, Object?>>[];
      for (final c in derivedNows) {
        final now = local(c);
        pinClock(now);
        final paces = <String>[];
        for (final (currency, locale, hidden) in formatterConfigs) {
          MoneyFormatter.configure(
              currencyCode: currency, locale: locale, hideBalances: hidden);
          paces.add(paceCopyFor(goal));
        }
        MoneyFormatter.configure(currencyCode: 'USD');
        atNows.add({
          'now': iso(now),
          'isOverdue': goal.isOverdue,
          'status': statusFor(goal).name,
          'suggested': bitsHex(goal.suggestedMonthlyContribution),
          'paces': paces,
        });
      }
      perGoal.add({
        'row': jsonEncode(rows[i]),
        'memory': goalMemory(goal),
        'progress': bitsHex(goal.progress),
        'progressPercent': goal.progressPercent,
        'percentLabel': '${goal.progressPercent}%',
        'remaining': bitsHex(remaining),
        'isCompleted': goal.isCompleted,
        'fullyFunded': fullyFunded(goal),
        'willComplete': [
          for (final a in amounts)
            [bitsHex(a), !goal.isCompleted && a >= goal.remainingAmount]
        ],
        'atNows': atNows,
      });
    }
    pinClock(null);

    final lists = <List<SavingsGoal>>[
      goals,
      goals.reversed.toList(),
      <SavingsGoal>[],
      goals.sublist(0, 3),
      goals.where((g) => g.isCompleted).toList(),
      [goals[6]],
    ];
    writeJson('$fixturesRoot/$zoneDir/derived.json', {
      'tz': parityTz,
      'goals': perGoal,
      'lists': [
        for (final list in lists)
          {
            'ids': list.map((g) => g.id).toList(),
            'summary': summary(sortedGoals(list)),
          }
      ],
    });
  });
}
