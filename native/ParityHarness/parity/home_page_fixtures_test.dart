// Emits native/Fixtures/home/tz/<zone>/page.json : everything the real Home
// tab (SpendingPage, spending_page.dart) renders as text, for fixed stores,
// in America/New_York and America/Santiago (DST change at midnight).
//
// Each dataset is loaded through the app's own launch path (AppHarness, no
// generation), the page pumped at a pinned clock with a chosen month, and
// read back: the month pill; the hero (eyebrow, amount, in/out subline,
// status caption, semantics label); the spend gauge (fill fraction, SPENT
// and INCOME labels); both flow chips (label, amount, delta line); the
// safe-to-spend card (title, subtitle, amount, semantics label); the
// breakdown sheet it opens (every text, in order); the budget rows (name,
// subtitle, chip, bar fill) and the add row; the recent activity rows.
// `home_fixtures_test.dart` owns the rest of native/Fixtures/home/; this
// generator writes only home/tz/<zone>/.

import 'dart:convert';

import 'package:animated_digit/animated_digit.dart';
import 'package:budget_app/common.dart';
import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/spending_page.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/widgets/budgie_header.dart';
import 'package:budget_app/widgets/glow_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

Map<String, Object?> tx(
  String id,
  String type,
  double amount,
  String category,
  List date, {
  String? description,
  String? template,
  List created = const [2026, 9, 1, 8],
}) => {
  'id': id,
  'type': type,
  'description': description ?? id,
  'amount': amount,
  'category': category,
  'date': local(date).toIso8601String(),
  'recurringTemplateId': template,
  'tagIds': <String>[],
  'createdAt': local(created).toIso8601String(),
  'updatedAt': local(created).toIso8601String(),
};

Map<String, Object?> template(
  String id,
  String type,
  double amount,
  String category,
  String pattern,
  List next, {
  int? dom,
  bool active = true,
}) => {
  'id': id,
  'type': type,
  'description': id,
  'amount': amount,
  'category': category,
  'pattern': pattern,
  'startDate': local(next).toIso8601String(),
  'nextOccurrence': local(next).toIso8601String(),
  'dayOfMonth': dom,
  'dayOfWeek': pattern == 'monthly' ? null : local(next).weekday,
  'isActive': active,
};

Map<String, Object?> goal(
  String id,
  double target,
  double current,
  List targetDate,
  List created,
) => {
  'id': id,
  'name': id,
  'targetAmount': target,
  'currentAmount': current,
  'targetDate': local(targetDate).toIso8601String(),
  'createdAt': local(created).toIso8601String(),
  'completedAt': null,
};

final defaultClock = [2026, 9, 28, 9, 15];

List<Map<String, Object?>> typicalRows() => [
  tx('i9', 'income', 3200.0, 'Salary', [2026, 9, 1, 12]),
  tx('s1', 'expense', 150.25, 'Groceries', [2026, 9, 2, 12]),
  tx('s2', 'expense', 84.99, 'Eating Out', [2026, 9, 3, 12]),
  tx('s3', 'expense', 249.75, 'Groceries', [2026, 9, 4, 12]),
  tx('s4', 'expense', 1000.01, 'Housing', [2026, 9, 5, 12]),
  tx('s5', 'expense', 85.0, 'Health', [2026, 9, 6, 12]),
  tx('s6', 'expense', 50.0, 'Pets', [2026, 9, 7, 12]),
  tx('i8', 'income', 3000.0, 'Salary', [2026, 8, 1, 12]),
  tx('a1', 'expense', 0.1, 'Groceries', [2026, 8, 2, 12]),
  tx('a2', 'expense', 199.99, 'Travel', [2026, 8, 3, 12]),
];

const typicalLimits = <String, Object?>{
  'Groceries': 400.0,
  'Eating Out': 100.0,
  'Housing': 1000.0,
  'Health': 85.0,
  'Pets': 49.99,
  'Travel': 150.5,
};

List<Map<String, Object?>> typicalTemplates() => [
  template('gym', 'expense', 30.0, 'Health', 'weekly', [2026, 9, 29]),
  template('pay', 'income', 3200.0, 'Salary', 'monthly', [
    2026,
    9,
    30,
  ], dom: 30),
];

List<Map<String, Object?>> typicalGoals() => [
  goal('trip', 1200.0, 100.0, [2026, 12, 1], [2026, 1, 1, 9]),
];

class Dataset {
  final String name;
  final List clock;

  /// `[year, month]` of the month pill.
  final List month;
  final List<Map<String, Object?>> transactions;
  final Map<String, Object?> limits;
  final List<Map<String, Object?>> templates;
  final List<Map<String, Object?>> goals;
  final String currency;
  final String? locale;
  final bool hide;
  const Dataset(
    this.name, {
    required this.clock,
    required this.month,
    this.transactions = const [],
    this.limits = const {},
    this.templates = const [],
    this.goals = const [],
    this.currency = 'USD',
    this.locale,
    this.hide = false,
  });
}

List<Dataset> datasets() => [
  Dataset(
    'typical',
    clock: defaultClock,
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'no_income',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('e1', 'expense', 80.0, 'Groceries', [2026, 9, 3, 12]),
    ],
  ),
  Dataset(
    'shortfall',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('i', 'income', 1000.0, 'Salary', [2026, 9, 1, 12]),
      tx('h', 'expense', 2500.0, 'Housing', [2026, 9, 2, 12]),
      tx('ip', 'income', 900.0, 'Salary', [2026, 8, 1, 12]),
      tx('hp', 'expense', 300.0, 'Housing', [2026, 8, 2, 12]),
    ],
    limits: {'Housing': 2000.0, 'Groceries': 100.0},
    templates: [
      template('bill', 'expense', 300.0, 'Housing', 'monthly', [
        2026,
        9,
        29,
      ], dom: 29),
    ],
    goals: typicalGoals(),
  ),
  Dataset(
    'break_even',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('i', 'income', 500.0, 'Salary', [2026, 9, 1, 12]),
      tx('a', 'expense', 250.0, 'Groceries', [2026, 9, 2, 12]),
      tx('b', 'expense', 250.0, 'Eating Out', [2026, 9, 3, 12]),
    ],
  ),
  Dataset('empty', clock: defaultClock, month: [2026, 9]),
  Dataset(
    'hidden_balances',
    clock: defaultClock,
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
    hide: true,
  ),
  Dataset(
    'euro_de',
    clock: defaultClock,
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
    currency: 'EUR',
    locale: 'de_DE',
  ),
  Dataset(
    'yen_ja',
    clock: defaultClock,
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    currency: 'JPY',
    locale: 'ja_JP',
  ),
  Dataset(
    'closed_month',
    clock: defaultClock,
    month: [2026, 8],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'future_month',
    clock: defaultClock,
    month: [2026, 10],
    transactions: [
      ...typicalRows(),
      tx('f1', 'expense', 40.0, 'Travel', [2026, 10, 5, 12]),
    ],
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'last_day',
    clock: [2026, 9, 30, 12],
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'last_day_late',
    clock: [2026, 9, 30, 23, 59, 59, 999],
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
  ),
  // Santiago skips 2026-09-06 00:00-00:59 (local midnight does not
  // exist): its day count in the month, a day short, is checked on both
  // sides of the change and on the day.
  Dataset(
    'before_gap',
    clock: [2026, 9, 5, 23, 59, 59, 999],
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'gap_day',
    clock: [2026, 9, 6, 0, 30],
    month: [2026, 9],
    transactions: [
      ...typicalRows(),
      tx('g1', 'expense', 12.5, 'Eating Out', [2026, 9, 6, 0, 30]),
      tx('g2', 'income', 100.0, 'Salary', [2026, 9, 6]),
    ],
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  Dataset(
    'after_gap',
    clock: [2026, 9, 7, 0, 0],
    month: [2026, 9],
    transactions: typicalRows(),
    limits: typicalLimits,
    templates: typicalTemplates(),
    goals: typicalGoals(),
  ),
  // Santiago repeats 2026-04-04 23:00-23:59.
  Dataset(
    'fold_day',
    clock: [2026, 4, 4, 23, 30],
    month: [2026, 4],
    transactions: [
      tx('i4', 'income', 2000.0, 'Salary', [2026, 4, 1, 12]),
      tx('f1', 'expense', 60.0, 'Groceries', [2026, 4, 4, 23, 30]),
      tx('f2', 'expense', 15.0, 'Eating Out', [2026, 4, 4, 23, 59, 59, 999]),
      tx('f3', 'expense', 25.0, 'Groceries', [2026, 4, 5]),
      tx('p1', 'expense', 500.0, 'Housing', [2026, 3, 4, 12]),
      tx('p2', 'income', 1000.0, 'Salary', [2026, 3, 1, 12]),
    ],
    limits: {'Groceries': 100.0, 'Eating Out': 50.0},
    templates: [
      template('w', 'expense', 10.0, 'General', 'weekly', [2026, 4, 11]),
    ],
  ),
  Dataset(
    'budget_edges',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('b1', 'expense', 99.999, 'General', [2026, 9, 1, 12]),
      tx('b2', 'expense', 50.0, 'Eating Out', [2026, 9, 2, 12]),
      tx('b3', 'expense', 1000.5, 'Groceries', [2026, 9, 3, 12]),
      tx('b4', 'expense', 15.0, 'Housing', [2026, 9, 4, 12]),
      tx('b5', 'expense', 123456.789, 'Health', [2026, 9, 5, 12]),
      tx('b6', 'expense', 20.0, 'Travel', [2026, 9, 6, 12]),
      tx('b7', 'expense', 20.0, 'Clothing', [2026, 9, 7, 12]),
      tx('b8', 'expense', 84.99, 'Gift', [2026, 9, 8, 12]),
      tx('b9', 'expense', 85.0, 'Family', [2026, 9, 9, 12]),
      tx('b10', 'expense', 0.0, 'Books', [2026, 9, 10, 12]),
      tx('b11', 'expense', 7.0, 'groceries', [2026, 9, 11, 12]),
      tx('b12', 'income', 99999.99, 'Salary', [2026, 9, 12, 12]),
      tx('b13', 'income', 0.004, 'Salary', [2026, 9, 13, 12]),
    ],
    limits: {
      'General': 100.0,
      'Eating Out': 50.0,
      'Groceries': 1000.0,
      'Housing': 100.0,
      'Health': 1e6,
      'Travel': 40.0,
      'Clothing': 40.0,
      'Gift': 100.0,
      'Family': 100.0,
      'Books': 0.01,
      'Pets': 1.005,
      'Unknown Category': 10.0,
      'groceries': 10.0,
    },
  ),
  Dataset(
    'all_budgeted',
    clock: defaultClock,
    month: [2026, 9],
    transactions: typicalRows(),
    limits: {for (final name in expenseCategories.keys) name: 100.0},
  ),
  Dataset(
    'year_boundary',
    clock: [2027, 1, 15, 10],
    month: [2027, 1],
    transactions: [
      tx('j1', 'income', 2500.0, 'Salary', [2027, 1, 1, 12]),
      tx('j2', 'expense', 300.0, 'Groceries', [2027, 1, 3, 12]),
      tx('d1', 'income', 2000.0, 'Salary', [2026, 12, 1, 12]),
      tx('d2', 'expense', 900.0, 'Housing', [2026, 12, 3, 12]),
    ],
    limits: {'Groceries': 350.0},
  ),
  Dataset(
    'delta_down',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('i9', 'income', 1000.0, 'Salary', [2026, 9, 1, 12]),
      tx('i8', 'income', 1000.0, 'Salary', [2026, 8, 1, 12]),
      tx('e8', 'expense', 200.0, 'Groceries', [2026, 8, 2, 12]),
    ],
  ),
  Dataset(
    'delta_thirds',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('i9', 'income', 4000.0, 'Salary', [2026, 9, 1, 12]),
      tx('i8', 'income', 3000.0, 'Salary', [2026, 8, 1, 12]),
      tx('e9', 'expense', 100.0, 'Groceries', [2026, 9, 2, 12]),
      tx('e8', 'expense', 300.0, 'Groceries', [2026, 8, 2, 12]),
    ],
  ),
  Dataset(
    'delta_new_income',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx('i9', 'income', 1000.0, 'Salary', [2026, 9, 1, 12]),
      tx('e8', 'expense', 50.0, 'Groceries', [2026, 8, 2, 12]),
    ],
  ),
  Dataset(
    'recent_activity',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      tx(
        'r1',
        'expense',
        12.0,
        'Groceries',
        [2026, 9, 27, 9],
        created: [2026, 9, 27, 9, 1],
      ),
      tx(
        'r2',
        'expense',
        13.0,
        'Eating Out',
        [2026, 9, 27, 18],
        created: [2026, 9, 27, 18, 5],
        description: 'Lunch',
      ),
      tx(
        'r3',
        'income',
        500.0,
        'Salary',
        [2026, 9, 27],
        created: [2026, 9, 27, 20],
      ),
      tx(
        'r4',
        'expense',
        9.99,
        'Gift',
        [2026, 9, 27, 7],
        created: [2026, 9, 27, 20],
        description: '',
      ),
      tx(
        'r5',
        'expense',
        40.0,
        'Health',
        [2026, 9, 26, 12],
        template: 'gym',
        created: [2026, 9, 26, 12],
      ),
      tx(
        'r6',
        'expense',
        7.0,
        'Books',
        [2026, 10, 2, 12],
        created: [2026, 9, 20],
      ),
      tx(
        'r7',
        'expense',
        6.0,
        'Pets',
        [2026, 9, 6, 0, 30],
        created: [2026, 9, 6, 8],
      ),
      tx(
        'r8',
        'expense',
        5.0,
        'Pets',
        [2026, 4, 4, 23, 30],
        created: [2026, 4, 4, 23, 40],
      ),
    ],
    limits: {'Groceries': 20.0},
  ),
  Dataset(
    'recent_ties',
    clock: defaultClock,
    month: [2026, 9],
    transactions: [
      for (var i = 0; i < 6; i++)
        tx(
          't$i',
          i.isEven ? 'expense' : 'income',
          10.0 + i,
          'General',
          [2026, 9, 10, 12],
          created: [2026, 9, 10, 12],
        ),
    ],
  ),
];

Future<void> loadDataset(WidgetTester tester, Dataset d, AppHarness app) async {
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    await AtomicFinancialStore.instance.updateSections({
      'transactions': d.transactions,
      if (d.limits.isNotEmpty) 'categoryBudgetLimits': d.limits,
      if (d.templates.isNotEmpty) 'recurringTransactions': d.templates,
      if (d.goals.isNotEmpty) 'savingsGoals': d.goals,
    });
    await app.initialize(generate: false);
    // The launch path applies the stored settings (USD, balances shown);
    // this dataset's formatter is set after it.
    MoneyFormatter.configure(
      currencyCode: d.currency,
      locale: d.locale,
      hideBalances: d.hide,
    );
  });
}

bool isType(Widget w, String name) => w.runtimeType.toString() == name;

Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => isType(w, name), description: name);

/// The Text widgets under [parent] with their strings (rich text as plain).
List<String> textsUnder(
  WidgetTester tester,
  Finder parent, {
  bool skipDigits = false,
}) {
  final digits = skipDigits
      ? find
            .descendant(
              of: find.byType(AnimatedDigitWidget),
              matching: find.byType(Text),
            )
            .evaluate()
            .map((e) => e.widget)
            .toSet()
      : <Widget>{};
  return [
    for (final e
        in find.descendant(of: parent, matching: find.byType(Text)).evaluate())
      if (!digits.contains(e.widget))
        (e.widget as Text).data ??
            (e.widget as Text).textSpan?.toPlainText() ??
            '',
  ];
}

/// The label of the first Semantics widget under (or at) [parent] that has one.
String? semanticsLabel(WidgetTester tester, Finder parent) {
  for (final e
      in find
          .descendant(of: parent, matching: find.byType(Semantics))
          .evaluate()) {
    final label = (e.widget as Semantics).properties.label;
    if (label != null) return label;
  }
  return null;
}

Map<String, Object?> readPage(WidgetTester tester) {
  final hero = byTypeName('_HeroCashFlow');
  final gauge = byTypeName('_SpendGauge');
  final card = byTypeName('_SafeToSpendCard');
  final chips = byTypeName('_FlowChip');
  final rows = byTypeName('_BudgetRow');
  final addRow = byTypeName('_AddBudgetRow');
  final recent = byTypeName('_RecentActivityRow');
  return {
    'pill': tester.widget<MonthPill>(find.byType(MonthPill)).label,
    'hero': {
      'texts': textsUnder(tester, hero, skipDigits: true),
      'semantics': semanticsLabel(tester, hero),
    },
    'gauge': {
      'texts': textsUnder(tester, gauge),
      'value': bitsHex(
        tester
            .widget<GlowProgressBar>(
              find.descendant(
                of: gauge,
                matching: find.byType(GlowProgressBar),
              ),
            )
            .value,
      ),
    },
    'chips': [
      for (final e in chips.evaluate())
        textsUnder(tester, find.byElementPredicate((x) => x == e)),
    ],
    'card': {
      'texts': textsUnder(tester, card),
      'semantics': semanticsLabel(tester, card),
    },
    'budgets': {
      'rows': [
        for (final e in rows.evaluate())
          {
            'texts': textsUnder(tester, find.byElementPredicate((x) => x == e)),
            'bar': bitsHex(
              tester
                  .widget<GlowProgressBar>(
                    find.descendant(
                      of: find.byElementPredicate((x) => x == e),
                      matching: find.byType(GlowProgressBar),
                    ),
                  )
                  .value,
            ),
          },
      ],
      'add': addRow.evaluate().isEmpty
          ? null
          : textsUnder(tester, addRow.first),
    },
    'recent': {
      'empty': find.text('No transactions yet.').evaluate().isNotEmpty,
      'rows': [
        for (final e in recent.evaluate())
          textsUnder(tester, find.byElementPredicate((x) => x == e)),
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final zone = parityTz.replaceAll('/', '_');
  final cases = <Map<String, Object?>>[];

  setUp(() {
    seedUuids(71);
  });

  for (final d in datasets()) {
    testWidgets('page: ${d.name}', (tester) async {
      tester.view.physicalSize = const Size(1000, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // The test font is wider than Gabarito, so some rows overflow, and
      // the sheets trip debug-only checks that touch no value read here.
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
        MoneyFormatter.configure(
          currencyCode: d.currency,
          locale: d.locale,
          hideBalances: d.hide,
        );
        pinClock(local(d.clock));
        final app = AppHarness();
        await loadDataset(tester, d, app);
        final model = app.transactionModel;
        model.selectMonth(DateTime(d.month[0] as int, d.month[1] as int));

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TransactionModel>.value(value: model),
              ChangeNotifierProvider<RecurringTransactionModel>.value(
                value: app.recurringModel,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.light(),
              home: const SpendingPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final page = readPage(tester);

        // Open the breakdown sheet from the card and read every text.
        await tester.tap(byTypeName('_SafeToSpendCard'));
        await tester.pumpAndSettle();
        final sheet = textsUnder(tester, find.byType(BottomSheet));
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        cases.add({
          'name': d.name,
          'clock': local(d.clock).toIso8601String(),
          'clockUs': local(d.clock).microsecondsSinceEpoch,
          'month': local(d.month).toIso8601String(),
          'currency': d.currency,
          'locale': d.locale,
          'hide': d.hide,
          'sections': jsonEncode({
            'transactions': d.transactions,
            if (d.limits.isNotEmpty) 'categoryBudgetLimits': d.limits,
            if (d.templates.isNotEmpty) 'recurringTransactions': d.templates,
            if (d.goals.isNotEmpty) 'savingsGoals': d.goals,
          }),
          'expenseCategories': expenseCategories.keys.toList(),
          'page': page,
          'sheet': sheet,
        });
      } finally {
        MoneyFormatter.configure(currencyCode: 'USD');
        pinClock(null);
        FlutterError.onError = previousOnError;
      }
    });
  }

  test('write page.json', () {
    // Only home/tz/<zone>/ is this generator's: fixtureDir deletes the
    // directory it is given.
    final dir = fixtureDir('home/tz/$zone').path;
    writeJson('$dir/page.json', {'tz': parityTz, 'cases': cases});
  });
}
