// Emits native/Fixtures/spend/ : expected outputs of the real Flutter Spend
// tab (CategoryPage) and its donut (CategoryDonutChart), for fixed inputs.
// Runs under America/New_York (the zone of the Swift test calendar).
//
// - breakdowns.json: each dataset is loaded through the app's own launch
//   path (AppHarness), then the real CategoryPage is pumped and everything
//   it renders is read back: month pill, donut inputs (slices, totals,
//   previous month), centre texts, delta pill, row titles/subtitles/amounts,
//   icon and bar colours, bar values, tail and expanded rows, the centre
//   label and row tint for each selectable slice. The page keeps its maths
//   private and inline (category_page.dart:60-154), so the bits of values
//   it never exposes (record percentages, amounts past rank 5) come from a
//   verbatim mirror below, which is checked against the rendered page in
//   this test before anything is written.
// - donut.json: the real CategoryDonutChart pumped alone at the origin.
//   Taps at chosen points report what `_handleTapUp` did; the arcs are the
//   drawArc calls of the real painter on a recording canvas, frame by frame
//   through the sweep-in.
// - strings.json: Dart VM String.hashCode (the colour fallback) and
//   toUpperCase (the selected slice label) over a corpus / every scalar.

import 'dart:convert';
import 'dart:math' as math;

import 'package:budget_app/category_page.dart';
import 'package:budget_app/common.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/widgets/budgie_header.dart';
import 'package:budget_app/widgets/category_donut_chart.dart';
import 'package:budget_app/widgets/glow_card.dart';
import 'package:budget_app/widgets/glow_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

String? maybeBits(double? d) => d == null ? null : bitsHex(d);

String argb(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0');

// --- Verbatim mirror of category_page.dart:60-115 and :131-154 -------------
// Colours are replaced by where they come from: `colorIndex` is the index
// into getChartColors that :92-103 picks (before the rank palette of
// :119-129 overrides ranks 0..5). Everything else is copied as written.

Map<String, Object?> mirrorBreakdown(TransactionModel model, DateTime month) {
  // :60-64
  final Map<String, double> expensesPerCategory =
      model.getCategoryExpensesForMonth(month);
  final double totalAmount =
      expensesPerCategory.values.fold(0.0, (sum, value) => sum + value);

  // :66-76
  final Map<String, int> transactionCounts = {};
  for (final transaction in model
      .getTransactionsForMonth(month)
      .where((t) => t.type == TransactionTyp.expense)) {
    transactionCounts.update(
      transaction.category,
      (existing) => existing + 1,
      ifAbsent: () => 1,
    );
  }

  // :78-87
  final DateTime previousMonth = DateTime(month.year, month.month - 1);
  final List<Transaction> previousMonthTransactions =
      model.getTransactionsForMonth(previousMonth);
  final double? previousMonthTotal = previousMonthTransactions.isEmpty
      ? null
      : previousMonthTransactions
          .where((t) => t.type == TransactionTyp.expense)
          .fold<double>(0.0, (sum, t) => sum + t.amount);

  // :92-97 (chartColors.length == 14 in both themes)
  const chartLength = 14;
  final Map<String, int> categoryColorMap = {
    for (int i = 0; i < expenseCategories.length; i++)
      expenseCategories.keys.elementAt(i): i % chartLength,
  };

  // :100-115
  final records = expensesPerCategory.entries.map((entry) {
    final colorIndex = categoryColorMap[entry.key] ??
        entry.key.hashCode.abs() % chartLength;
    return (
      category: entry.key,
      amount: entry.value,
      percentage: totalAmount > 0 ? (entry.value / totalAmount) * 100 : 0.0,
      colorIndex: colorIndex,
      fromHash: !categoryColorMap.containsKey(entry.key),
      count: transactionCounts[entry.key] ?? 0,
      budgetLimit: model.getCategoryBudgetLimit(entry.key),
    );
  }).toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));

  // :131, :136-154
  final double largestAmount = records.isNotEmpty ? records.first.amount : 0.0;
  final bool hasTail = records.length > 6;
  final double? tailTotal =
      hasTail ? records.skip(6).fold<double>(0.0, (s, r) => s + r.amount) : null;

  return {
    'total': bitsHex(totalAmount),
    'previousTotal': maybeBits(previousMonthTotal),
    'largest': bitsHex(largestAmount),
    'tailTotal': maybeBits(tailTotal),
    'records': [
      for (final r in records)
        {
          'name': r.category,
          'amount': bitsHex(r.amount),
          'percentage': bitsHex(r.percentage),
          'percentageText': r.percentage.toStringAsFixed(0),
          'count': r.count,
          'budgetLimit': maybeBits(r.budgetLimit),
          'colorIndex': r.colorIndex,
          'fromHash': r.fromHash,
          'hashCode': r.category.hashCode,
        }
    ],
  };
}

// ---------------------------------------------------------------------------

Map<String, Object?> tx(String id, String type, double amount, String category,
        String date) =>
    {
      'id': id,
      'type': type,
      'description': id,
      'amount': amount,
      'category': category,
      'date': date,
      'createdAt': '2026-09-01T08:00:00.000',
      'updatedAt': '2026-09-01T08:00:00.000',
    };

Map<String, Object?> cat(String name, int order, {bool archived = false}) => {
      'id': 'expense-c$order',
      'type': 'expense',
      'name': name,
      'iconIdentifier': 'book',
      'colorToken': 'accent',
      'sortOrder': order,
      'isArchived': archived,
      'isBuiltIn': false,
    };

const salary = {
  'id': 'income-salary',
  'type': 'income',
  'name': 'Salary',
  'iconIdentifier': 'money',
  'colorToken': 'green',
  'sortOrder': 0,
  'isArchived': false,
  'isBuiltIn': true,
};

/// Sixteen active expense categories (so chart indices wrap past 14), two
/// archived ones.
List<Map<String, Object?>> baseCategories() => [
      for (final (i, name) in [
        'General', 'Eating Out', 'Groceries', 'Housing', 'Transportation',
        'Travel', 'Clothing', 'Gift', 'Health', 'Entertainment', 'Pets',
        'Family', 'Loan Payment', 'Books', 'Café', 'Garden',
      ].indexed)
        cat(name, i),
      cat('Old Hobby', 16, archived: true),
      cat('Retired', 17, archived: true),
      salary,
    ];

String d(int y, int m, [int day = 10]) =>
    DateTime(y, m, day, 12).toIso8601String();

/// Expenses in `month`, one row per (category, amount), in list order.
List<Map<String, Object?>> spend(String prefix, int y, int m,
        List<(String, double)> rows) =>
    [
      for (final (i, (c, a)) in rows.indexed)
        tx('$prefix$i', 'expense', a, c, d(y, m, 1 + i % 27)),
    ];

Map<String, Object?> income(String id, int y, int m, double a) =>
    tx(id, 'income', a, 'Salary', d(y, m, 1));

final List<String> fortyNames = [
  for (var i = 0; i < 40; i++)
    switch (i) {
      3 => 'Old Hobby',
      9 => 'Retired',
      12 => 'groceries',
      17 => 'Café',
      _ => 'Cat ${String.fromCharCode(65 + i % 26)}$i',
    }
];

/// Each dataset: sections, the months to read (<= 5, newest first is the
/// page default), and the themes to pump.
final datasets = <String, Map<String, Object?>>{
  'typical': {
    'transactions': [
      ...spend('s', 2026, 9, [
        ('Groceries', 150.25), ('Eating Out', 84.99), ('Groceries', 249.75),
        ('Housing', 1000.01), ('Health', 85.0), ('Eating Out', 30.0),
        ('Pets', 50.0),
      ]),
      income('i9', 2026, 9, 3200),
      ...spend('a', 2026, 8, [('Groceries', 0.1), ('Travel', 199.99)]),
      income('i8', 2026, 8, 3000),
    ],
    'limits': {
      'Groceries': 400.0,
      'Eating Out': 100.0,
      'Housing': 1000.0,
      'Health': 85.0,
      'Pets': 49.99,
      'Travel': 150.5,
    },
    'months': [DateTime(2026, 9), DateTime(2026, 8)],
    'themes': ['light', 'dark'],
  },
  'ties': {
    'transactions': [
      ...spend('t', 2026, 9, [
        ('Travel', 20.0), ('Books', 50.0), ('Garden', 20.0), ('General', 50.0),
        ('Pets', 20.0), ('Health', 10.0), ('Gift', 50.0), ('Family', 20.0),
        ('Clothing', 10.0), ('Old Hobby', 20.0),
      ]),
      ...spend('u', 2026, 8, [('Books', 100.0)]),
    ],
    'limits': {'Books': 50.0, 'Travel': 19.99},
    'months': [DateTime(2026, 9)],
    'themes': ['light', 'dark'],
  },
  'exactly_six': {
    'transactions': spend('e', 2026, 9, [
      ('General', 60.0), ('Eating Out', 50.0), ('Groceries', 40.0),
      ('Housing', 30.0), ('Transportation', 20.0), ('Travel', 10.0),
    ]),
    'months': [DateTime(2026, 9)],
  },
  'seven': {
    'transactions': spend('v', 2026, 9, [
      ('General', 70.0), ('Eating Out', 60.0), ('Groceries', 50.0),
      ('Housing', 40.0), ('Transportation', 30.0), ('Travel', 20.0),
      ('Retired', 10.0),
    ]),
    'months': [DateTime(2026, 9)],
  },
  'forty': {
    'transactions': [
      ...spend('f', 2026, 9, [
        for (var i = 0; i < 40; i++) (fortyNames[i], 1000.0 - i * 7.25),
      ]),
      ...spend('p', 2026, 8, [('Books', 12345.67)]),
    ],
    'months': [DateTime(2026, 9)],
    'themes': ['light', 'dark'],
  },
  'forty_ties': {
    // Above 33 records Dart sorts with a quicksort: tie order is not the
    // first-appearance order Swift keeps (PARITY_GAPS). Amounts only.
    'transactions': spend('q', 2026, 9, [
      for (var i = 0; i < 40; i++) (fortyNames[i], (i % 4) * 10.0 + 5),
    ]),
    'months': [DateTime(2026, 9)],
    'unstableTies': true,
  },
  'amounts': {
    'transactions': [
      ...spend('m', 2026, 9, [
        ('General', 945.0), ('Eating Out', 25.0), ('Groceries', 15.0),
        ('Housing', 10.0), ('Transportation', 5.0), ('Travel', 0.0),
        ('Clothing', 0.001), ('Gift', -5.0), ('Health', 0.1),
        ('Health', 0.2), ('Pets', 4.999),
      ]),
      ...spend('n', 2026, 8, [('General', 0.1), ('General', 0.2)]),
      ...spend('o', 2026, 7, [('General', 3.0), ('Eating Out', -3.0)]),
      ...spend('r', 2026, 6, [('General', 2.0), ('Eating Out', -1.0)]),
    ],
    'limits': {'Travel': 1.0, 'Gift': 1.0, 'General': 945.0},
    'months': [DateTime(2026, 9), DateTime(2026, 8), DateTime(2026, 7), DateTime(2026, 6)],
  },
  'income_only': {
    'transactions': [
      income('i1', 2026, 9, 3000),
      ...spend('x', 2026, 8, [('General', 12.0)]),
      income('i2', 2026, 7, 100),
    ],
    'months': [DateTime(2026, 9), DateTime(2026, 8)],
  },
  'previous_missing': {
    'transactions': [
      ...spend('a', 2026, 9, [('General', 10.0)]),
      ...spend('b', 2026, 7, [('General', 20.0)]),
      ...spend('c', 2026, 1, [('Housing', 30.0)]),
      ...spend('e', 2025, 12, [('Housing', 60.0)]),
      // A future month with data is the page default.
      ...spend('f', 2027, 2, [('Garden', 7.5)]),
    ],
    'months': [DateTime(2027, 2), DateTime(2026, 9), DateTime(2026, 7), DateTime(2026, 1), DateTime(2025, 12)],
  },
  'previous_zero': {
    'transactions': [
      ...spend('a', 2026, 9, [('General', 10.0)]),
      income('i', 2026, 8, 50),
      ...spend('z', 2026, 5, [('General', 0.0)]),
      ...spend('y', 2026, 6, [('General', 4.0)]),
    ],
    'months': [DateTime(2026, 9), DateTime(2026, 6), DateTime(2026, 5)],
  },
  'delta_down_half': {
    'transactions': [
      ...spend('a', 2025, 2, [('General', 199.0)]),
      ...spend('b', 2025, 1, [('General', 200.0)]),
      ...spend('c', 2024, 12, [('General', 200.0)]),
      ...spend('e', 2024, 11, [('General', 100.0), ('Housing', 0.99)]),
      ...spend('f', 2024, 10, [('General', 100.0)]),
    ],
    'months': [DateTime(2025, 2), DateTime(2025, 1), DateTime(2024, 11)],
  },
  'delta_up_half': {
    'transactions': [
      ...spend('a', 2025, 6, [('General', 201.0)]),
      ...spend('b', 2025, 5, [('General', 200.0)]),
      ...spend('c', 2025, 4, [('General', 200.99)]),
      ...spend('e', 2025, 3, [('General', 0.1), ('General', 0.2)]),
      ...spend('f', 2025, 2, [('General', 0.3)]),
    ],
    'months': [DateTime(2025, 6), DateTime(2025, 5), DateTime(2025, 4), DateTime(2025, 3)],
  },
  'delta_large': {
    'transactions': [
      ...spend('a', 2025, 6, [('General', 1234.56)]),
      ...spend('b', 2025, 5, [('General', 43.21)]),
      ...spend('c', 2025, 4, [('General', 0.01)]),
      ...spend('e', 2025, 3, [('General', 1e9)]),
    ],
    'months': [DateTime(2025, 6), DateTime(2025, 5), DateTime(2025, 4)],
  },
  'unicode': {
    'transactions': spend('u', 2026, 9, [
      ('Café', 30.0), ('Café', 20.0), ('\u{1F355} Pizza', 12.5),
      ('straße', 8.0), ('ᾀ alpha', 4.0), ('Café', 1.0),
      ('ǆungla', 2.0), ('Café', 0.5),
    ]),
    'limits': {'Café': 20.0, 'Café': 10.0},
    'months': [DateTime(2026, 9)],
  },
};

Future<void> loadDataset(WidgetTester tester, Map<String, Object?> spec,
    Map<String, Object?> sections, AppHarness app) async {
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    await AtomicFinancialStore.instance.updateSections(sections);
    await app.initialize(generate: false);
  });
}

List<String?> textsUnder(WidgetTester tester, Finder parent) => tester
    .widgetList<Text>(find.descendant(of: parent, matching: find.byType(Text)))
    .map((t) => t.data)
    .toList();

/// The list card's rows as rendered, in order.
Map<String, Object?> readList(WidgetTester tester) {
  final card = find.byType(GlowListCard);
  final texts = textsUnder(tester, card);
  final tiles = tester
      .widgetList<IconTile>(
          find.descendant(of: card, matching: find.byType(IconTile)))
      .toList();
  final bars = tester
      .widgetList<GlowProgressBar>(
          find.descendant(of: card, matching: find.byType(GlowProgressBar)))
      .toList();
  final containers = tester
      .widgetList<AnimatedContainer>(
          find.descendant(of: card, matching: find.byType(AnimatedContainer)))
      .toList();
  final rows = <Map<String, Object?>>[];
  Map<String, Object?>? tail;
  var showLess = false;
  var t = 0, i = 0;
  while (t < texts.length) {
    if (texts[t] == 'Show less') {
      showLess = true;
      t += 1;
      continue;
    }
    final entry = {
      'title': texts[t],
      'subtitle': texts[t + 1],
      'amount': texts[t + 2],
      'iconColor': argb(tiles[i].color),
      'bar': bitsHex(bars[i].value),
      'barColor': argb(bars[i].color),
    };
    if (tiles[i].background != null) {
      tail = entry;
    } else {
      final box = containers[rows.length].decoration as BoxDecoration;
      rows.add({...entry, 'tinted': box.color != Colors.transparent});
    }
    t += 3;
    i += 1;
  }
  return {'rows': rows, 'tail': tail, 'showLess': showLess};
}

Future<Map<String, Object?>> readMonth(
    WidgetTester tester, TransactionModel model, DateTime expectedMonth) async {
  final out = <String, Object?>{
    'pill': (tester.widget<MonthPill>(find.byType(MonthPill))).label,
  };
  if (find.text('No Expenses').evaluate().isNotEmpty) {
    out['empty'] = true;
    out['mirror'] = mirrorBreakdown(model, expectedMonth);
    return out;
  }
  final donutFinder = find.byType(CategoryDonutChart);
  final donut = tester.widget<CategoryDonutChart>(donutFinder);
  expect(donut.month, expectedMonth);
  out['donut'] = {
    'month': donut.month.toIso8601String(),
    'total': bitsHex(donut.totalAmount),
    'previousTotal': maybeBits(donut.previousMonthTotal),
    'previousLabel': donut.previousMonthLabel,
    'slices': [
      for (final s in donut.slices)
        {'label': s.label, 'value': bitsHex(s.value), 'color': argb(s.color)}
    ],
  };
  out['centre'] = textsUnder(tester, donutFinder);
  out['collapsed'] = readList(tester);

  // Select each slice by tapping the middle of its ring range, read the
  // centre and the row tints, then tap it again to clear the selection.
  final origin = tester.getTopLeft(donutFinder);
  final total = donut.slices.fold(0.0, (s, x) => s + x.value);
  final selections = <Map<String, Object?>>[];
  var cursor = 0.0;
  for (var index = 0; index < donut.slices.length; index++) {
    final share = total > 0 ? donut.slices[index].value / total : 0.0;
    if (share > 0) {
      final f = cursor + share / 2;
      final local = Offset(120 + 105 * math.sin(2 * math.pi * f),
          120 - 105 * math.cos(2 * math.pi * f));
      final point = origin + local;
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      final list = readList(tester);
      selections.add({
        'index': index,
        'x': bitsHex(local.dx),
        'y': bitsHex(local.dy),
        'centre': textsUnder(tester, donutFinder),
        'tinted': [
          for (final (i, row) in (list['rows'] as List).indexed)
            if ((row as Map)['tinted'] == true) i
        ],
      });
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(textsUnder(tester, donutFinder), out['centre']);
    }
    cursor += share;
  }
  out['selections'] = selections;

  final tailTitle = (out['collapsed'] as Map)['tail'];
  if (tailTitle != null) {
    await tester.tap(find.text((tailTitle as Map)['title'] as String));
    await tester.pumpAndSettle();
    out['expanded'] = readList(tester);
    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
  }
  out['mirror'] = mirrorBreakdown(model, expectedMonth);
  return out;
}

/// The mirror agrees with what the page rendered.
void checkMirror(Map<String, Object?> month) {
  final mirror = month['mirror'] as Map<String, Object?>;
  if (month['empty'] == true) {
    expect(mirror['total'], bitsHex(0.0));
    return;
  }
  final donut = month['donut'] as Map<String, Object?>;
  expect(mirror['total'], donut['total']);
  expect(mirror['previousTotal'], donut['previousTotal']);
  final records = (mirror['records'] as List).cast<Map<String, Object?>>();
  final slices = (donut['slices'] as List).cast<Map<String, Object?>>();
  for (var i = 0; i < slices.length && i < 6; i++) {
    expect(slices[i]['label'], records[i]['name']);
    expect(slices[i]['value'], records[i]['amount']);
  }
  if (records.length > 6) expect(slices[6]['value'], mirror['tailTotal']);
  final rows = ((month['expanded'] ?? month['collapsed']) as Map)['rows']
      as List;
  expect(rows.length, records.length);
  for (final (i, row) in rows.indexed) {
    final r = row as Map;
    expect(r['title'], records[i]['name']);
    expect((r['subtitle'] as String).contains(' · ${records[i]['percentageText']}%'),
        isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = fixtureDir('spend').path;
  final breakdowns = <String, Object?>{};

  setUp(() async {
    pinClock(DateTime(2026, 9, 28, 9, 15));
    seedUuids(11);
  });

  for (final entry in datasets.entries) {
    final spec = entry.value;
    for (final theme in (spec['themes'] as List<String>? ?? ['light'])) {
      testWidgets('page: ${entry.key} ($theme)', (tester) async {
        tester.view.physicalSize = const Size(1000, 8000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        // The test font is wider than Gabarito, so some rows overflow, and
        // the month sheet trips ListTile's debug-only ink check. Neither
        // touches a value read here; anything else still fails the test.
        final previousOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          final text = details.exceptionAsString();
          if (text.contains('overflowed') ||
              text.contains('ListTile background color') ||
              text.contains("deactivated widget's ancestor")) {
            return;
          }
          previousOnError?.call(details);
        };
        try {
        final sections = <String, Object?>{
          'categories': baseCategories(),
          'transactions': spec['transactions'],
          if (spec['limits'] != null) 'categoryBudgetLimits': spec['limits'],
        };
        final app = AppHarness();
        await loadDataset(tester, spec, sections, app);
        final model = app.transactionModel;

        await tester.pumpWidget(
          ChangeNotifierProvider<TransactionModel>.value(
            value: model,
            child: MaterialApp(
              theme: theme == 'dark' ? ThemeData.dark() : ThemeData.light(),
              home: const CategoryPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final available = model.getAvailableMonths();
        final months = (spec['months'] as List).cast<DateTime>();
        expect(available.first, months.first,
            reason: 'the first listed month is the page default');
        final out = <Map<String, Object?>>[];
        for (final (i, month) in months.indexed) {
          if (i > 0) {
            await tester.tap(find.byType(MonthPill));
            await tester.pumpAndSettle();
            await tester.tap(find.text(DateFormat.yMMMM().format(month)));
            await tester.pumpAndSettle();
          }
          final result = await readMonth(tester, model, month);
          result['month'] = month.toIso8601String();
          checkMirror(result);
          out.add(result);
        }

        breakdowns['${entry.key}/$theme'] = {
          'dataset': entry.key,
          'theme': theme,
          'unstableTies': spec['unstableTies'] == true,
          'sections': jsonEncode(sections),
          'expenseCategories': expenseCategories.keys.toList(),
          'availableMonths': [for (final m in available) m.toIso8601String()],
          'months': out,
        };
        } finally {
          FlutterError.onError = previousOnError;
        }
      });
    }
  }

  test('write breakdowns.json', () {
    writeJson('$dir/breakdowns.json', {
      'tz': parityTz,
      'cases': [
        for (final key in breakdowns.keys.toList()..sort()) breakdowns[key]
      ],
    });
  });

  testWidgets('donut hit tests and arcs', (tester) async {
    final distributions = <String, List<double>>{
      'single': [1.0],
      'three': [3.0, 2.0, 1.0],
      'tiny': [50.0, 0.1, 0.2, 49.7],
      'seven': [100.0, 80.0, 60.0, 40.0, 20.0, 10.0, 25.0],
      'zero_slice': [5.0, 0.0, 5.0],
      'negative': [10.0, -2.0, 7.0],
      'noise': [0.1, 0.2, 0.3],
      'all_zero': [0.0, 0.0],
      'empty': [],
    };
    const radii = [
      0.0, 30.0, 60.0, 82.0, 84.0, 86.0, 89.99999999, 90.0, 90.00000001,
      95.0, 105.0, 115.0, 119.99999999, 120.0, 120.00000001, 125.0, 140.0,
      160.0, 169.0,
    ];
    final out = <Map<String, Object?>>[];
    for (final entry in distributions.entries) {
      final values = entry.value;
      final slices = [
        for (final (i, v) in values.indexed)
          CategorySlice(label: 'S$i', value: v, color: Color(0xFF000001 + i)),
      ];
      final selected = values.length > 1 ? 1 : 0;

      // Hit points: a grid of angles and radii, the exact slice boundaries
      // and their neighbours, corners, and points just outside the square.
      final fractions = <double>[for (var k = 0; k < 64; k++) k / 64];
      final total = values.fold(0.0, (s, v) => s + v);
      var cursor = 0.0;
      for (final v in values) {
        if (total > 0) cursor += v / total;
        fractions.addAll([cursor, cursor - 1e-9, cursor + 1e-9]);
      }
      final points = <Offset>[
        for (final f in fractions)
          for (final r in radii)
            Offset(120 + r * math.sin(2 * math.pi * f),
                120 - r * math.cos(2 * math.pi * f)),
        const Offset(0, 0),
        const Offset(239.999, 239.999),
        const Offset(239.999, 120),
        const Offset(240, 120),
        const Offset(250, 120),
        const Offset(120, 240),
        const Offset(120, 239.99999),
      ].where((p) => p.dx >= 0 && p.dy >= 0 && p.dx < 300 && p.dy < 300).toList();

      Future<List<Object?>> tapAll(int selectedIndex) async {
        int? result;
        var called = false;
        Offset? local;
        await tester.pumpWidget(MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Listener(
              onPointerUp: (e) => local = e.localPosition,
              child: CategoryDonutChart(
                slices: slices,
                totalAmount: total,
                selectedIndex: selectedIndex,
                month: DateTime(2026, 9),
                onSliceSelected: (i) {
                  called = true;
                  result = i;
                },
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final results = <Object?>[];
        for (final p in points) {
          called = false;
          result = null;
          local = null;
          await tester.tapAt(p);
          await tester.pump();
          if (local != null) expect(local, p);
          // null = no callback; -1 = deselect; i = select.
          results.add(called ? result : null);
        }
        return results;
      }

      final unselected = await tapAll(-1);
      final whenSelected = await tapAll(selected);

      // Arcs through the sweep-in, then settled, unselected and selected.
      Future<List<Map<String, Object?>>> frames(int selectedIndex) async {
        await tester.pumpWidget(Container());
        await tester.pumpWidget(MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CategoryDonutChart(
              slices: slices,
              totalAmount: total,
              selectedIndex: selectedIndex,
              month: DateTime(2026, 9),
              onSliceSelected: (_) {},
            ),
          ),
        ));
        final recorded = <Map<String, Object?>>[];
        for (final step in [0, 0, 50, 100, 125, 100, 150, 200, 600]) {
          await tester.pump(Duration(milliseconds: step));
          final paint = tester.widget<CustomPaint>(find.descendant(
              of: find.byType(CategoryDonutChart),
              matching: find.byType(CustomPaint)));
          final painter = paint.painter!;
          final canvas = TestRecordingCanvas();
          painter.paint(canvas, const Size(240, 240));
          recorded.add({
            'sweep': bitsHex((painter as dynamic).sweep as double),
            'arcs': [
              for (final call in canvas.invocations)
                if (call.invocation.memberName == #drawArc)
                  () {
                    final args = call.invocation.positionalArguments;
                    final rect = args[0] as Rect;
                    final p = args[4] as Paint;
                    return {
                      'index': p.color.toARGB32() - 0xFF000001,
                      'centerX': bitsHex(rect.center.dx),
                      'centerY': bitsHex(rect.center.dy),
                      'radius': bitsHex(rect.width / 2),
                      'start': bitsHex(args[1] as double),
                      'sweep': bitsHex(args[2] as double),
                      'useCenter': args[3],
                      'strokeWidth': bitsHex(p.strokeWidth),
                      'cap': p.strokeCap.name,
                      'style': p.style.name,
                    };
                  }()
            ],
          });
        }
        return recorded;
      }

      out.add({
        'name': entry.key,
        'values': [for (final v in values) bitsHex(v)],
        'selected': selected,
        'points': [
          for (final (i, p) in points.indexed)
            {
              'x': bitsHex(p.dx),
              'y': bitsHex(p.dy),
              'unselected': unselected[i],
              'selected': whenSelected[i],
            }
        ],
        'frames': await frames(-1),
        'selectedFrames': await frames(selected),
      });
    }
    writeJson('$dir/donut.json', {'tz': parityTz, 'distributions': out});
  });

  test('String.hashCode and toUpperCase', () {
    final corpus = <String>[
      '', 'a', 'General', 'Groceries', 'groceries', 'Old Hobby', 'Retired',
      'Café', 'Café', '\u{1F355} Pizza', 'straße', 'ᾀ alpha',
      'ǆungla', 'Other', 'x' * 300, '\u{10000}', '￿\u0000',
      for (final n in fortyNames) n,
    ];
    final upper = <List<Object>>[];
    for (var cp = 0; cp <= 0x10FFFF; cp++) {
      if (cp >= 0xD800 && cp <= 0xDFFF) continue;
      final s = String.fromCharCode(cp);
      final u = s.toUpperCase();
      if (u != s) upper.add([cp, u.codeUnits]);
    }
    writeJson('$dir/strings.json', {
      'tz': parityTz,
      'hashCodes': [
        for (final s in corpus) {'units': s.codeUnits, 'hashCode': s.hashCode}
      ],
      'upper': upper,
    });
  });
}
