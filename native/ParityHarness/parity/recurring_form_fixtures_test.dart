// Emits native/Fixtures/recurring_form/tz/<zone>/validation.json : the real
// recurring transaction form (`showRecurringTransactionForm`,
// recurring_transaction_form.dart) driven through its Save button, in
// several zones (run.sh): America/New_York, America/Santiago (DST change at
// midnight) and Australia/Lord_Howe (30-minute change).
//
// Per case the form is opened at a pinned clock, in add mode or editing a
// template, its amount and description typed, Save tapped, and what the
// form showed is read back: the amount, description and start-date error
// texts, whether the dialog closed, the template it stored (and, for an
// add, the transactions the generator logged right after), and the initial
// position of the Day of Month / Day of Week wheel.
//
// The start-date rule is `startDate.isBefore(now.subtract(Duration(days:
// 365)))`: 365 elapsed days, which is not one calendar year across a DST
// change, so starts are placed around that instant (and around the local
// days next to it) at clocks on, before and after each zone's transitions.
// The date picker itself is not driven: a picked day is a local midnight,
// which an edit of a template that starts at that midnight reproduces.

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/recurring_transaction.dart';
import 'package:budget_app/recurring_transaction_form.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/widgets/modern_text_field.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

String get zoneDir => 'recurring_form/tz/${parityTz.replaceAll('/', '_')}';

Map<String, Object?> dt(DateTime d) => {
  'iso': d.toIso8601String(),
  'us': d.microsecondsSinceEpoch,
};

/// The form's Day of Month wheel when its pattern is monthly, else its Day
/// of Week wheel: `FixedExtentScrollController(initialItem: value - 1)`.
Map<String, Object?> wheel(WidgetTester tester) {
  final pickers = tester
      .widgetList<CupertinoPicker>(find.byType(CupertinoPicker))
      .toList();
  final pattern = tester.widget<CupertinoPicker>(
    find.byType(CupertinoPicker).at(1),
  );
  final patternIndex =
      (pattern.scrollController as FixedExtentScrollController).initialItem;
  final third = pickers[2].scrollController as FixedExtentScrollController;
  return {
    'kind': RecurrencePattern.values[patternIndex] == RecurrencePattern.monthly
        ? 'dayOfMonth'
        : 'dayOfWeek',
    'value': third.initialItem + 1,
  };
}

List<String> dialogTexts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: find.byType(Dialog), matching: find.byType(Text)),
  ))
    t.data ?? '',
];

class Case {
  final String label;
  final DateTime now;
  final bool edit;
  final String amount;
  final String description;

  /// The edited template (edit mode only).
  final RecurringTransaction? template;
  final TransactionTyp type;
  const Case(
    this.label,
    this.now, {
    this.edit = false,
    this.amount = '10',
    this.description = 'Rent',
    this.template,
    this.type = TransactionTyp.expense,
  });
}

RecurringTransaction stored(
  DateTime start, {
  double amount = 900.0,
  RecurrencePattern pattern = RecurrencePattern.monthly,
  int dom = 15,
  String description = 'Rent',
  int? weekday,
}) => RecurringTransaction(
  id: 'edit-1',
  type: TransactionTyp.expense,
  description: description,
  amount: amount,
  category: 'Housing',
  pattern: pattern,
  startDate: start,
  dayOfMonth: pattern == RecurrencePattern.monthly ? dom : null,
  dayOfWeek: pattern == RecurrencePattern.monthly
      ? null
      : (weekday ?? start.weekday),
);

final launch = DateTime(2026, 9, 28, 9, 15, 30, 250, 125);

List<Case> cases() {
  final out = <Case>[];
  // Amount text, add mode.
  for (final a in [
    '',
    ' ',
    'abc',
    '1,5',
    'NaN',
    'Infinity',
    '-Infinity',
    '1e400',
    '0',
    '-5',
    '-0',
    '0.00',
    '12.50',
    ' 12 ',
    '.5',
    '5.',
    '1e3',
    '0x10',
    '+5',
    '1_000',
    '١٢',
    '1.2.3',
    '\$5',
    '0.001',
    '1e-7',
    '1e21',
    '0.1',
    '100',
  ]) {
    out.add(Case('amount ${jsonEncode(a)}', launch, amount: a));
  }
  // Description text, add mode.
  for (final d in [
    '',
    ' ',
    '﻿ \n\t',
    ' ',
    ' x ',
    '  Rent ﻿',
    '​',
    '\u0085',
    'x',
  ]) {
    out.add(Case('description ${jsonEncode(d)}', launch, description: d));
  }
  out.add(
    Case(
      'all three',
      launch,
      edit: true,
      amount: '',
      description: ' ',
      template: stored(DateTime(2024, 1, 15)),
    ),
  );
  // Edit: the amount field starts as toStringAsFixed(2) of the stored one
  // and is left alone.
  for (final (i, amount) in [
    12.345,
    0.001,
    1e21,
    0.1 + 0.2,
    100.0,
    1234.5,
    0.005,
  ].indexed) {
    final t = stored(DateTime(2026, 6, 15), amount: amount);
    out.add(
      Case(
        'edit prefill $i ${t.amount}',
        launch,
        edit: true,
        amount: t.amount.toStringAsFixed(2),
        template: t,
      ),
    );
  }
  // Edit, other patterns: the wheel that is shown and what is stored.
  out.add(
    Case(
      'edit weekly',
      launch,
      edit: true,
      amount: '900.00',
      template: stored(
        DateTime(2026, 6, 15),
        pattern: RecurrencePattern.weekly,
        weekday: 3,
      ),
    ),
  );
  out.add(
    Case(
      'edit biweekly',
      launch,
      edit: true,
      amount: '900.00',
      template: stored(
        DateTime(2026, 6, 15),
        pattern: RecurrencePattern.biweekly,
      ),
    ),
  );
  out.add(
    Case(
      'edit monthly day 31',
      launch,
      edit: true,
      amount: '900.00',
      template: stored(DateTime(2026, 1, 31), dom: 31),
    ),
  );
  out.add(
    Case(
      'edit income',
      launch,
      edit: true,
      type: TransactionTyp.income,
      amount: '900.00',
      template: stored(DateTime(2026, 6, 15)),
    ),
  );
  out.add(Case('add income', launch, type: TransactionTyp.income));

  // The start-date rule, at several clocks. The start of an edited template
  // is what the form validates when its date is left alone.
  final clocks = <(String, DateTime)>[
    ('launch', launch),
    ('Santiago gap day', DateTime(2026, 9, 6, 0, 30)),
    ('Santiago fold day', DateTime(2026, 4, 4, 23, 30)),
    ('New York gap day', DateTime(2026, 3, 8, 3, 30)),
    ('New York fold day', DateTime(2026, 11, 1, 1, 30)),
    ('Lord Howe gap day', DateTime(2026, 10, 4, 2, 45)),
    ('Lord Howe fold day', DateTime(2026, 4, 5, 1, 45)),
    ('leap day', DateTime(2028, 3, 1, 12)),
    ('midnight', DateTime(2026, 9, 28)),
  ];
  for (final (name, now) in clocks) {
    final floor = now.subtract(const Duration(days: 365));
    final starts = <(String, DateTime)>[
      ('floor', floor),
      ('floor - 1 us', floor.subtract(const Duration(microseconds: 1))),
      ('floor + 1 us', floor.add(const Duration(microseconds: 1))),
      ('floor - 1 h', floor.subtract(const Duration(hours: 1))),
      ('floor + 1 h', floor.add(const Duration(hours: 1))),
      ('floor - 1 day', floor.subtract(const Duration(days: 1))),
      ('floor + 1 day', floor.add(const Duration(days: 1))),
      ('same day last year', DateTime(now.year - 1, now.month, now.day)),
      (
        'same time last year',
        DateTime(now.year - 1, now.month, now.day, now.hour, now.minute),
      ),
      (
        'midnight of the floor day',
        DateTime(floor.year, floor.month, floor.day),
      ),
      (
        'midnight after the floor day',
        DateTime(floor.year, floor.month, floor.day + 1),
      ),
      ('now', now),
      ('tomorrow', DateTime(now.year, now.month, now.day + 1)),
    ];
    for (final (startName, start)
        in (name == 'launch'
            ? starts
            : starts.where(
                (s) => !{
                  'floor - 1 day',
                  'floor + 1 day',
                  'tomorrow',
                  'now',
                }.contains(s.$1),
              ))) {
      out.add(
        Case(
          'start $startName @ $name',
          now,
          edit: true,
          amount: '900.00',
          template: stored(start),
        ),
      );
    }
  }
  out.add(
    Case(
      'start years ago',
      launch,
      edit: true,
      amount: '900.00',
      template: stored(DateTime(2024, 3, 15, 8, 30)),
    ),
  );
  out.add(
    Case(
      'start far future',
      launch,
      edit: true,
      amount: '900.00',
      template: stored(DateTime(2030, 1, 1)),
    ),
  );
  return out;
}

Future<void> settle(
  WidgetTester tester,
  TransactionModel transactions,
  RecurringTransactionModel recurring,
) async {
  await tester.runAsync(() async {
    var stable = 0;
    var last = '';
    for (var i = 0; i < 400 && stable < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final now =
          '${transactions.transactions.length}/${recurring.recurringTransactions.map((t) => t.nextOccurrence.microsecondsSinceEpoch).join(',')}';
      stable = now == last ? stable + 1 : 0;
      last = now;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final results = <Map<String, Object?>>[];

  setUp(() {
    seedUuids(61);
  });

  for (final c in cases()) {
    testWidgets('form: ${c.label}', (tester) async {
      tester.view.physicalSize = const Size(1000, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
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
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('recurring_form_fixture'),
      );
      try {
        SharedPreferences.setMockInitialValues({});
        await tester.runAsync(() async {
          await AtomicFinancialStore.instance.resetForTesting(directory: dir!);
        });
        pinClock(c.now);
        final transactions = TransactionModel();
        final recurring = RecurringTransactionModel();
        if (c.template != null) {
          recurring.recurringTransactions.add(c.template!);
        }

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TransactionModel>.value(
                value: transactions,
              ),
              ChangeNotifierProvider<RecurringTransactionModel>.value(
                value: recurring,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.light(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => showRecurringTransactionForm(
                        context,
                        c.type,
                        c.template,
                      ),
                      child: const Text('open form'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open form'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);

        final title = dialogTexts(tester).first;
        final initialWheel = wheel(tester);
        final fields = find.descendant(
          of: find.byType(ModernTextField),
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.at(0), c.amount);
        await tester.enterText(fields.at(1), c.description);
        await tester.pump();
        final before = dialogTexts(tester);

        await tester.tap(find.text(c.edit ? 'Update' : 'Save'));
        await tester.pumpAndSettle();

        final closed = find.byType(Dialog).evaluate().isEmpty;
        String? amountError, descriptionError, startError;
        if (!closed) {
          final boxes = tester
              .widgetList<ModernTextField>(find.byType(ModernTextField))
              .toList();
          amountError = boxes[0].errorText;
          descriptionError = boxes[1].errorText;
          final fresh = dialogTexts(tester).toList();
          for (final text in before) {
            fresh.remove(text);
          }
          if (amountError != null) fresh.remove(amountError);
          if (descriptionError != null) fresh.remove(descriptionError);
          // What is left is the start-date error (and nothing else).
          startError = fresh.isEmpty ? null : fresh.single;
          // A field that kept its error text since the last frame must not
          // also be listed twice.
        }

        Map<String, Object?>? storedRow;
        String? storedAmountBits;
        List<Map<String, Object?>>? generated;
        if (closed) {
          await settle(tester, transactions, recurring);
          final templates = recurring.recurringTransactions;
          final row = c.edit
              ? templates.firstWhere((t) => t.id == c.template!.id)
              : templates.single;
          storedAmountBits = bitsHex(row.amount);
          storedRow = row.toJson();
          // NaN and infinity (which the form lets through) are not JSON.
          if (!row.amount.isFinite) storedRow['amount'] = 'non-finite';
          if (!c.edit) {
            generated = [
              for (final t in transactions.transactions)
                {
                  'date': dt(t.date),
                  'recurringTemplateId': t.recurringTemplateId,
                  'amount': bitsHex(t.amount),
                  'description': t.description,
                },
            ];
            storedRow = {
              ...storedRow,
              // The id is random in Dart; compare the rest.
              'id': '<new>',
            };
            for (final g in generated) {
              g['recurringTemplateId'] = '<new>';
            }
          }
        }

        results.add({
          'label': c.label,
          'mode': c.edit ? 'edit' : 'add',
          'type': c.type.name,
          'now': dt(c.now),
          'title': title,
          'amountText': c.amount,
          'descriptionText': c.description,
          'template': c.template == null ? null : c.template!.toJson(),
          'templateStart': c.template == null
              ? null
              : dt(c.template!.startDate),
          'wheel': initialWheel,
          'closed': closed,
          'amountError': amountError,
          'descriptionError': descriptionError,
          'startError': startError,
          'stored': storedRow,
          'storedAmount': storedAmountBits,
          'storedStart': storedRow == null
              ? null
              : dt(DateTime.parse(storedRow['startDate'] as String)),
          'generated': generated,
        });
        pinClock(null);
      } finally {
        FlutterError.onError = previousOnError;
        await tester.runAsync(() async {
          await AtomicFinancialStore.instance.resetForTesting();
          await dir!.delete(recursive: true);
        });
      }
    });
  }

  test('write validation.json', () {
    writeJson('$fixturesRoot/$zoneDir/validation.json', {
      'tz': parityTz,
      'cases': results,
    });
  });
}
