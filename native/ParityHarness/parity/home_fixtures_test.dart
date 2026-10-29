// Emits native/Fixtures/home/ : expected outputs of the real Dart code behind
// the Home tab (budget limits and rows, month-over-month deltas) and the
// transaction form's auto-categorisation, for fixed inputs. Runs under
// America/New_York (the zone of the Swift test calendar).
//
// Budget mutations, the category list, rule matching, suggestions and
// double.tryParse call the app's own code. Three formulas are private to
// widget State classes in spending_page.dart and are copied verbatim below,
// each citing its source lines; they call the real model getters.

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/categorization_rule.dart';
import 'package:budget_app/common.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

Object? numberJson(double? d) =>
    d == null ? null : {'bits': bitsHex(d), 'isNaN': d.isNaN};

// --- Copied verbatim from spending_page.dart (private State members) -------

/// spending_page.dart:107-136 `_buildBudgetProgressItems`, with the model
/// getters it wraps (`_getCategoryBudgetLimit` :75-80,
/// `_getCategorySpendingForMonth` :82-88) inlined.
List<({String category, double spent, double limit})> buildBudgetProgressItems(
  TransactionModel model,
  DateTime month,
) {
  final items = <({String category, double spent, double limit})>[];
  for (final entry in expenseCategories.entries) {
    final limit = model.getCategoryBudgetLimit(entry.key);
    if (limit == null || limit <= 0) continue;

    items.add((
      category: entry.key,
      spent: model.getCategorySpendingForMonth(entry.key, month),
      limit: limit,
    ));
  }

  items.sort((a, b) {
    final spentCompare = b.spent.compareTo(a.spent);
    if (spentCompare != 0) {
      return spentCompare;
    }

    return a.category.compareTo(b.category);
  });

  return items;
}

/// spending_page.dart:138-150 `_budgetedCategories` / `_unbudgetedCategories`.
List<String> budgetedCategories(TransactionModel model) => [
      for (final category in expenseCategories.keys)
        if ((model.getCategoryBudgetLimit(category) ?? 0) > 0) category,
    ];
List<String> unbudgetedCategories(TransactionModel model) => [
      for (final category in expenseCategories.keys)
        if ((model.getCategoryBudgetLimit(category) ?? 0) <= 0) category,
    ];

/// spending_page.dart:1948-1968 `_CategoryBudgetProgress` getters and
/// :1672-1683 `_statusColor` (colour names instead of colours).
String budgetStatus(double spent, double limit) {
  final remaining = limit - spent;
  final isOverBudget = remaining < 0;
  final progress = spent / limit;
  if (isOverBudget) return 'over';
  if (progress >= 0.85) return 'warning';
  return 'ok';
}

/// spending_page.dart:339-345 `_percentDelta`.
double? percentDelta(double current, double previous) {
  if (previous == 0) {
    if (current == 0) return null;
    return 100;
  }
  return (current - previous) / previous * 100;
}

/// spending_page.dart:1487-1493 (`_FlowChip.build`).
String deltaLabelFor(double? delta, String previousMonthLabel) {
  final String deltaLabel;
  if (delta == null) {
    deltaLabel = 'No $previousMonthLabel data';
  } else {
    final sign = delta >= 0 ? '+' : '';
    deltaLabel = '$sign${delta.toStringAsFixed(1)}% vs $previousMonthLabel';
  }
  return deltaLabel;
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

/// Empties `home/` except `home/tz/`, which home_page_fixtures_test.dart
/// writes (`fixtureDir` would delete it).
String homeDir() {
  final dir = Directory('$fixturesRoot/home');
  dir.createSync(recursive: true);
  for (final entry in dir.listSync()) {
    if (entry.uri.pathSegments.where((segment) => segment.isNotEmpty).last == 'tz') {
      continue;
    }
    entry.deleteSync(recursive: true);
  }
  return dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = homeDir();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    pinClock(DateTime(2026, 9, 28, 9, 15));
    seedUuids(7);
  });

  test('budget limit mutations', () async {
    // Each case: the stored `categoryBudgetLimits` JSON (null = absent) and
    // a sequence of model calls. NaN/Infinity are not sent: Dart accepts
    // them into memory and then fails every save (Swift rejects them).
    final cases = <Map<String, Object?>>[
      {
        'label': 'double lexemes',
        'initial':
            '{"Groceries":400.0,"Eating Out":150.5,"Pet Food":60.0}',
        'ops': [
          ['set', 'Travel', 200.0],
          ['set', 'Eating Out', 175.25],
          ['set', '  Groceries  ', 410.0],
          ['set', '', 5.0],
          ['set', '   ', 5.0],
          ['set', 'Pet Food', 0.0],
          ['remove', 'Missing'],
          ['remove', ' Travel'],
          ['set', 'Travel', -3.0],
          ['set', 'Pet Food', 60.0],
          ['set', 'Groceries', 410.0],
          ['set', '﻿Health ', 1e-7],
          ['set', 'Café', 0.1 + 0.2],
          ['set', 'Café', 12.0],
          ['remove', 'Café'],
          ['set', 'Big', 123456789012345680000.0],
          ['set', 'Travel', -0.0],
          ['remove', 'Travel'],
        ],
      },
      {
        'label': 'absent section',
        'initial': null,
        'ops': [
          ['remove', 'General'],
          ['set', 'General', 100.0],
          ['set', 'Health', 49.99],
          ['remove', 'General'],
          ['remove', 'Health'],
        ],
      },
      {
        'label': 'int lexemes and dropped values',
        'initial': '{"Groceries":250,"Zero":0,"Negative":-5.0,"Travel":100}',
        'ops': [
          ['set', 'Health', 50.0],
          ['set', 'Zero', 20.0],
          ['remove', 'Negative'],
          ['set', 'Negative', 0.0],
          ['set', 'Travel', 100.0],
          ['remove', 'Groceries'],
          ['set', 'Groceries', 250.0],
        ],
      },
      {
        'label': 'repeated keys',
        'initial': '{"A":1.0,"B":2.0,"A":3.0}',
        'ops': [
          ['set', 'C', 1.0],
          ['set', 'A', 4.0],
          ['remove', 'B'],
        ],
      },
    ];

    final out = <Map<String, Object?>>[];
    for (final c in cases) {
      SharedPreferences.setMockInitialValues({});
      await AtomicFinancialStore.instance.resetForTesting();
      final store = AtomicFinancialStore.instance;
      final initial = c['initial'] as String?;
      if (initial != null) {
        await store.updateSection(
            FinancialSections.categoryBudgetLimits, jsonDecode(initial));
      }
      final model = TransactionModel();
      await model.getTransactions();

      Map<String, Object?> state() => {
            'memory': [
              for (final e in model.categoryBudgetLimits.entries)
                [e.key, bitsHex(e.value)]
            ],
          };

      final loaded = state();
      final steps = <Map<String, Object?>>[];
      for (final op in (c['ops'] as List).cast<List>()) {
        final before = (await store.read()).revision;
        if (op[0] == 'set') {
          await model.setCategoryBudgetLimit(
              op[1] as String, (op[2] as num).toDouble());
        } else {
          await model.removeCategoryBudgetLimit(op[1] as String);
        }
        final snapshot = await store.read();
        final section = snapshot.sections[FinancialSections.categoryBudgetLimits];
        steps.add({
          'op': op[0],
          'category': op[1],
          if (op[0] == 'set') 'limit': bitsHex((op[2] as num).toDouble()),
          'wrote': snapshot.revision != before,
          'section': section == null ? null : jsonEncode(section),
          ...state(),
          'hasUnsavedChanges': model.hasUnsavedChanges,
        });
      }
      out.add({
        'label': c['label'],
        'initial': initial,
        'loaded': loaded,
        'steps': steps,
      });
    }
    writeJson('$dir/budget_mutations.json', {'tz': parityTz, 'cases': out});
  });

  test('budget rows and category lists', () async {
    final sections = <String, Object?>{
      'categories': [
        {'id': 'expense-general', 'type': 'expense', 'name': 'General', 'iconIdentifier': 'square_grid_2x2', 'colorToken': 'accent', 'sortOrder': 0, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-housing', 'type': 'expense', 'name': 'Housing', 'iconIdentifier': 'house', 'colorToken': 'blue', 'sortOrder': 5, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-groceries', 'type': 'expense', 'name': 'Groceries', 'iconIdentifier': 'cart', 'colorToken': 'green', 'sortOrder': 2, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-eating-out', 'type': 'expense', 'name': 'Eating Out', 'iconIdentifier': 'asterisk_circle', 'colorToken': 'orange', 'sortOrder': 1, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-travel', 'type': 'expense', 'name': 'Travel', 'iconIdentifier': 'airplane', 'colorToken': 'cyan', 'sortOrder': 3, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-health', 'type': 'expense', 'name': 'Health', 'iconIdentifier': 'heart', 'colorToken': 'red', 'sortOrder': 4, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-pets', 'type': 'expense', 'name': 'Pets', 'iconIdentifier': 'paw', 'colorToken': 'green', 'sortOrder': 6, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-clothing', 'type': 'expense', 'name': 'Clothing', 'iconIdentifier': 'bag', 'colorToken': 'pink', 'sortOrder': 7, 'isArchived': false, 'isBuiltIn': true},
        {'id': 'expense-old-hobby', 'type': 'expense', 'name': 'Old Hobby', 'iconIdentifier': 'film', 'colorToken': 'orange', 'sortOrder': 8, 'isArchived': true, 'isBuiltIn': false},
        {'id': 'expense-zeta', 'type': 'expense', 'name': 'Zeta', 'iconIdentifier': 'book', 'colorToken': 'accent', 'sortOrder': 9, 'isArchived': false, 'isBuiltIn': false},
        {'id': 'expense-alpha', 'type': 'expense', 'name': 'alpha', 'iconIdentifier': 'book', 'colorToken': 'accent', 'sortOrder': 10, 'isArchived': false, 'isBuiltIn': false},
        {'id': 'income-salary', 'type': 'income', 'name': 'Salary', 'iconIdentifier': 'money', 'colorToken': 'green', 'sortOrder': 0, 'isArchived': false, 'isBuiltIn': true},
      ],
      'categoryBudgetLimits': {
        'Groceries': 400.0,
        'Eating Out': 100.0,
        'Housing': 1000.0,
        'Travel': 200.0,
        'Old Hobby': 50.0,
        'groceries': 30.0,
        'Budget Only': 75.0,
        'Health': 100.0,
        'Pets': 100.0,
        'Zero': 0,
        'Clothing': 20.0,
        'Zeta': 10.0,
        'alpha': 10.0,
      },
      'transactions': [
        tx('g1', 'expense', 150.25, 'Groceries', '2026-09-03T12:00:00.000'),
        tx('g2', 'expense', 249.75, 'Groceries', '2026-09-04T12:00:00.000'),
        tx('g3', 'expense', 30.0, 'groceries', '2026-09-05T12:00:00.000'),
        tx('e1', 'expense', 84.99, 'Eating Out', '2026-09-06T12:00:00.000'),
        tx('h1', 'expense', 1000.01, 'Housing', '2026-09-01T00:00:00.000'),
        tx('he', 'expense', 85.0, 'Health', '2026-09-10T12:00:00.000'),
        tx('p1', 'expense', 50.0, 'Pets', '2026-09-11T12:00:00.000'),
        tx('c1', 'expense', 50.0, 'Clothing', '2026-09-12T12:00:00.000'),
        tx('o1', 'expense', 10.0, 'Old Hobby', '2026-09-13T12:00:00.000'),
        tx('z1', 'expense', 5.0, 'Zeta', '2026-09-14T12:00:00.000'),
        tx('a1', 'expense', 5.0, 'alpha', '2026-09-14T12:00:00.000'),
        tx('s1', 'income', 3200.0, 'Salary', '2026-09-01T09:00:00.000'),
        tx('g4', 'expense', 0.1, 'Groceries', '2026-08-31T23:59:59.999'),
        tx('g5', 'expense', 0.2, 'Groceries', '2026-08-01T00:00:00.000'),
        tx('t1', 'expense', 199.99, 'Travel', '2026-08-15T12:00:00.000'),
        tx('e2', 'expense', 85.0, 'Eating Out', '2026-08-15T12:00:00.000'),
        tx('s2', 'income', 3000.0, 'Salary', '2026-08-01T09:00:00.000'),
      ],
    };

    await AtomicFinancialStore.instance.updateSections(sections);
    final app = AppHarness();
    await app.initialize(generate: false);
    final model = app.transactionModel;

    final months = <Map<String, Object?>>[];
    for (final month in [
      DateTime(2026, 7),
      DateTime(2026, 8),
      DateTime(2026, 9),
      DateTime(2026, 10),
    ]) {
      months.add({
        'month': month.toIso8601String(),
        'rows': [
          for (final row in buildBudgetProgressItems(model, month))
            {
              'category': row.category,
              'spent': bitsHex(row.spent),
              'limit': bitsHex(row.limit),
              'remaining': bitsHex(row.limit - row.spent),
              'progress': bitsHex(row.spent / row.limit),
              'isOver': row.limit - row.spent < 0,
              'status': budgetStatus(row.spent, row.limit),
            }
        ],
      });
    }

    writeJson('$dir/budget_rows.json', {
      'tz': parityTz,
      'sections': jsonEncode(sections),
      'expenseCategories': expenseCategories.keys.toList(),
      'limits': [
        for (final e in model.categoryBudgetLimits.entries)
          [e.key, bitsHex(e.value)]
      ],
      'budgeted': budgetedCategories(model),
      'unbudgeted': unbudgetedCategories(model),
      'months': months,
    });
  });

  test('month-over-month deltas', () {
    final pairs = <(double, double)>[
      (0, 0),
      (-0.0, 0),
      (0, -0.0),
      (5, 0),
      (-5, 0),
      (0, 5),
      (100, 50),
      (50, 100),
      (100, -50),
      (-50, -50),
      (50, 50),
      (-100, 50),
      (1, 3),
      (8, 7),
      (3200, 3000),
      (43.21, 1234.56),
      (1e-300, 1e300),
      (1e300, 1e-300),
      (100.04, 100),
      (99.96, 100),
      (99.95, 100),
      (100.05, 100),
      (0.1 + 0.2, 0.3),
    ];
    for (var cents = 0; cents <= 100; cents += 5) {
      pairs.add((100 + cents / 100, 100));
      pairs.add((200 + cents / 100 * 2, 200));
      pairs.add((1000 - cents / 1000, 1000));
    }
    final deltas = [
      for (final (current, previous) in pairs)
        () {
          final delta = percentDelta(current, previous);
          return {
            'current': bitsHex(current),
            'previous': bitsHex(previous),
            'delta': numberJson(delta),
            'label': deltaLabelFor(delta, 'August'),
          };
        }()
    ];

    // spending_page.dart:474-482: previous month and its MMMM label.
    final previous = <Map<String, Object?>>[];
    for (final month in [
      for (var m = 1; m <= 12; m++) DateTime(2026, m),
      DateTime(2027, 1),
      DateTime(2026, 3, 31, 23, 30),
      DateTime(2000, 1, 15),
    ]) {
      final selected = DateTime(month.year, month.month);
      final previousMonth = DateTime(selected.year, selected.month - 1);
      previous.add({
        'month': month.toIso8601String(),
        'previous': previousMonth.toIso8601String(),
        'label': DateFormat.MMMM().format(previousMonth),
      });
    }
    writeJson('$dir/deltas.json', {
      'tz': parityTz,
      'deltas': deltas,
      'previousMonths': previous,
    });
  });

  test('categorization rules and suggestions', () async {
    final rules = <Map<String, Object?>>[
      {'id': 'r1', 'merchantPattern': 'coffee', 'matchType': 'contains', 'transactionType': 'expense', 'category': 'Eating Out', 'priority': 0},
      {'id': 'r2', 'merchantPattern': '  Star  ', 'matchType': 'startsWith', 'category': 'Eating Out', 'priority': 5, 'tagIds': ['t1']},
      {'id': 'r3', 'merchantPattern': 'rent', 'matchType': 'exact', 'minimumAmount': 1000, 'maximumAmount': 2000.0, 'category': 'Housing', 'priority': 1},
      {'id': 'r4', 'merchantPattern': 'coffee', 'category': 'Groceries', 'priority': 10, 'isEnabled': false},
      {'id': 'r5', 'merchantPattern': '   ', 'category': 'General', 'priority': 100},
      {'id': 'r6', 'merchantPattern': 'salary', 'transactionType': 'income', 'category': 'Salary'},
      {'id': 'r7', 'merchantPattern': 'Café', 'matchType': 'contains', 'category': 'Eating Out', 'priority': 0},
      {'id': 'r8', 'merchantPattern': 'İstanbul', 'matchType': 'startsWith', 'category': 'Travel', 'priority': 0},
      {'id': 'r9', 'merchantPattern': 'shop', 'matchType': 'fuzzy', 'category': 'Clothing', 'priority': 0},
      {'id': 'r10', 'merchantPattern': 'shop', 'minimumAmount': 5.5, 'category': 'Gift', 'priority': 2},
      {'id': 'r11', 'merchantPattern': 'shop', 'maximumAmount': 5.5, 'category': 'Pets', 'priority': 2},
      {'id': 'r12', 'merchantPattern': 'gas', 'transactionType': 'bogus', 'category': 'Transportation', 'priority': 0},
      {'id': 'r13', 'merchantPattern': 'gas', 'category': 'Travel', 'priority': 3.7},
      {'id': 'r14', 'merchantPattern': 'uber', 'category': 'Transportation', 'priority': -1},
      {'id': 'r15', 'merchantPattern': 'COFFEE', 'matchType': 'exact', 'category': 'Groceries', 'priority': 0},
    ];
    await AtomicFinancialStore.instance
        .updateSection(FinancialSections.categorizationRules, rules);
    final provider = CategorizationProvider();
    await provider.load();
    final parsed = [
      for (final row in rules) CategorizationRule.fromJson(row),
    ];

    final descriptions = [
      'Coffee shop',
      '  COFFEE  ',
      'coffee',
      'Starbucks',
      'starbucks',
      ' star',
      'st',
      'rent',
      'Rent ',
      'rent payment',
      'Café au lait',
      'Café au lait',
      'İSTANBUL kebab',
      'istanbul',
      'ISTANBUL',
      'salary sept',
      'shop',
      'gas station',
      '',
      '   ',
      'uber eats',
      '﻿coffee ',
      '​coffee',
    ];
    final amounts = <double>[
      0,
      5.5,
      5.4999,
      1000,
      999.99,
      2000,
      2000.01,
      -1,
      double.nan,
      double.infinity,
    ];
    final queries = <Map<String, Object?>>[];
    for (final type in TransactionTyp.values) {
      for (final description in descriptions) {
        for (final amount in amounts) {
          queries.add({
            'type': type.name,
            'description': description,
            'amount': bitsHex(amount),
            'matches': [
              for (final rule in parsed)
                if (rule.matches(
                    type: type, description: description, amount: amount))
                  rule.id
            ],
            'suggestion': provider
                .suggest(type: type, description: description, amount: amount)
                ?.rule
                .id,
          });
        }
      }
    }
    writeJson('$dir/rules.json', {
      'tz': parityTz,
      'rules': jsonEncode(rules),
      'sortedIds': provider.rules.map((r) => r.id).toList(),
      'queries': queries,
    });
  });

  test('double.tryParse', () {
    final corpus = <String>[
      '', ' ', '\t\n', '0', '-0', '+0', '0.0', '-0.0', '00012', '12', '-12',
      '+12', '1.5', '-1.5', '+1.5', '.5', '-.5', '+.5', '5.', '-5.', '.',
      '-.', '+.', '-', '+', '1e3', '1E3', '1e+3', '1e-3', '1.5e3', '.5e1',
      '5.e1', '1e', '1e+', '1e-', 'e1', '.e1', '1e3.5', '1e03', '1e0003',
      '--1', '+-1', '-+1', '- 1', '1 2', '1,5', '1.500,00', '1,500.00',
      '12.34.56', r'$5', r'5$', '5%', '0x10', '0X1F', '0x1p3', '1_000',
      '0b101', '1f', '1d', '1.5f', 'Infinity', '-Infinity', '+Infinity',
      'infinity', 'INFINITY', 'Inf', '-Inf', 'inf', 'NaN', '-NaN', '+NaN',
      'nan', 'NAN', 'Infinityx', 'NaN1', ' Infinity ', ' NaN ',
      ' 3.14 ', '\t42\n', ' 3.14 ', '﻿7﻿', '\u00857',
      ' 7 ', '　7　', '​7', '7​', ' 7',
      ' 7 ', ' 7 ', '᠎7', '１２', '١٢', '٣.٥',
      '1e400', '-1e400', '1e-400', '-1e-400', '4.9e-324', '5e-324',
      '2.4703282292062327e-324', '2.4703282292062328e-324',
      '1.7976931348623157e308', '1.7976931348623158e308',
      '1.7976931348623159e308', '9007199254740993', '0.1', '0.3',
      '0.30000000000000004', '123456789012345678901234567890',
      '1e99999999999999999999', '1e-99999999999999999999',
      '0.${'0' * 400}1', '1${'0' * 400}', '${'9' * 800}.${'9' * 800}',
      '0.000001', '1e-7', '100', '1,000', '1.2.3', '١', '0.5\u0000', '\u00001',
    ];
    writeJson('$dir/try_parse.json', {
      'tz': parityTz,
      'cases': [
        for (final input in corpus)
          {'input': input, 'result': numberJson(double.tryParse(input))}
      ],
    });
  });
}
