// Emits native/Fixtures/insights/ : outputs of the real InsightEngine
// (lib/insights/insight_engine.dart) and of the real LocalInsightsSection
// (lib/widgets/local_insights_section.dart) preferences handling.
//
// Per zone (insights/tz/<zone>/):
//   cases.json   named scenarios at each rule's thresholds
//   random.json  seeded random scenarios (differential)
//   prefs.json   the section pumped with stored preferences, then driven
//                through its menu (snooze, dismiss) and reloaded at later
//                clocks: visible cards and preferences after every step
// Zone independent (from the UTC run): slugs.json, `_slug` outputs read back
// from the real engine's goal ids.
//
// Every insight is recorded in full (id, type, severity, the three strings,
// generatedDate, supportingValues as IEEE bits). `full` is the whole sorted
// candidate list (no exclusions, limit 1000), `result` the case's call. A
// call that throws (Dart's round() on NaN/Infinity) is recorded as
// {"throws": <type>}.

import 'dart:convert';
import 'dart:math';

import 'package:budget_app/insights/insight_engine.dart';
import 'package:budget_app/savings_goal.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/widgets/glow_card.dart';
import 'package:budget_app/widgets/local_insights_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

final bool writeZoneIndependent = parityTz == 'UTC';
String get zoneDir => 'insights/tz/${parityTz.replaceAll('/', '_')}';

const engine = InsightEngine();

String two(int v) => v.toString().padLeft(2, '0');
String three(int v) => v.toString().padLeft(3, '0');

/// A local wall-clock ISO string, as the app stores dates.
String local(int y, int m, int d,
        [int h = 0, int mi = 0, int s = 0, int ms = 0]) =>
    '${y.toString().padLeft(4, '0')}-${two(m)}-${two(d)}T${two(h)}:${two(mi)}:${two(s)}.${three(ms)}';

int _rowCounter = 0;

/// A stored transaction row (Transaction.toJson shape, tags/stamps omitted:
/// fromJson defaults them).
Map<String, Object?> row(
  String type,
  num amount,
  String category,
  String date, {
  String description = 'Purchase',
  String? template,
}) =>
    {
      'id': 'r${_rowCounter++}',
      'type': type,
      'description': description,
      'amount': amount,
      'category': category,
      'date': date,
      if (template != null) 'recurringTemplateId': template,
    };

Map<String, Object?> ex(num amount, String date,
        {String category = 'General',
        String description = 'Purchase',
        String? template}) =>
    row('expense', amount, category, date,
        description: description, template: template);

Map<String, Object?> inc(num amount, String date,
        {String category = 'Salary',
        String description = 'Paycheck',
        String? template}) =>
    row('income', amount, category, date,
        description: description, template: template);

Map<String, Object?> goal(
  String id, {
  String name = 'Goal',
  Object target = 1000.0,
  Object current = 0.0,
  required String createdAt,
  required String targetDate,
}) =>
    {
      'id': id,
      'name': name,
      'targetAmount': target,
      'currentAmount': current,
      'targetDate': targetDate,
      'createdAt': createdAt,
      'completedAt': null,
    };

class InsightCase {
  final String label;
  final DateTime now;
  final DateTime selectedMonth;
  final String rowsJson;
  final String goalsJson;
  final List<List<Object>> limits;
  final List<String> excluded;
  final int limit;

  InsightCase(this.label, this.now, this.selectedMonth, this.rowsJson,
      this.goalsJson, this.limits, this.excluded, this.limit);
}

InsightCase kase(
  String label, {
  DateTime? now,
  DateTime? month,
  List<Map<String, Object?>> rows = const [],
  String? rowsJson,
  List<Map<String, Object?>> goals = const [],
  String? goalsJson,
  List<List<Object>> limits = const [],
  List<String> excluded = const [],
  int limit = 3,
}) =>
    InsightCase(
      label,
      now ?? DateTime(2026, 7, 10),
      month ?? DateTime(2026, 7),
      rowsJson ?? jsonEncode(rows),
      goalsJson ?? jsonEncode(goals),
      limits,
      excluded,
      limit,
    );

Map<String, Object?> insightJson(LocalInsight i) => {
      'id': i.id,
      'type': i.type.name,
      'severity': i.severity.name,
      'headline': i.headline,
      'explanation': i.explanation,
      'action': i.suggestedAction,
      'generatedDate': iso(i.generatedDate),
      'values': [
        for (final e in i.supportingValues.entries) [e.key, bitsHex(e.value)]
      ],
    };

List<Transaction> transactionsOf(String rowsJson) => [
      for (final r in jsonDecode(rowsJson) as List)
        Transaction.fromJson(r as Map<String, dynamic>)
    ];

List<SavingsGoal> goalsOf(String goalsJson) => [
      for (final g in jsonDecode(goalsJson) as List)
        SavingsGoal.fromJson(g as Map<String, dynamic>)
    ];

Object? generateJson(InsightCase k, Set<String> excluded, int limit) {
  pinClock(k.now);
  final limits = <String, double>{
    for (final p in k.limits) p[0] as String: (p[1] as num).toDouble()
  };
  try {
    return [
      for (final i in engine.generate(
        transactions: transactionsOf(k.rowsJson),
        categoryBudgetLimits: limits,
        savingsGoals: goalsOf(k.goalsJson),
        selectedMonth: k.selectedMonth,
        now: k.now,
        excludedIds: excluded,
        limit: limit,
      ))
        insightJson(i)
    ];
  } catch (error) {
    return {'throws': error.runtimeType.toString()};
  }
}

Map<String, Object?> caseJson(InsightCase k) {
  final keys = <String>{};
  for (final p in k.limits) {
    if (!keys.add(p[0] as String)) {
      throw StateError('${k.label}: repeated limit key ${p[0]}');
    }
  }
  // Dart's List.sort is stable only up to 32 elements; beyond that equal
  // (severity, id) pairs, and equal dates in the unusual and recurring
  // sorts, come out in its quicksort's order. Swift reproduces that order
  // (DartSort), so such cases are recorded like any other.
  final full = generateJson(k, const {}, 1000);
  return {
    'label': k.label,
    'now': iso(k.now),
    'selectedMonth': iso(k.selectedMonth),
    'rows': k.rowsJson,
    'goals': k.goalsJson,
    'limits': [
      for (final p in k.limits) [p[0], bitsHex((p[1] as num).toDouble())]
    ],
    'excluded': k.excluded,
    'limit': k.limit,
    'full': full,
    'result': generateJson(k, k.excluded.toSet(), k.limit),
  };
}

// --- Named scenarios -------------------------------------------------------

List<InsightCase> namedCases() {
  _rowCounter = 0;
  final cases = <InsightCase>[];
  void add(InsightCase c) => cases.add(c);

  // The seven Dart tests (test/insight_engine_test.dart), as data.
  add(kase('dart_1_pace', rows: [
    ex(80, local(2026, 7, 5), category: 'Groceries'),
  ], limits: [
    ['Groceries', 100.0]
  ]));
  add(kase('dart_2_duplicate', rows: [
    ex(24.5, local(2026, 7, 4, 9),
        description: 'Corner Cafe', category: 'Eating Out'),
    ex(24.5, local(2026, 7, 4, 18),
        description: 'Corner Cafe', category: 'Eating Out'),
  ]));
  add(kase('dart_3_recurring', rows: [
    ex(100, local(2026, 6, 2), description: 'Internet', template: 'internet'),
    ex(120, local(2026, 7, 2), description: 'Internet', template: 'internet'),
  ]));
  add(kase('dart_4_negative_flow', rows: [
    for (final m in [5, 6, 7]) ...[
      inc(1000, local(2026, m, 1)),
      ex(1200, local(2026, m, 2)),
    ]
  ]));
  add(kase('dart_5_goal', goals: [
    goal('emergency',
        name: 'Emergency fund',
        target: 1000.0,
        current: 100.0,
        createdAt: local(2026, 1, 1),
        targetDate: local(2026, 10, 1)),
  ]));
  final dart6 = [
    ex(40, local(2026, 7, 3), description: 'Cafe'),
    ex(40, local(2026, 7, 3), description: 'Cafe'),
    ex(90, local(2026, 7, 5), category: 'Groceries'),
  ];
  add(kase('dart_6_all', rows: dart6, limits: [
    ['Groceries', 100.0]
  ], limit: 10));
  add(kase('dart_6_excluded', rows: dart6, limits: [
    ['Groceries', 100.0]
  ], excluded: [
    'budget-pace:groceries:2026-7'
  ], limit: 1));
  add(kase('dart_7_sparse', rows: [
    ex(100, local(2026, 6, 2)),
    ex(200, local(2026, 7, 2)),
  ]));

  // budgetPace.
  for (final spent in [24.99, 25.0, 25.01]) {
    add(kase('pace_spent_$spent', rows: [
      ex(spent, local(2026, 7, 5), category: 'Groceries'),
    ], limits: [
      ['Groceries', 30.0]
    ]));
  }
  for (final spent in [64.99999, 65.0, 65.00001]) {
    add(kase('pace_ratio_$spent', rows: [
      ex(spent, local(2026, 7, 5), category: 'Groceries'),
    ], limits: [
      ['Groceries', 100.0]
    ]));
  }
  // usedRatio == elapsedRatio + 0.15 exactly (1.15 on the 31st), and
  // either side; June's 30 days likewise.
  for (final spent in [114.99, 115.0, 115.01]) {
    add(kase('pace_edge_jul31_$spent',
        now: DateTime(2026, 7, 31, 23, 59, 59, 999),
        rows: [ex(spent, local(2026, 7, 1), category: 'Groceries')],
        limits: [
          ['Groceries', 100.0]
        ]));
    add(kase('pace_edge_jun30_$spent',
        now: DateTime(2026, 6, 30),
        month: DateTime(2026, 6),
        rows: [ex(spent, local(2026, 6, 1), category: 'Groceries')],
        limits: [
          ['Groceries', 100.0]
        ]));
  }
  for (final spent in [99.99999, 100.0, 250.0]) {
    add(kase('pace_urgent_$spent', rows: [
      ex(spent, local(2026, 7, 2), category: 'Groceries'),
    ], limits: [
      ['Groceries', 100.0]
    ]));
  }
  add(kase('pace_other_month',
      month: DateTime(2026, 6),
      rows: [ex(90, local(2026, 6, 5), category: 'Groceries')],
      limits: [
        ['Groceries', 100.0]
      ]));
  add(kase('pace_selected_month_not_normalised',
      month: DateTime(2026, 7, 19, 13, 45),
      rows: [ex(90, local(2026, 7, 5), category: 'Groceries')],
      limits: [
        ['Groceries', 100.0]
      ]));
  add(kase('pace_zero_negative_limits', rows: [
    ex(90, local(2026, 7, 5), category: 'Groceries'),
    ex(90, local(2026, 7, 5, 1), category: 'Travel'),
  ], limits: [
    ['Groceries', 0.0],
    ['Travel', -5.0],
  ]));
  add(kase('pace_day1',
      now: DateTime(2026, 7, 1),
      rows: [ex(30, local(2026, 7, 1), category: 'Groceries')],
      limits: [
        ['Groceries', 40.0]
      ]));
  add(kase('pace_feb_leap',
      now: DateTime(2028, 2, 29, 12),
      month: DateTime(2028, 2),
      rows: [ex(99, local(2028, 2, 3), category: 'Groceries')],
      limits: [
        ['Groceries', 100.0]
      ]));
  add(kase('pace_feb_28',
      now: DateTime(2026, 2, 28, 12),
      month: DateTime(2026, 2),
      rows: [ex(99, local(2026, 2, 3), category: 'Groceries')],
      limits: [
        ['Groceries', 100.0]
      ]));
  add(kase('pace_categories_exact', rows: [
    ex(50, local(2026, 7, 2), category: 'Groceries'),
    ex(40, local(2026, 7, 3), category: 'groceries'),
    ex(30, local(2026, 7, 4), category: 'Café'),
    ex(45, local(2026, 7, 5), category: 'Café'),
    inc(500, local(2026, 7, 6), category: 'Groceries'),
    ex(70, local(2026, 6, 6), category: 'Groceries'),
  ], limits: [
    ['Groceries', 60.0],
    ['groceries', 50.0],
    ['Café', 40.0],
    ['Café', 60.0],
  ]));
  add(kase('pace_slugs', rows: [
    ex(90, local(2026, 7, 2), category: '  Café & Bar!! '),
    ex(90, local(2026, 7, 2, 1), category: '☕️'),
    ex(90, local(2026, 7, 2, 2), category: 'İstanbul ΣΟΦΙΑ'),
    ex(90, local(2026, 7, 2, 3), category: 'Eating Out'),
    ex(90, local(2026, 7, 2, 4), category: 'eating-out'),
  ], limits: [
    ['  Café & Bar!! ', 100.0],
    ['☕️', 100.0],
    ['İstanbul ΣΟΦΙΑ', 100.0],
    ['Eating Out', 100.0],
    ['eating-out', 100.0],
  ], limit: 10));
  add(kase('pace_same_slug_excluded', rows: [
    ex(90, local(2026, 7, 2, 3), category: 'Eating Out'),
    ex(90, local(2026, 7, 2, 4), category: 'eating-out'),
  ], limits: [
    ['Eating Out', 100.0],
    ['eating-out', 100.0],
  ], excluded: [
    'budget-pace:eating-out:2026-7'
  ], limit: 10));
  add(kase('pace_float_sum', rows: [
    for (var i = 0; i < 10; i++)
      ex(0.1 * (i + 1), local(2026, 7, 1, i), category: 'Tiny'),
    ex(0.1, local(2026, 7, 2), category: 'Tiny'),
    ex(0.2, local(2026, 7, 2, 1), category: 'Tiny'),
  ], limits: [
    ['Tiny', 5.9]
  ]));

  // monthlySpendingChange.
  List<Map<String, Object?>> months(List<num> previous, List<num> current,
          {int y = 2026, int m = 7}) =>
      [
        for (var i = 0; i < previous.length; i++)
          ex(previous[i], iso(DateTime(y, m - 1, 2 + i))),
        for (var i = 0; i < current.length; i++)
          ex(current[i], local(y, m, 2 + i)),
      ];
  add(kase('change_counts_2_3', rows: months([100, 100], [200, 200, 200])));
  add(kase('change_counts_3_2', rows: months([100, 100, 100], [200, 200])));
  add(kase('change_prev_49_99', rows: months([20, 20, 9.99], [40, 40, 40])));
  add(kase('change_prev_50', rows: months([20, 20, 10], [40, 40, 40])));
  add(kase('change_plus_20', rows: months([30, 30, 40], [40, 40, 40])));
  add(kase('change_minus_20', rows: months([30, 30, 40], [30, 30, 20])));
  add(kase('change_19_999', rows: months([30, 30, 40], [40, 40, 39.999])));
  add(kase('change_half_percent', rows: months([50, 50, 100], [83, 83, 83])));
  add(kase('change_january',
      now: DateTime(2027, 1, 20),
      month: DateTime(2027, 1),
      rows: months([10, 20, 30], [100, 100, 100], y: 2027, m: 1)));
  add(kase('change_zero_negative_rows',
      rows: months([100, 0, -5], [100, 100, -1])));

  // unusualTransaction.
  List<Map<String, Object?>> history(List<num> amounts,
          {String category = 'Travel', int month = 5}) =>
      [
        for (var i = 0; i < amounts.length; i++)
          ex(amounts[i], local(2026, month, 1 + i, 10),
              category: category, description: 'Trip $i'),
      ];
  add(kase('unusual_history_3', rows: [
    ...history([10, 20, 30]),
    ex(500, local(2026, 7, 8), category: 'Travel', description: 'Big trip'),
  ]));
  add(kase('unusual_history_4_even', rows: [
    ...history([10, 20, 30, 40]),
    ex(500, local(2026, 7, 8), category: 'Travel', description: 'Big trip'),
  ]));
  add(kase('unusual_history_5_odd', rows: [
    ...history([10, 20, 30, 40, 1000]),
    ex(500, local(2026, 7, 8), category: 'Travel', description: ''),
  ]));
  add(kase('unusual_exact_2_5', rows: [
    ...history([20, 20, 20, 20]),
    ex(50, local(2026, 7, 8), category: 'Travel', description: 'Edge'),
  ]));
  add(kase('unusual_below_50', rows: [
    ...history([10, 10, 10, 10]),
    ex(49.99, local(2026, 7, 8), category: 'Travel', description: 'Small'),
  ]));
  add(kase('unusual_just_below_multiple', rows: [
    ...history([40, 40, 40, 40]),
    ex(99.99, local(2026, 7, 8), category: 'Travel', description: 'Almost'),
  ]));
  add(kase('unusual_history_filters', rows: [
    ex(10, local(2026, 5, 1), category: 'Travel'),
    ex(0, local(2026, 5, 2), category: 'Travel'),
    ex(-10, local(2026, 5, 3), category: 'Travel'),
    ex(10, local(2026, 5, 4), category: 'travel'),
    inc(10, local(2026, 5, 5), category: 'Travel'),
    ex(10, local(2026, 7, 1), category: 'Travel'),
    ex(10, local(2026, 8, 1), category: 'Travel'),
    ex(10, local(2026, 7, 8, 12), category: 'Travel'),
    ex(10, local(2026, 6, 30, 23, 59, 59, 999), category: 'Travel'),
    ex(10, local(2026, 4, 30), category: 'Travel'),
    ex(300, local(2026, 7, 8, 12), category: 'Travel', description: 'Tie'),
  ]));
  add(kase('unusual_history_filters_enough', rows: [
    ex(10, local(2026, 5, 1), category: 'Travel'),
    ex(10, local(2026, 5, 4), category: 'Travel'),
    ex(10, local(2026, 6, 30, 23, 59, 59, 999), category: 'Travel'),
    ex(10, local(2026, 4, 30), category: 'Travel'),
    ex(10, local(2026, 7, 1), category: 'Travel'),
    ex(300, local(2026, 7, 8, 12), category: 'Travel', description: 'Tie'),
  ]));
  add(kase('unusual_nfc_nfd', rows: [
    ...history([10, 10, 10, 10], category: 'Café'),
    ex(300, local(2026, 7, 8), category: 'Café', description: 'NFD'),
    ex(300, local(2026, 7, 7), category: 'Café', description: 'NFC'),
  ]));
  add(kase('unusual_newest_wins', rows: [
    ...history([10, 10, 10, 10]),
    ...history([20, 20, 20, 20], category: 'Housing'),
    ex(300, local(2026, 7, 3), category: 'Travel', description: 'Older'),
    ex(300, local(2026, 7, 9), category: 'Housing', description: 'Newer'),
  ]));
  add(kase('unusual_tie_stored_order', rows: [
    ...history([10, 10, 10, 10]),
    ...history([20, 20, 20, 20], category: 'Housing'),
    ex(300, local(2026, 7, 9), category: 'Travel', description: 'First'),
    ex(300, local(2026, 7, 9), category: 'Housing', description: 'Second'),
  ]));
  add(kase('unusual_many_expenses', rows: [
    ...history([10, 10, 10, 10]),
    for (var i = 0; i < 40; i++)
      ex(5 + i, local(2026, 7, 1 + i % 28, i % 24, i),
          category: 'Travel', description: 'Row $i'),
    ex(900, local(2026, 7, 2, 7, 7, 7), category: 'Travel', description: 'Big'),
  ]));
  add(kase('unusual_amount_formats', rows: [
    ...history([0.1, 0.2, 0.3, 0.4]),
    ex(1.005 * 100, local(2026, 7, 8), category: 'Travel', description: 'Tie'),
  ]));
  add(kase('unusual_huge', rows: [
    ...history([1, 2, 3, 4]),
    ex(1e21, local(2026, 7, 8), category: 'Travel', description: 'Huge'),
  ]));

  // savingsRateTrend.
  List<Map<String, Object?>> flow(num prevIn, num prevOut, num curIn, num curOut) => [
        if (prevIn != 0) inc(prevIn, local(2026, 6, 1)),
        if (prevOut != 0) ex(prevOut, local(2026, 6, 2)),
        if (curIn != 0) inc(curIn, local(2026, 7, 1)),
        if (curOut != 0) ex(curOut, local(2026, 7, 2)),
      ];
  add(kase('rate_delta_0_08', rows: flow(1000, 880, 1000, 800)));
  add(kase('rate_delta_0_0799', rows: flow(1000, 880, 1000, 800.1)));
  add(kase('rate_delta_minus_0_08', rows: flow(1000, 800, 1000, 880)));
  add(kase('rate_zero_income_prev', rows: flow(0, 100, 1000, 100)));
  add(kase('rate_zero_income_cur', rows: flow(1000, 100, 0, 100)));
  add(kase('rate_negative_rates', rows: flow(1000, 1500, 1000, 3000)));
  add(kase('rate_improving', rows: flow(1000, 900, 2000, 500)));

  // recurringAmountChange.
  add(kase('recurring_4_9_percent_10_dollars', rows: [
    ex(204, local(2026, 6, 2), description: 'Gym', template: 'gym'),
    ex(214, local(2026, 7, 2), description: 'Gym', template: 'gym'),
  ]));
  add(kase('recurring_small', rows: [
    ex(100, local(2026, 6, 2), description: 'Gym', template: 'gym'),
    ex(104.99, local(2026, 7, 2), description: 'Gym', template: 'gym'),
  ]));
  add(kase('recurring_unchanged', rows: [
    ex(100, local(2026, 6, 2), description: 'Gym', template: 'gym'),
    ex(100, local(2026, 7, 2), description: 'Gym', template: 'gym'),
  ]));
  add(kase('recurring_0_percent_big', rows: [
    ex(1500000, local(2026, 6, 2), description: 'Mortgage', template: 'm'),
    ex(1506000, local(2026, 7, 2), description: 'Mortgage', template: 'm'),
  ]));
  add(kase('recurring_previous_zero_negative', rows: [
    ex(0, local(2026, 6, 2), description: 'Z', template: 'z'),
    ex(100, local(2026, 7, 2), description: 'Z', template: 'z'),
    ex(-5, local(2026, 6, 2), description: 'N', template: 'n'),
    ex(100, local(2026, 7, 2), description: 'N', template: 'n'),
  ]));
  add(kase('recurring_three_occurrences_mixed', rows: [
    ex(50, local(2026, 7, 2), description: 'Newest', template: 'mix'),
    inc(80, local(2026, 5, 2), description: 'Oldest', template: 'mix'),
    inc(100, local(2026, 6, 2), description: 'Middle', template: 'mix'),
    ex(10, local(2026, 3, 2), description: 'Alone', template: 'alone'),
  ]));
  add(kase('recurring_slugs', rows: [
    for (final id in ['Rent 2026!', '日本', '', '  --  ', 'rent-2026']) ...[
      ex(100, local(2026, 6, 2), description: 'T[$id]', template: id),
      ex(150, local(2026, 7, 2), description: 'T[$id]', template: id),
    ]
  ], limit: 10));
  add(kase('recurring_other_year',
      month: DateTime(2026, 7),
      rows: [
        ex(100, local(2025, 11, 2), description: 'Old', template: 'old'),
        ex(80, local(2025, 12, 2), description: 'Old', template: 'old'),
      ]));
  add(kase('recurring_equal_dates', rows: [
    ex(100, local(2026, 7, 2), description: 'First', template: 'tie'),
    ex(200, local(2026, 7, 2), description: 'Second', template: 'tie'),
    ex(300, local(2026, 6, 2), description: 'Older', template: 'tie'),
  ]));
  add(kase('recurring_nfc_nfd_templates', rows: [
    ex(100, local(2026, 6, 2), description: 'NFC', template: 'café'),
    ex(200, local(2026, 7, 2), description: 'NFD', template: 'café'),
  ]));

  // consistentlyUnderBudget.
  List<Map<String, Object?>> under(List<num> spent,
          {String category = 'Dining', int y = 2026, int m = 7}) =>
      [
        for (var i = 0; i < spent.length; i++)
          if (spent[i] != 0)
            ex(spent[i], iso(DateTime(y, m - 1 - i, 10)), category: category),
      ];
  add(kase('under_three', rows: under([10, 20, 30]), limits: [
    ['Dining', 100.0]
  ]));
  add(kase('under_empty_month', rows: under([10, 0, 30]), limits: [
    ['Dining', 100.0]
  ]));
  add(kase('under_exact_0_7', rows: under([10, 70, 30]), limits: [
    ['Dining', 100.0]
  ]));
  add(kase('under_0_6999', rows: under([10, 69.99, 30]), limits: [
    ['Dining', 100.0]
  ]));
  add(kase('under_january',
      now: DateTime(2027, 1, 3),
      month: DateTime(2027, 1),
      rows: under([10, 20, 30], y: 2027, m: 1),
      limits: [
        ['Dining', 100.0]
      ]));
  add(kase('under_round_half', rows: under([12.5, 12.5, 12.5]), limits: [
    ['Dining', 100.0]
  ]));
  add(kase('under_any_selected_month',
      month: DateTime(2025, 3),
      rows: under([10, 20, 30], y: 2025, m: 3),
      limits: [
        ['Dining', 100.0]
      ]));

  // goalBehindSchedule.
  for (final created in [local(2026, 6, 26), local(2026, 6, 27)]) {
    add(kase('goal_elapsed_$created', goals: [
      goal('g', createdAt: created, targetDate: local(2026, 8, 1)),
    ]));
  }
  add(kase('goal_duration_zero_negative', goals: [
    goal('same', createdAt: local(2026, 1, 1), targetDate: local(2026, 1, 1)),
    goal('back', createdAt: local(2026, 2, 1), targetDate: local(2026, 1, 1)),
  ]));
  add(kase('goal_completed_and_zero_target', goals: [
    goal('done',
        target: 100.0,
        current: 100.0,
        createdAt: local(2026, 1, 1),
        targetDate: local(2026, 12, 1)),
    goal('zero',
        target: 0.0,
        current: 0.0,
        createdAt: local(2026, 1, 1),
        targetDate: local(2026, 12, 1)),
  ]));
  add(kase('goal_overdue_and_today', goals: [
    goal('overdue', createdAt: local(2026, 1, 1), targetDate: local(2026, 7, 9)),
    goal('today',
        createdAt: local(2026, 1, 1),
        targetDate: local(2026, 7, 10, 15)),
    goal('midnight',
        createdAt: local(2026, 1, 1, 18, 30),
        targetDate: local(2026, 7, 10)),
  ], limit: 10));
  // progress + 0.1 == expected (50 of 100 days, no DST in the span).
  for (final current in [399.99, 400.0, 400.01]) {
    add(kase('goal_boundary_$current',
        now: DateTime(2026, 6, 20, 8),
        month: DateTime(2026, 6),
        goals: [
          goal('b',
              current: current,
              createdAt: local(2026, 5, 1),
              targetDate: local(2026, 8, 9)),
        ]));
  }
  add(kase('goal_dst_spans', goals: [
    goal('ny', createdAt: local(2026, 3, 1), targetDate: local(2026, 3, 29)),
    goal('santiago',
        createdAt: local(2026, 3, 20), targetDate: local(2026, 4, 20)),
    goal('lord-howe',
        createdAt: local(2026, 3, 30), targetDate: local(2026, 4, 30)),
    goal('long', createdAt: local(2025, 7, 1), targetDate: local(2026, 11, 30)),
  ], now: DateTime(2026, 4, 12, 7), month: DateTime(2026, 4), limit: 10));
  add(kase('goal_slugged_ids', goals: [
    goal('savings_goal_mf2x1k_0',
        name: 'Trip ☕️', createdAt: local(2026, 1, 1), targetDate: local(2026, 12, 1)),
    goal('  ', name: '', createdAt: local(2026, 1, 1), targetDate: local(2026, 12, 1)),
  ], limit: 10));
  add(kase('goal_nan_progress_throws',
      goalsJson: jsonEncode([
        goal('nan',
            target: 'NaN',
            current: 10.0,
            createdAt: local(2026, 1, 1),
            targetDate: local(2026, 12, 1)),
      ])));
  add(kase('goal_string_amounts',
      goalsJson: jsonEncode([
        goal('str',
            target: '1000',
            current: '12.5',
            createdAt: local(2026, 1, 1),
            targetDate: local(2026, 12, 1)),
      ])));

  // negativeCashFlow.
  add(kase('negative_zero_income_month', rows: [
    for (final m in [5, 6, 7]) ...[
      if (m != 6) inc(1000, local(2026, m, 1)),
      ex(1200, local(2026, m, 2)),
    ]
  ]));
  add(kase('negative_net_zero', rows: [
    for (final m in [5, 6, 7]) ...[
      inc(1000, local(2026, m, 1)),
      ex(m == 5 ? 1000 : 1200, local(2026, m, 2)),
    ]
  ]));
  add(kase('negative_across_year',
      now: DateTime(2026, 2, 3),
      month: DateTime(2026, 2),
      rows: [
        for (final d in [DateTime(2025, 12), DateTime(2026, 1), DateTime(2026, 2)]) ...[
          inc(10, local(d.year, d.month, 1)),
          ex(10.01, local(d.year, d.month, 2)),
        ]
      ]));

  // possibleDuplicate.
  add(kase('dup_three_and_four', rows: [
    for (var i = 0; i < 3; i++)
      ex(12, local(2026, 7, 4, 8 + i), description: 'Lunch'),
    for (var i = 0; i < 4; i++)
      ex(3, local(2026, 7, 5, 8 + i), description: 'Coffee'),
  ], limit: 10));
  add(kase('dup_three_excluded', rows: [
    for (var i = 0; i < 3; i++)
      ex(12, local(2026, 7, 4, 8 + i), description: 'Lunch'),
  ], excluded: [
    'duplicate:expense:lunch:12.00:${local(2026, 7, 4)}'
  ], limit: 10));
  add(kase('dup_description_variants', rows: [
    ex(5, local(2026, 7, 6, 8), description: 'Coffee!'),
    ex(5, local(2026, 7, 6, 9), description: ' COFFEE '),
    ex(5, local(2026, 7, 6, 10), description: 'coffee'),
    ex(5, local(2026, 7, 6, 11), description: 'Coffeé'),
    ex(5, local(2026, 7, 6, 12), description: 'İstanbul'),
    ex(5, local(2026, 7, 6, 13), description: 'istanbul'),
    ex(5, local(2026, 7, 6, 14), description: ''),
    ex(5, local(2026, 7, 6, 15), description: '☕️'),
  ], limit: 10));
  add(kase('dup_day_and_month_edges', rows: [
    ex(7, local(2026, 7, 7, 23, 59, 59, 999), description: 'Edge'),
    ex(7, local(2026, 7, 8), description: 'Edge'),
    ex(7, local(2026, 6, 30, 12), description: 'Edge'),
    ex(7, local(2026, 7, 1, 12), description: 'Month'),
    ex(7, local(2026, 6, 1, 12), description: 'Month'),
    inc(7, local(2026, 7, 9, 1), description: 'Mixed'),
    ex(7, local(2026, 7, 9, 2), description: 'Mixed'),
  ], limit: 10));
  add(kase('dup_amount_formats', rows: [
    ex(0.1 + 0.2, local(2026, 7, 10, 1), description: 'Float'),
    ex(0.3, local(2026, 7, 10, 2), description: 'Float'),
    ex(1.005, local(2026, 7, 11, 1), description: 'Tie'),
    ex(1.0, local(2026, 7, 11, 2), description: 'Tie'),
    ex(1e21, local(2026, 7, 12, 1), description: 'Huge'),
    ex(1e21, local(2026, 7, 12, 2), description: 'Huge'),
    ex(0, local(2026, 7, 13, 1), description: 'Zero'),
    ex(0, local(2026, 7, 13, 2), description: 'Zero'),
    ex(-5, local(2026, 7, 14, 1), description: 'Neg'),
    ex(-5, local(2026, 7, 14, 2), description: 'Neg'),
    ex(-0.001, local(2026, 7, 15, 1), description: 'NegZero'),
    ex(0, local(2026, 7, 15, 2), description: 'NegZero'),
  ], limit: 10));
  add(kase('dup_utc_rows', rows: [
    ex(9, '2026-07-04T23:30:00.000Z', description: 'Zulu'),
    ex(9, '2026-07-04T01:30:00.000Z', description: 'Zulu'),
    ex(9, '2026-07-31T23:30:00.000Z', description: 'Late'),
    ex(9, '2026-07-31T22:30:00.000Z', description: 'Late'),
  ], limit: 10));
  add(kase('dup_santiago_gap_day',
      now: DateTime(2026, 9, 10),
      month: DateTime(2026, 9),
      rows: [
        ex(4, local(2026, 9, 6, 10), description: 'Gap'),
        ex(4, local(2026, 9, 6, 11), description: 'Gap'),
        ex(4, local(2026, 9, 6, 0, 30), description: 'Skipped'),
        ex(4, local(2026, 9, 6, 1, 30), description: 'Skipped'),
      ],
      limit: 10));
  add(kase('dup_fold_days',
      now: DateTime(2026, 11, 10),
      month: DateTime(2026, 11),
      rows: [
        ex(4, local(2026, 11, 1, 1, 30), description: 'Fold'),
        ex(4, local(2026, 11, 1, 23), description: 'Fold'),
      ],
      limit: 10));
  add(kase('dup_overflow_throws',
      rowsJson: '[${[
        for (var i = 0; i < 2; i++)
          '{"id":"inf$i","type":"expense","description":"Inf","amount":1e400,'
              '"category":"Groceries","date":"${local(2026, 7, 2, i)}"}'
      ].join(',')}]',
      limits: [
        ['Groceries', 100.0]
      ]));
  add(kase('dup_overflow_no_round',
      rowsJson: '[${[
        for (var i = 0; i < 2; i++)
          '{"id":"inf$i","type":"expense","description":"Inf","amount":1e400,'
              '"category":"Groceries","date":"${local(2026, 7, 2, i)}"}'
      ].join(',')}]'));
  add(kase('pace_saturated_percent', rows: [
    ex(1e300, local(2026, 7, 2), category: 'Groceries'),
  ], limits: [
    ['Groceries', 1e-5]
  ]));

  // Ordering, exclusions and limits over one mixed dataset.
  final mixed = [
    for (final m in [5, 6, 7]) ...[
      inc(1000, local(2026, m, 1)),
      ex(1100, local(2026, m, 2), category: 'Rent'),
    ],
    ex(30, local(2026, 4, 10), category: 'Dining'),
    ex(30, local(2026, 5, 10), category: 'Dining'),
    ex(30, local(2026, 6, 10), category: 'Dining'),
    ex(90, local(2026, 7, 3), category: 'Groceries'),
    ex(12, local(2026, 7, 4, 8), description: 'Lunch'),
    ex(12, local(2026, 7, 4, 9), description: 'Lunch'),
    ex(12, local(2026, 7, 4, 10), description: 'Brunch'),
    ex(12, local(2026, 7, 4, 11), description: 'Brunch'),
  ];
  final mixedLimits = [
    ['Groceries', 100.0],
    ['Dining', 100.0],
  ];
  final mixedGoals = [
    goal('late', createdAt: local(2026, 1, 1), targetDate: local(2026, 6, 1)),
  ];
  for (final limit in [-1, 0, 1, 3, 10]) {
    add(kase('mixed_limit_$limit',
        rows: mixed, limits: mixedLimits, goals: mixedGoals, limit: limit));
  }
  add(kase('mixed_exclude_top_two',
      rows: mixed,
      limits: mixedLimits,
      goals: mixedGoals,
      excluded: ['goal-behind:late', 'negative-flow:2026-7', 'nothing'],
      limit: 3));
  add(kase('mixed_exclude_unknown',
      rows: mixed,
      limits: mixedLimits,
      goals: mixedGoals,
      excluded: ['NEGATIVE-FLOW:2026-7', 'negative-flow:2026-07', ''],
      limit: 3));

  // Degenerate inputs.
  add(kase('empty'));
  add(kase('single_row', rows: [ex(10, local(2026, 7, 1))]));
  add(kase('goals_only',
      goals: mixedGoals,
      month: DateTime(2020, 1),
      now: DateTime(2026, 7, 10, 23, 59, 59, 999, 999)));
  add(kase('far_years',
      now: DateTime(2026, 7, 10),
      month: DateTime(1, 7),
      rows: [
        ex(10, local(1, 7, 1), description: 'Year one'),
        ex(10, local(1, 7, 1, 1), description: 'Year one'),
      ]));
  // Ties beyond Dart's 32-element insertion sort (DartSort in Swift).
  // Repeated duplicate ids beyond 32 candidates: equal (severity, id)
  // pairs whose explanations differ, in Dart's quicksort tie order.
  add(kase('duplicate_one_key_many', rows: [
    for (var i = 0; i < 40; i++)
      ex(4.5, local(2026, 7, 6, i % 24),
          description: 'Coffee${'!' * i}', category: 'Eating Out'),
  ]));
  add(kase('duplicate_17_triples', rows: [
    for (var k = 0; k < 17; k++) ...[
      ex(10 + k, local(2026, 7, 1 + k), description: 'Shop $k'),
      ex(10 + k, local(2026, 7, 1 + k, 12), description: 'shop $k'),
      ex(10 + k, local(2026, 7, 1 + k, 18), description: 'SHOP $k!'),
    ],
  ]));
  // 34+ expenses on one instant: the date sort's tie order (Dart's
  // quicksort beyond 32 elements) decides which candidate is tried first.
  add(kase('unusual_same_instant_one_qualifies', rows: [
    ...history([10, 10, 10, 10]),
    for (var i = 0; i < 40; i++) ...[
      if (i == 23)
        ex(900, local(2026, 7, 8, 12), category: 'Travel', description: 'Big'),
      ex(5 + i, local(2026, 7, 8, 12), category: 'Travel', description: 'Row $i'),
    ],
  ]));
  add(kase('unusual_same_instant_all_qualify', rows: [
    ...history([10, 10, 10, 10]),
    for (var i = 0; i < 40; i++)
      ex(60 + i, local(2026, 7, 8, 12),
          category: 'Travel', description: 'Row $i'),
  ]));
  // 40 occurrences on one instant: which two are "latest" and "previous"
  // is Dart's quicksort tie order.
  add(kase('recurring_same_instant_many', rows: [
    ex(50, local(2026, 6, 2), description: 'Older', template: 'bulk'),
    for (var i = 0; i < 40; i++)
      ex(100 + i * 7, local(2026, 7, 2, 9),
          description: 'Bulk $i', template: 'bulk'),
  ]));
  return cases;
}

// --- Random differential --------------------------------------------------

const randomCategories = [
  'Groceries',
  'groceries',
  'Eating Out',
  'Café',
  'Café',
  'Travel',
  'Housing',
  '☕ Coffee',
  'Salary',
  '',
];
const randomDescriptions = [
  'Coffee',
  'coffee!',
  'Rent',
  "Trader Joe's",
  'İstanbul',
  'Straße',
  'ΣΟΦΙΑ',
  '',
  '  padded  ',
  'Paycheck',
];
const randomAmounts = [
  5.0, 10.0, 10.0, 24.99, 25.0, 50.0, 65.0, 100.0, 120.0, 200.0, 0.0, -3.0,
  0.30000000000000004, 0.3, 1.005, 1.0, 1000.0, 12.5,
];
const randomTemplates = ['rent', 'internet', 'Gym 24/7', ''];

List<InsightCase> randomCases(int count) {
  final random = Random(9090 + parityTz.codeUnits.fold(0, (a, b) => a + b));
  T pick<T>(List<T> list) => list[random.nextInt(list.length)];
  final cases = <InsightCase>[];
  var attempt = 0;
  while (cases.length < count) {
    attempt++;
    final selected = DateTime(2025 + random.nextInt(3), 1 + random.nextInt(12));
    final nowRoll = random.nextInt(10);
    final nowMonth = nowRoll < 6
        ? selected
        : DateTime(selected.year, selected.month + (nowRoll < 8 ? 1 : -2));
    final now = DateTime(nowMonth.year, nowMonth.month, 1 + random.nextInt(28),
        random.nextInt(24), random.nextInt(60), random.nextInt(60),
        random.nextInt(1000), random.nextInt(1000));
    final rows = <Map<String, Object?>>[];
    final n = random.nextInt(46);
    for (var i = 0; i < n; i++) {
      // Duplicate an earlier row's key sometimes (a later time that day).
      if (rows.isNotEmpty && random.nextInt(5) == 0) {
        final source = rows[random.nextInt(rows.length)];
        final date = (source['date'] as String);
        rows.add({
          ...source,
          'id': 'x$i',
          'date': '${date.substring(0, 11)}${two(random.nextInt(24))}:'
              '${two(random.nextInt(60))}:${two(random.nextInt(60))}.${three(i)}'
              '${date.endsWith('Z') ? 'Z' : ''}',
        });
        continue;
      }
      const offsets = [0, 0, 0, 0, -1, -1, -1, -2, -2, -3, -4, 1];
      final month = DateTime(selected.year, selected.month + pick(offsets));
      final zulu = random.nextInt(20) == 0;
      final date = '${local(month.year, month.month, 1 + random.nextInt(28), random.nextInt(24), random.nextInt(60), random.nextInt(60), i)}${zulu ? 'Z' : ''}';
      final amount = random.nextInt(3) == 0
          ? random.nextInt(50000) / 100
          : pick(randomAmounts);
      rows.add({
        'id': 'x$i',
        'type': random.nextInt(5) == 0 ? 'income' : 'expense',
        'description': pick(randomDescriptions),
        'amount': amount,
        'category': pick(randomCategories),
        'date': date,
        if (random.nextInt(4) == 0) 'recurringTemplateId': pick(randomTemplates),
      });
    }
    final limits = <List<Object>>[];
    final used = <String>{};
    for (var i = random.nextInt(4); i > 0; i--) {
      final key = pick(randomCategories);
      if (!used.add(key)) continue;
      limits.add([
        key,
        random.nextInt(3) == 0
            ? random.nextInt(60000) / 100
            : pick(const [0.0, 30.0, 50.0, 100.0, 150.0, 500.0]),
      ]);
    }
    final goals = <Map<String, Object?>>[];
    for (var i = random.nextInt(3); i > 0; i--) {
      final created = DateTime(2025, 1 + random.nextInt(24), 1 + random.nextInt(28),
          random.nextInt(24), random.nextInt(60));
      final target = created.add(Duration(
          days: random.nextInt(420) - 10, hours: random.nextInt(24)));
      goals.add(goal('g_${attempt}_$i',
          name: pick(randomDescriptions),
          target: pick(const [0.0, 100.0, 1000.0]),
          current: pick(const [0.0, 50.0, 100.0, 400.0, 1000.0, 1500.0]),
          createdAt: iso(created),
          targetDate: iso(target)));
    }
    final base = kase('random_$attempt',
        now: now, month: selected, rows: rows, goals: goals, limits: limits);
    final full = generateJson(base, const {}, 1000);
    if (full is! List) continue;
    final ids = [for (final i in full) (i as Map)['id'] as String];
    final excluded = <String>[
      if (ids.isNotEmpty && random.nextInt(3) == 0) ids[random.nextInt(ids.length)],
      if (ids.length > 1 && random.nextInt(4) == 0) ids[random.nextInt(ids.length)],
      if (random.nextInt(5) == 0) 'unknown:${random.nextInt(10)}',
    ];
    cases.add(InsightCase(base.label, base.now, base.selectedMonth,
        base.rowsJson, base.goalsJson, limits, excluded,
        pick(const [3, 3, 3, 3, 1, 0, 5, -1, 10])));
  }
  return cases;
}

// --- Slugs ----------------------------------------------------------------

/// `_slug` is private; the real engine prints it in `goal-behind:<slug>`.
String engineSlug(String value) {
  final insights = engine.generate(
    transactions: const [],
    categoryBudgetLimits: const {},
    savingsGoals: [
      SavingsGoal(
        id: value,
        name: 'Slug',
        targetAmount: 1000,
        currentAmount: 0,
        targetDate: DateTime(2026, 12, 31),
        createdAt: DateTime(2026, 1, 1),
      ),
    ],
    selectedMonth: DateTime(2026, 7),
    now: DateTime(2026, 7, 10),
  );
  final id = insights.single.id;
  if (!id.startsWith('goal-behind:')) throw StateError(id);
  return id.substring('goal-behind:'.length);
}

List<String> slugInputs() {
  final fixed = [
    '',
    '   ',
    'Groceries',
    '  Rent 2026! ',
    '--a--b--',
    'A_B-C.D',
    '123',
    'İstanbul',
    'Kelvin',
    'Straße',
    'ΣΟΦΙΑ',
    'áb',
    'Ａｂｃ',
    '☕️ Coffee',
    '﻿x﻿',
    ' a　',
    '\tTab\nNew\rLine',
    'Ω',
    'ǅ',
    'Ⅻ',
    'savings_goal_mf2x1k_0',
    'UPPER lower MiXeD',
    '😀a😀',
    'x' * 200,
  ];
  final random = Random(4711);
  const pool = [
    'a', 'Z', '0', '9', '-', '_', ' ', '.', 'é', 'é', 'İ', 'ß', 'Σ',
    '☕', '😀', ' ', '﻿', '\t', 'K', 'Ω', 'Ａ', '/', '#',
  ];
  return [
    ...fixed,
    for (var i = 0; i < 200; i++)
      [for (var j = random.nextInt(12); j > 0; j--) pool[random.nextInt(pool.length)]]
          .join(),
  ];
}

// --- Preferences through the real section ----------------------------------

/// Visible cards: the three strings of each, in order.
List<List<String>> visibleCards(WidgetTester tester) {
  final cards = find.descendant(
      of: find.byType(LocalInsightsSection), matching: find.byType(GlowCard));
  return [
    for (var i = 0; i < cards.evaluate().length; i++)
      [
        for (final element in find
            .descendant(of: cards.at(i), matching: find.byType(Text))
            .evaluate())
          (element.widget as Text).data!
      ]
  ];
}

Future<void> pumpSection(WidgetTester tester, TransactionModel model) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: LocalInsightsSection(model: model),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> chooseMenuItem(WidgetTester tester, int index, String item) async {
  await tester.tap(find.byTooltip('Insight options').at(index));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text(item).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Map<String, Object> insightPrefs(Map<String, Object> typed) => {
      for (final e in typed.entries)
        if (e.key.contains('local_insights')) e.key: e.value
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pinClock(null);
  });

  test('cases', () {
    writeJson('$fixturesRoot/$zoneDir/cases.json', {
      'tz': parityTz,
      'commit': parityCommit,
      'cases': [for (final c in namedCases()) caseJson(c)],
    });
  });

  test('random', () {
    final cases = randomCases(300);
    writeCompactJson('$fixturesRoot/$zoneDir/random.json', {
      'tz': parityTz,
      'commit': parityCommit,
      'cases': [for (final c in cases) caseJson(c)],
    });
  });

  test('slugs', () {
    if (!writeZoneIndependent) return;
    writeJson('$fixturesRoot/insights/slugs.json', {
      'commit': parityCommit,
      'slugs': [
        for (final input in slugInputs()) [input, engineSlug(input)]
      ],
    });
  });

  testWidgets('preferences through LocalInsightsSection', (tester) async {
    tester.view.physicalSize = const Size(402 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final scenarios = <Object?>[];
    for (final start in [
      DateTime(2026, 7, 10, 9),
      DateTime(2026, 10, 20, 9, 0, 0, 123, 456),
      DateTime(2026, 3, 20, 23, 30),
      DateTime(2026, 8, 20, 0, 15),
    ]) {
      _rowCounter = 0;
      final rows = [
        for (final (i, name) in ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo'].indexed)
          for (final hour in [8, 12])
            ex(10, local(start.year, start.month, 1 + i, hour), description: name),
      ];
      final rowsJson = jsonEncode(rows);
      final selected = DateTime(start.year, start.month);
      final ids = [
        for (final i in engine.generate(
          transactions: transactionsOf(rowsJson),
          categoryBudgetLimits: const {},
          savingsGoals: const [],
          selectedMonth: selected,
          now: start,
          limit: 100,
        ))
          i.id
      ];
      final a = ids[0], b = ids[1], c = ids[2], d = ids[3];
      String at(Duration offset) => iso(start.add(offset));
      final future = at(const Duration(days: 1));
      final past = at(const Duration(days: -1));
      final initials = <String, Map<String, Object>>{
        'absent': {},
        'dismissed_messy': {
          'local_insights_dismissed_v1': ['zzz-unknown', b, a, b, 'Ω-foreign', 'K'],
        },
        'snoozed_empty_string': {'local_insights_snoozed_v1': ''},
        'snoozed_invalid': {'local_insights_snoozed_v1': 'not json'},
        'snoozed_list': {'local_insights_snoozed_v1': '[]'},
        'snoozed_string': {'local_insights_snoozed_v1': '"x"'},
        'snoozed_number': {'local_insights_snoozed_v1': '5'},
        'snoozed_null': {'local_insights_snoozed_v1': 'null'},
        'snoozed_empty_object': {'local_insights_snoozed_v1': '{}'},
        'snoozed_bom': {
          'local_insights_snoozed_v1': '﻿${jsonEncode({a: future})}'
        },
        'snoozed_whitespace': {
          'local_insights_snoozed_v1': ' \n${jsonEncode({a: future})}\t '
        },
        'snoozed_states': {
          'local_insights_snoozed_v1': jsonEncode({
            a: future,
            b: past,
            c: iso(start),
            d: at(const Duration(microseconds: 1)),
          }),
        },
        'snoozed_type_abort': {
          'local_insights_snoozed_v1': '{"$a":"$future","x":5,"$b":"$future"}'
        },
        'snoozed_null_value': {
          'local_insights_snoozed_v1': '{"$a":"$future","x":null,"$b":"$future"}'
        },
        'snoozed_nested_value': {
          'local_insights_snoozed_v1':
              '{"$a":"$future","x":{"y":"$future"},"$b":"$future"}'
        },
        'snoozed_bad_dates': {
          'local_insights_snoozed_v1':
              '{"$a":"garbage","$b":"","$c":"$future","$d":"2026-13-45"}'
        },
        'snoozed_duplicate_keys': {
          'local_insights_snoozed_v1':
              '{"$a":"$past","$b":"$future","$a":"$future"}'
        },
        'snoozed_date_forms': {
          'local_insights_snoozed_v1': jsonEncode({
            a: iso(start.toUtc().add(const Duration(hours: 1))),
            b: '${iso(start.add(const Duration(days: 2))).substring(0, 19)}+05:30',
            c: '20991001',
            d: '2099-10-01 09:00',
            'unused': iso(start.toUtc().subtract(const Duration(hours: 1))),
          }),
        },
        'both': {
          'local_insights_dismissed_v1': [a],
          'local_insights_snoozed_v1': jsonEncode({b: future, 'other': past}),
        },
      };
      final cases = <Object?>[];
      for (final entry in initials.entries) {
        SharedPreferences.setMockInitialValues(Map.of(entry.value));
        final model = TransactionModel()
          ..transactions = transactionsOf(rowsJson)
          ..selectedMonth = selected;
        final steps = <Object?>[];
        Future<void> record(String op, {int? index, String? atIso}) async {
          steps.add({
            'op': op,
            if (index != null) 'index': index,
            if (atIso != null) 'at': atIso,
            'cards': visibleCards(tester),
            'prefs': insightPrefs(await dumpPrefs()),
          });
        }

        pinClock(start);
        await pumpSection(tester, model);
        await record('load');
        if (visibleCards(tester).isNotEmpty) {
          await chooseMenuItem(tester, 0, 'Snooze for 30 days');
          await record('snooze', index: 0);
        }
        if (visibleCards(tester).isNotEmpty) {
          await chooseMenuItem(tester, 0, 'Dismiss');
          await record('dismiss', index: 0);
        }
        if (visibleCards(tester).length > 1) {
          await chooseMenuItem(tester, 1, 'Snooze for 30 days');
          await record('snooze', index: 1);
        }
        for (final offset in [
          const Duration(days: 30) - const Duration(microseconds: 1),
          const Duration(days: 30),
          const Duration(days: 45),
        ]) {
          final later = start.add(offset);
          pinClock(later);
          await pumpSection(tester, model);
          await record('reload', atIso: iso(later));
        }
        cases.add({
          'label': entry.key,
          'initial': typedPrefs(entry.value),
          'steps': steps,
        });
      }
      scenarios.add({
        'start': iso(start),
        'selectedMonth': iso(selected),
        'rows': rowsJson,
        'cases': cases,
      });
    }
    await tester.pumpWidget(const SizedBox());
    writeCompactJson('$fixturesRoot/$zoneDir/prefs.json', {
      'tz': parityTz,
      'commit': parityCommit,
      'scenarios': scenarios,
    });
  });
}
