// Emits native/Fixtures/monthlist/tz/<zone>/ : the real Home SEE ALL page
// (TransactionPage, transaction_page.dart) and the Spend category drill-in
// (CategoryTransactionsPage, category_transactions_page.dart), in
// America/New_York and America/Santiago (DST change at midnight).
//
// page.json: per dataset, loaded through the app's own launch path, the
// month chips (month and year texts, in order), and for every month, by
// tapping its chip: the summary card texts and the list in document order,
// each pinned date header (`DateFormat.yMMMd`) followed by its rows (id,
// description, "Category • Mon d", amount). A store without transactions
// shows the empty state instead.
//
// drillin.json: per (dataset, category, month): the header, the TOTAL SPENT
// card (total, month and count pills), the rows (id and texts, newest
// first) or the empty state's message.

import 'dart:convert';

import 'package:budget_app/category_transactions_page.dart';
import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/transaction_page.dart';
import 'package:budget_app/widgets/modern_transaction_list_item.dart';
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

class Dataset {
  final String name;
  final List<Map<String, Object?>> transactions;
  final String currency;
  final String? locale;
  final bool hide;

  /// `[category, [year, month]]` pairs to open the drill-in for, besides
  /// every pair that has expense rows.
  final List<(String, List)> extraDrillIns;
  final int maxDrillIns;
  const Dataset(
    this.name,
    this.transactions, {
    this.currency = 'USD',
    this.locale,
    this.hide = false,
    this.extraDrillIns = const [],
    this.maxDrillIns = 40,
  });
}

List<Dataset> datasets() => [
  Dataset(
    'typical',
    [
      tx('i9', 'income', 3200.0, 'Salary', [2026, 9, 1, 12]),
      tx('s1', 'expense', 150.25, 'Groceries', [2026, 9, 2, 12]),
      tx(
        's2',
        'expense',
        84.99,
        'Eating Out',
        [2026, 9, 2, 18],
        created: [2026, 9, 2, 18, 30],
      ),
      tx(
        's3',
        'expense',
        249.75,
        'Groceries',
        [2026, 9, 2, 9],
        created: [2026, 9, 2, 9, 30],
      ),
      tx('s4', 'expense', 1000.01, 'Housing', [
        2026,
        9,
        5,
        12,
      ], template: 'rent'),
      tx('s5', 'expense', 85.0, 'Health', [2026, 9, 6, 12]),
      tx('s6', 'expense', 50.0, 'Pets', [2026, 9, 7, 12]),
      tx('i8', 'income', 3000.0, 'Salary', [2026, 8, 1, 12]),
      tx('a1', 'expense', 0.1, 'Groceries', [2026, 8, 2, 12]),
      tx('a2', 'expense', 199.99, 'Travel', [2026, 8, 3, 12]),
      tx('a3', 'expense', 0.2, 'Groceries', [2026, 8, 3, 13]),
      tx('j1', 'expense', 40.0, 'Groceries', [2026, 7, 31, 23, 59, 59, 999]),
      tx('j2', 'income', 10.0, 'Salary', [2026, 7, 1]),
      tx('d1', 'expense', 12.0, 'Eating Out', [2025, 12, 31, 23, 59, 59, 999]),
      tx('d2', 'expense', 13.0, 'Eating Out', [2026, 1, 1]),
      tx('d3', 'income', 100.0, 'Salary', [2025, 12, 15]),
      tx('f1', 'expense', 7.5, 'Travel', [2027, 2, 14, 10]),
    ],
    extraDrillIns: [
      ('Groceries', [2026, 10]),
      ('Nope', [2026, 9]),
      ('Salary', [2026, 9]),
      ('groceries', [2026, 9]),
      ('Travel', [2027, 2]),
    ],
  ),
  Dataset(
    'dst',
    [
      // Santiago: 2026-09-06 00:00-00:59 does not exist.
      tx('g0', 'expense', 1.0, 'General', [2026, 9, 5, 23, 59, 59, 999]),
      tx('g1', 'expense', 2.0, 'General', [2026, 9, 6]),
      tx('g2', 'expense', 3.0, 'General', [2026, 9, 6, 0, 30]),
      tx('g3', 'expense', 4.0, 'General', [2026, 9, 6, 0, 59, 59, 999]),
      tx('g4', 'expense', 5.0, 'General', [2026, 9, 6, 1]),
      tx('g5', 'income', 6.0, 'Salary', [2026, 9, 6, 12]),
      tx('g6', 'expense', 7.0, 'General', [2026, 9, 7]),
      // Santiago: 2026-04-04 23:00-23:59 happens twice.
      tx('f0', 'expense', 10.0, 'General', [2026, 4, 4, 22, 59]),
      tx('f1', 'expense', 11.0, 'General', [2026, 4, 4, 23]),
      tx('f2', 'expense', 12.0, 'General', [2026, 4, 4, 23, 30]),
      tx('f3', 'expense', 13.0, 'General', [2026, 4, 4, 23, 59, 59, 999]),
      tx('f4', 'expense', 14.0, 'General', [2026, 4, 5]),
      tx('f5', 'expense', 15.0, 'General', [2026, 4, 5, 0, 30]),
      // New York: 2026-03-08 02:00-02:59 missing, 2026-11-01 01:00-01:59 twice.
      tx('n1', 'expense', 20.0, 'General', [2026, 3, 8, 1, 59]),
      tx('n2', 'expense', 21.0, 'General', [2026, 3, 8, 2, 30]),
      tx('n3', 'expense', 22.0, 'General', [2026, 3, 8, 3]),
      tx('n4', 'expense', 23.0, 'General', [2026, 11, 1, 0, 30]),
      tx('n5', 'expense', 24.0, 'General', [2026, 11, 1, 1, 30]),
      tx('n6', 'expense', 25.0, 'General', [2026, 11, 1, 2]),
      // Lord Howe: 2026-10-04 02:00-02:29 missing, 2026-04-05 01:30-01:59 twice.
      tx('l1', 'expense', 30.0, 'General', [2026, 10, 4, 2, 15]),
      tx('l2', 'expense', 31.0, 'General', [2026, 10, 4, 1, 59]),
      tx('l3', 'expense', 32.0, 'General', [2026, 4, 5, 1, 45]),
      // Ties: same day, same createdAt, ids decide; and same instant.
      for (var i = 0; i < 5; i++)
        tx(
          'z${'abcde'[i]}',
          i.isEven ? 'expense' : 'income',
          100.0 + i,
          'General',
          [2026, 6, 15, 12],
          created: [2026, 6, 15, 12],
        ),
      tx(
        'zz-late',
        'expense',
        1.0,
        'General',
        [2026, 6, 15, 8],
        created: [2026, 6, 15, 13],
      ),
      tx(
        'zz-early',
        'expense',
        1.0,
        'General',
        [2026, 6, 15, 20],
        created: [2026, 6, 15, 7],
      ),
    ],
    extraDrillIns: [
      ('General', [2026, 1]),
    ],
  ),
  Dataset(
    'income_only',
    [
      tx('i1', 'income', 1000.0, 'Salary', [2026, 9, 1, 12]),
      tx('i2', 'income', 250.5, 'Salary', [2026, 9, 1, 14]),
      tx('i3', 'income', 99.99, 'Salary', [2026, 8, 10]),
    ],
    extraDrillIns: [
      ('Salary', [2026, 9]),
    ],
  ),
  Dataset('empty', const []),
  Dataset(
    'unicode',
    [
      tx('u1', 'expense', 30.0, 'Café', [
        2026,
        9,
        2,
        12,
      ], description: 'Café ☕️ "quoted" \u{1F355}'),
      tx('u2', 'expense', 20.0, 'Café', [
        2026,
        9,
        2,
        13,
      ], description: 'decomposed'),
      tx('u3', 'expense', 12.5, '\u{1F355} Pizza', [
        2026,
        9,
        3,
        12,
      ], description: ''),
      tx('u4', 'expense', 8.0, 'straße', [
        2026,
        9,
        4,
        12,
      ], description: 'Straße ǆungla'),
      tx('u5', 'expense', 5.0, 'STRASSE', [2026, 9, 4, 13]),
      tx('u6', 'income', 1e9, 'Salary', [
        2026,
        9,
        5,
        12,
      ], description: 'x' * 120),
      tx('u7', 'expense', 0.004, 'Café', [2026, 9, 6, 12]),
      tx('u8', 'expense', 0.0, 'Café', [2026, 9, 7, 12]),
      tx('u9', 'expense', -5.0, 'Café', [2026, 9, 8, 12]),
      tx('u10', 'expense', 1234567.891, 'Café', [2026, 9, 9, 12]),
    ],
    extraDrillIns: [
      ('Café', [2026, 9]),
      ('café', [2026, 9]),
    ],
  ),
  Dataset(
    'hidden_euro',
    [
      tx('h1', 'income', 3200.0, 'Salary', [2026, 9, 1, 12]),
      tx('h2', 'expense', 84.99, 'Eating Out', [2026, 9, 2, 12]),
      tx('h3', 'expense', 10.0, 'Eating Out', [2026, 9, 3, 12]),
    ],
    currency: 'EUR',
    locale: 'de_DE',
    hide: true,
    extraDrillIns: [
      ('Eating Out', [2026, 9]),
    ],
  ),
  Dataset(
    'euro_de',
    [
      tx('h1', 'income', 3200.0, 'Salary', [2026, 9, 1, 12]),
      tx('h2', 'expense', 84.99, 'Eating Out', [2026, 9, 2, 12]),
      tx('h3', 'expense', 1234.5, 'Eating Out', [2026, 9, 3, 12]),
      tx('h4', 'expense', 5000.0, 'Housing', [2026, 8, 3, 12]),
    ],
    currency: 'EUR',
    locale: 'de_DE',
  ),
  Dataset('many', [
    for (var i = 0; i < 48; i++)
      tx(
        'm$i',
        i % 6 == 0 ? 'income' : 'expense',
        5.0 + i * 3.17,
        ['General', 'Groceries', 'Eating Out'][i % 3],
        [2026, 5 + i % 4, 1 + (i * 5) % 28, 6 + i % 14, i % 60],
        created: [2026, 5, 1, 8, i % 60, i ~/ 60],
      ),
  ]),
];

bool isType(Widget w, String name) => w.runtimeType.toString() == name;

Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => isType(w, name), description: name);

List<String> textsUnder(Finder parent) => [
  for (final e
      in find.descendant(of: parent, matching: find.byType(Text)).evaluate())
    (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '',
];

Future<void> loadDataset(WidgetTester tester, Dataset d, AppHarness app) async {
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    await AtomicFinancialStore.instance.updateSections({
      'transactions': d.transactions,
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

void wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(3200, 8000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void Function(FlutterErrorDetails)? quiet() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    if (text.contains('overflowed') ||
        text.contains("deactivated widget's ancestor")) {
      return;
    }
    previous?.call(details);
  };
  return previous;
}

Widget app(TransactionModel model, Widget home) =>
    ChangeNotifierProvider<TransactionModel>.value(
      value: model,
      child: MaterialApp(theme: ThemeData.light(), home: home),
    );

/// The list in document order: each pinned date header then its rows.
List<Map<String, Object?>> readList(WidgetTester tester) {
  final out = <Map<String, Object?>>[];
  final items = find.byWidgetPredicate(
    (w) => w is SliverPersistentHeader || w is ModernTransactionListItem,
  );
  for (final e in items.evaluate()) {
    final w = e.widget;
    final finder = find.byElementPredicate((x) => x == e);
    if (w is ModernTransactionListItem) {
      out.add({'row': w.transaction.id, 'texts': textsUnder(finder)});
    } else {
      out.add({'header': textsUnder(finder)});
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final zone = parityTz.replaceAll('/', '_');
  final pages = <Map<String, Object?>>[];
  final drillIns = <Map<String, Object?>>[];

  setUp(() {
    seedUuids(81);
    pinClock(DateTime(2026, 9, 28, 9, 15));
  });

  for (final d in datasets()) {
    testWidgets('page: ${d.name}', (tester) async {
      wide(tester);
      final previousOnError = quiet();
      try {
        MoneyFormatter.configure(
          currencyCode: d.currency,
          locale: d.locale,
          hideBalances: d.hide,
        );
        final harness = AppHarness();
        await loadDataset(tester, d, harness);
        final model = harness.transactionModel;
        await tester.pumpWidget(app(model, const TransactionPage()));
        await tester.pumpAndSettle();

        final available = model.getAvailableMonths();
        final out = <String, Object?>{
          'name': d.name,
          'currency': d.currency,
          'locale': d.locale,
          'hide': d.hide,
          'sections': jsonEncode({'transactions': d.transactions}),
          'availableMonths': [for (final m in available) m.toIso8601String()],
          'title': textsUnder(find.byType(AppBar)),
        };
        if (available.isEmpty) {
          out['empty'] = textsUnder(find.byType(Scaffold));
        } else {
          out['chips'] = [
            for (final e in byTypeName('_MonthChip').evaluate())
              textsUnder(find.byElementPredicate((x) => x == e)),
          ];
          final months = <Map<String, Object?>>[];
          for (var i = 0; i < available.length; i++) {
            if (i > 0) {
              await tester.tap(byTypeName('_MonthChip').at(i));
              await tester.pumpAndSettle();
            }
            months.add({
              'month': available[i].toIso8601String(),
              'summary': textsUnder(byTypeName('_MonthlySummaryCard')),
              'list': readList(tester),
            });
          }
          out['months'] = months;
        }
        pages.add(out);
      } finally {
        MoneyFormatter.configure(currencyCode: 'USD');
        FlutterError.onError = previousOnError;
      }
    });

    testWidgets('drill-in: ${d.name}', (tester) async {
      wide(tester);
      final previousOnError = quiet();
      try {
        MoneyFormatter.configure(
          currencyCode: d.currency,
          locale: d.locale,
          hideBalances: d.hide,
        );
        final harness = AppHarness();
        await loadDataset(tester, d, harness);
        final model = harness.transactionModel;

        // Every (category, month) with expense rows, in first-appearance
        // order, then the extra pairs.
        final pairs = <(String, DateTime)>[];
        final seen = <String>{};
        for (final t in model.transactions) {
          if (t.type.name != 'expense') continue;
          final month = DateTime(t.date.year, t.date.month);
          if (seen.add('${t.category}\u0000${month.toIso8601String()}')) {
            pairs.add((t.category, month));
          }
        }
        for (final (category, month) in d.extraDrillIns) {
          pairs.add((category, local(month)));
        }
        for (final (category, month) in pairs.take(d.maxDrillIns)) {
          await tester.pumpWidget(
            app(
              model,
              CategoryTransactionsPage(
                category: category,
                categoryColor: Colors.teal,
                categoryIcon: Icons.category,
                month: month,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rows = <Map<String, Object?>>[];
          for (final e in find.byType(Dismissible).evaluate()) {
            rows.add({
              'id': ((e.widget as Dismissible).key as ValueKey<String>).value,
              'texts': textsUnder(find.byElementPredicate((x) => x == e)),
            });
          }
          final texts = textsUnder(find.byType(Scaffold));
          drillIns.add({
            'dataset': d.name,
            'category': category,
            'month': month.toIso8601String(),
            'currency': d.currency,
            'locale': d.locale,
            'hide': d.hide,
            'sections': jsonEncode({'transactions': d.transactions}),
            'texts': texts,
            'rows': rows,
            'hasEyebrow': texts.contains('TRANSACTIONS'),
          });
        }
      } finally {
        MoneyFormatter.configure(currencyCode: 'USD');
        FlutterError.onError = previousOnError;
      }
    });
  }

  test('write page.json and drillin.json', () {
    final dir = fixtureDir('monthlist/tz/$zone').path;
    writeJson('$dir/page.json', {'tz': parityTz, 'cases': pages});
    writeJson('$dir/drillin.json', {'tz': parityTz, 'cases': drillIns});
  });
}
