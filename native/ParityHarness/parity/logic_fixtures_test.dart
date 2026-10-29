// Emits native/Fixtures/logic/ : expected outputs of the real Dart code for
// fixed inputs. Zone-dependent outputs go to logic/tz/<zone>/; the rest are
// written once (from the UTC run).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/net_worth_entry.dart';
import 'package:budget_app/recurring_transaction.dart';
import 'package:budget_app/safe_to_spend.dart';
import 'package:budget_app/savings_goal.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_generator.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';
import 'model_summary.dart';

final bool writeZoneIndependent = parityTz == 'UTC';
String get zoneDir => 'logic/tz/${parityTz.replaceAll('/', '_')}';

Map<String, Object?> dt(DateTime d) => {
      'iso': d.toIso8601String(),
      'us': d.microsecondsSinceEpoch,
      'isUtc': d.isUtc,
      'weekday': d.weekday,
    };

Map<String, Object?> tryParse(String input) {
  try {
    return {'input': input, 'result': dt(DateTime.parse(input))};
  } on FormatException {
    return {'input': input, 'error': 'FormatException'};
  }
}

class FakePathProvider extends PathProviderPlatform {
  final String temp;
  FakePathProvider(this.temp);
  @override
  Future<String?> getTemporaryPath() async => temp;
}

class FakeShare extends SharePlatform {
  final shared = <String>[];
  @override
  Future<ShareResult> shareXFiles(List<XFile> files,
      {String? subject,
      String? text,
      Rect? sharePositionOrigin,
      List<String>? fileNameOverrides}) async {
    shared.addAll(files.map((f) => f.path));
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    pinClock(DateTime(2026, 1, 1, 12));
    seedUuids(3);
  });

  test('dates', () {
    final parses = [
      '2026-03-05T14:30:00.000',
      '2026-03-05T14:30:00.123456',
      '2026-03-05T14:30:00.1234567',
      '2026-03-05T14:30:00.1',
      '2026-03-05 14:30:00',
      '2026-03-05',
      '20260305',
      '2026-03-05T14:30',
      '2026-03-05T24:00:00',
      '2026-02-30',
      '2026-13-01',
      '2026-3-5',
      ' 2026-03-05',
      '2026-03-05T14:30:00.000Z',
      '2026-03-05T14:30:00.000+05:30',
      '2026-03-05T14:30:00-0800',
      '2026-03-08T02:30:00.000',
      '2026-03-08T03:30:00.000',
      '2026-11-01T01:30:00.000',
      '2026-11-01T00:59:59.999999',
      '2026-03-29T01:30:00.000',
      '2026-10-25T01:30:00.000',
      '2026-10-04T02:15:00.000',
      '2026-04-05T02:15:00.000',
      '2026-04-05T01:45:00.000',
      // Midnight DST: America/Santiago has no 2026-09-06 00:00-00:59 and
      // repeats 2026-04-04 23:00-23:59; Asia/Beirut has no 2026-03-29
      // 00:00-00:59 and repeats 2026-10-24 23:00-23:59.
      '2026-09-05T23:59:59.999',
      '2026-09-06T00:00:00.000',
      '2026-09-06T00:30:00.000',
      '2026-09-06T00:59:59.999',
      '2026-09-06T01:00:00.000',
      '2026-04-04T22:59:59.999',
      '2026-04-04T23:00:00.000',
      '2026-04-04T23:30:00.000',
      '2026-04-04T23:59:59.999',
      '2026-04-05T00:00:00.000',
      '2026-03-28T23:59:59.999',
      '2026-03-29T00:00:00.000',
      '2026-03-29T00:30:00.000',
      '2026-03-29T01:00:00.000',
      '2026-10-24T22:59:59.999',
      '2026-10-24T23:30:00.000',
      '2026-10-24T23:59:59.999',
      '2026-10-25T00:00:00.000',
      '2026-09-06',
      '2026-03-29',
      '2024-02-29T12:00:00.000',
      '1999-12-31T23:59:59.999',
      '0099-01-01T00:00:00.000',
      '2026-01-31T23:59:59.999999',
      'not a date',
      '',
    ];

    final constructed = <Map<String, Object?>>[];
    void make(String label, DateTime value) =>
        constructed.add({'label': label, ...dt(value)});
    make('2026,2,31', DateTime(2026, 2, 31));
    make('2026,1,0', DateTime(2026, 1, 0));
    make('2026,13,1', DateTime(2026, 13, 1));
    make('2026,0,1', DateTime(2026, 0, 1));
    make('2026,-1,1', DateTime(2026, -1, 1));
    make('2026,3,0', DateTime(2026, 3, 0));
    make('2024,3,0', DateTime(2024, 3, 0));
    make('2026,1,1,25', DateTime(2026, 1, 1, 25));
    make('2026,3,8,2,30', DateTime(2026, 3, 8, 2, 30));
    make('2026,11,1,1,30', DateTime(2026, 11, 1, 1, 30));
    make('2026,3,29,1,30', DateTime(2026, 3, 29, 1, 30));
    make('2026,10,4,2,30', DateTime(2026, 10, 4, 2, 30));
    make('2026,10,4,2,15', DateTime(2026, 10, 4, 2, 15));
    make('2026,4,5,1,45', DateTime(2026, 4, 5, 1, 45));
    make('2026,4,5,2,15', DateTime(2026, 4, 5, 2, 15));
    make('2026,9,5,23,59', DateTime(2026, 9, 5, 23, 59));
    make('2026,9,6', DateTime(2026, 9, 6));
    make('2026,9,6,0,30', DateTime(2026, 9, 6, 0, 30));
    make('2026,9,6,1', DateTime(2026, 9, 6, 1));
    make('2026,9,5,24', DateTime(2026, 9, 5, 24));
    make('2026,9,7,-1', DateTime(2026, 9, 7, -1));
    make('2026,4,4,23,30', DateTime(2026, 4, 4, 23, 30));
    make('2026,4,4,23,59', DateTime(2026, 4, 4, 23, 59));
    make('2026,4,5', DateTime(2026, 4, 5));
    make('2026,3,29', DateTime(2026, 3, 29));
    make('2026,3,29,0,30', DateTime(2026, 3, 29, 0, 30));
    make('2026,3,28,24', DateTime(2026, 3, 28, 24));
    make('2026,10,24,23,30', DateTime(2026, 10, 24, 23, 30));
    make('2026,10,25', DateTime(2026, 10, 25));
    make('99,1,1', DateTime(99, 1, 1));
    for (var m = 1; m <= 12; m++) {
      make('eom 2026,$m', endOfNetWorthMonth(DateTime(2026, m)));
      make('eom 2024,$m', endOfNetWorthMonth(DateTime(2024, m)));
      make('eod 2026,$m,1', endOfNetWorthDay(DateTime(2026, m, 1)));
    }
    make('eod 2026,3,8', endOfNetWorthDay(DateTime(2026, 3, 8)));
    make('eod 2026,11,1', endOfNetWorthDay(DateTime(2026, 11, 1)));
    make('eod 2026,9,5', endOfNetWorthDay(DateTime(2026, 9, 5)));
    make('eod 2026,9,6', endOfNetWorthDay(DateTime(2026, 9, 6)));
    make('eod 2026,4,4', endOfNetWorthDay(DateTime(2026, 4, 4)));
    make('eod 2026,3,28', endOfNetWorthDay(DateTime(2026, 3, 28)));
    make('eod 2026,3,29', endOfNetWorthDay(DateTime(2026, 3, 29)));
    make('eod 2026,10,24', endOfNetWorthDay(DateTime(2026, 10, 24)));

    final arithmetic = <Map<String, Object?>>[];
    for (final start in [
      DateTime(2026, 3, 1),
      DateTime(2026, 3, 8),
      DateTime(2026, 3, 7, 23, 30),
      DateTime(2026, 10, 25),
      DateTime(2026, 11, 1),
      DateTime(2026, 3, 29),
      DateTime(2026, 10, 4),
      DateTime(2026, 4, 5),
      DateTime(2026, 9, 5),
      DateTime(2026, 9, 5, 23, 59, 59, 999),
      DateTime(2026, 9, 6),
      DateTime(2026, 9, 6, 0, 30),
      DateTime(2026, 4, 3, 23, 30),
      DateTime(2026, 4, 4),
      DateTime(2026, 4, 4, 23, 30),
      DateTime(2026, 3, 28, 23, 30),
      DateTime(2026, 10, 24, 23, 30),
      DateTime(2026, 10, 17, 23, 30),
      DateTime(2026, 6, 1, 14, 32, 11, 123, 456),
    ]) {
      for (final days in [-90, -1, 1, 7, 14, 90]) {
        final added = start.add(Duration(days: days));
        arithmetic.add({
          'start': dt(start),
          'days': days,
          'added': dt(added),
          'differenceInDays': added.difference(start).inDays,
          'sameDay': isSameDay(added, start),
        });
      }
    }
    final inDays = <Map<String, Object?>>[];
    for (final (a, b) in [
      (DateTime(2026, 3, 15), DateTime(2026, 3, 1)),
      (DateTime(2026, 11, 15), DateTime(2026, 11, 1)),
      (DateTime(2026, 3, 31), DateTime(2026, 3, 8)),
      (DateTime(2026, 4, 30), DateTime(2026, 4, 1)),
      (DateTime(2026, 10, 10), DateTime(2026, 9, 26)),
      (DateTime(2026, 4, 12), DateTime(2026, 3, 29)),
      (DateTime(2026, 1, 1), DateTime(2026, 1, 2)),
      // Across the midnight gaps and folds (23h and 25h days).
      (DateTime(2026, 9, 7), DateTime(2026, 9, 5)),
      (DateTime(2026, 9, 6, 1), DateTime(2026, 9, 5, 23, 59)),
      (DateTime(2026, 9, 10), DateTime(2026, 9, 1)),
      (DateTime(2026, 9, 6), DateTime(2026, 9, 5)),
      (DateTime(2026, 9, 7), DateTime(2026, 9, 6)),
      (DateTime(2026, 4, 5), DateTime(2026, 4, 4)),
      (DateTime(2026, 4, 6), DateTime(2026, 4, 3)),
      (DateTime(2026, 4, 5, 0, 30), DateTime(2026, 4, 4, 23, 30)),
      (DateTime(2026, 3, 30), DateTime(2026, 3, 28)),
      (DateTime(2026, 3, 29, 1), DateTime(2026, 3, 28, 23, 59)),
      (DateTime(2026, 10, 26), DateTime(2026, 10, 24)),
      (DateTime(2026, 10, 25), DateTime(2026, 10, 24)),
      (DateTime(2026, 10, 25, 0, 30), DateTime(2026, 10, 24, 23, 30)),
    ]) {
      inDays.add({'a': dt(a), 'b': dt(b), 'inDays': a.difference(b).inDays});
    }

    final keys = [
      for (final d in [
        DateTime(2026, 3, 5, 14),
        DateTime(2026, 12, 31, 23, 59),
        DateTime(2027, 1, 1),
        DateTime(99, 7, 4),
        DateTime(2026, 9, 6, 0, 30),
        DateTime(2026, 4, 4, 23, 30),
        DateTime(2026, 3, 29, 0, 30),
        DateTime(2026, 10, 24, 23, 30),
      ])
        {
          'date': dt(d),
          'monthKey': netWorthMonthKey(d),
          'dayKey': netWorthDayKey(d),
          'monthFromKey': dt(netWorthMonthFromKey(netWorthMonthKey(d))),
        }
    ];

    writeJson('$fixturesRoot/$zoneDir/dates.json', {
      'tz': parityTz,
      'parse': parses.map(tryParse).toList(),
      'constructed': constructed,
      'arithmetic': arithmetic,
      'inDays': inDays,
      'keys': keys,
    });
  });

  test('recurring generator', () async {
    final cases = <Map<String, Object?>>[];
    // The midnight-DST cases (below) also carry epoch microseconds, because
    // a fold-hour wall time names two instants.
    var withUs = false;
    Future<void> run(String label, RecurringTransaction template,
        List<DateTime> nows) async {
      for (final now in nows) {
        SharedPreferences.setMockInitialValues({});
        await AtomicFinancialStore.instance.resetForTesting();
        final transactions = TransactionModel();
        final recurring = RecurringTransactionModel();
        await recurring.addRecurringTransaction(template);
        pinClock(now);
        await TransactionGenerator(
          transactionModel: transactions,
          recurringModel: recurring,
        ).generateDueTransactions();
        final after = recurring.recurringTransactions.single;
        cases.add({
          'label': label,
          'template': template.toJson(),
          'now': dt(now),
          'generated': transactions.transactions
              .map((t) => {
                    'date': t.date.toIso8601String(),
                    if (withUs) 'dateUs': t.date.microsecondsSinceEpoch,
                    'recurringTemplateId': t.recurringTemplateId,
                    'createdAt': t.createdAt.toIso8601String(),
                    'amount': t.amount,
                    'type': t.type.name,
                  })
              .toList(),
          'nextOccurrence': after.nextOccurrence.toIso8601String(),
          if (withUs) 'nextOccurrenceUs': after.nextOccurrence.microsecondsSinceEpoch,
          'isActive': after.isActive,
        });
        pinClock(DateTime(2026, 1, 1, 12));
      }
    }

    RecurringTransaction t(String id, RecurrencePattern pattern, DateTime start,
            {int? dom, bool active = true, DateTime? next}) =>
        RecurringTransaction(
          id: id,
          type: TransactionTyp.expense,
          description: id,
          amount: 10.0,
          category: 'General',
          pattern: pattern,
          startDate: start,
          nextOccurrence: next,
          dayOfMonth: dom,
          dayOfWeek: pattern == RecurrencePattern.monthly ? null : start.weekday,
          isActive: active,
        );

    final nows = [
      DateTime(2026, 3, 20, 0, 30),
      DateTime(2026, 4, 10, 10, 30),
      DateTime(2026, 6, 15, 10, 30),
      DateTime(2026, 11, 30, 12),
      DateTime(2027, 1, 5, 23, 59, 59, 999, 999),
    ];
    await run('weekly midnight Sunday before spring DST', t('w1', RecurrencePattern.weekly, DateTime(2026, 2, 22)), nows);
    await run('weekly midnight before fall DST', t('w2', RecurrencePattern.weekly, DateTime(2026, 10, 18)), nows);
    await run('weekly with time of day', t('w3', RecurrencePattern.weekly, DateTime(2026, 6, 1, 14, 32, 11, 123, 456)), nows);
    await run('biweekly Monday', t('b1', RecurrencePattern.biweekly, DateTime(2026, 2, 23)), nows);
    await run('monthly dom 31 from Jan 31', t('m31', RecurrencePattern.monthly, DateTime(2026, 1, 31), dom: 31), nows);
    await run('monthly dom 30', t('m30', RecurrencePattern.monthly, DateTime(2026, 1, 30), dom: 30), nows);
    await run('monthly start 15 dom 31', t('m15', RecurrencePattern.monthly, DateTime(2026, 1, 15), dom: 31), nows);
    await run('monthly start with time', t('mt', RecurrencePattern.monthly, DateTime(2026, 1, 31, 14, 32, 11, 123), dom: 31), nows);
    await run('monthly leap dom 29', t('m29', RecurrencePattern.monthly, DateTime(2024, 1, 29), dom: 29, next: DateTime(2026, 1, 29)), nows);
    await run('monthly year boundary', t('my', RecurrencePattern.monthly, DateTime(2026, 12, 15), dom: 15), nows);
    await run('inactive', t('off', RecurrencePattern.weekly, DateTime(2026, 1, 1), active: false), nows);
    await run('far past start (lookback cap)', t('old', RecurrencePattern.weekly, DateTime(2025, 1, 6)), nows);
    await run('future start', t('fut', RecurrencePattern.monthly, DateTime(2027, 3, 1), dom: 1), nows);
    // Lookback boundary: maxLookback = now - 90*24h.
    final boundaryNow = DateTime(2026, 6, 15, 10, 30);
    for (final (i, offset) in [
      const Duration(days: 90, minutes: 1),
      const Duration(days: 90),
      const Duration(days: 89, hours: 23, minutes: 59),
      const Duration(days: 90, hours: 10, minutes: 30),
      const Duration(days: 90, hours: 10, minutes: 31),
    ].indexed) {
      final start = boundaryNow.subtract(offset);
      await run('lookback boundary $i', t('lb$i', RecurrencePattern.monthly, start, dom: start.day), [boundaryNow]);
    }
    await run('due later today', t('today', RecurrencePattern.monthly, DateTime(2026, 6, 15, 23), dom: 15), [DateTime(2026, 6, 15, 10, 30)]);

    writeJson('$fixturesRoot/$zoneDir/generator.json', {'tz': parityTz, 'cases': cases});

    // Midnight DST. Every template and clock is built from local components,
    // so each zone resolves them itself: America/Santiago (gap 2026-09-06
    // 00:00-00:59, fold 2026-04-04 23:00-23:59), Asia/Beirut (gap 2026-03-29
    // 00:00-00:59, fold 2026-10-24 23:00-23:59); everywhere else they are
    // ordinary times.
    withUs = true;
    cases.clear();
    final sclGapNows = [
      DateTime(2026, 9, 5, 23, 59, 59, 999),
      DateTime(2026, 9, 6, 0, 30),
      DateTime(2026, 9, 6, 1),
      DateTime(2026, 9, 6, 12),
      DateTime(2026, 9, 13, 0, 30),
      DateTime(2026, 9, 28, 9, 15),
    ];
    final sclFoldNows = [
      DateTime(2026, 4, 4, 22, 59),
      DateTime(2026, 4, 4, 23),
      DateTime(2026, 4, 4, 23, 30),
      DateTime(2026, 4, 5),
      DateTime(2026, 4, 11, 22, 30),
      DateTime(2026, 4, 11, 23, 30),
    ];
    final beiGapNows = [
      DateTime(2026, 3, 28, 23, 59, 59, 999),
      DateTime(2026, 3, 29, 0, 30),
      DateTime(2026, 3, 29, 1),
      DateTime(2026, 3, 29, 12),
      DateTime(2026, 4, 5, 0, 30),
      DateTime(2026, 4, 20, 9, 15),
    ];
    final beiFoldNows = [
      DateTime(2026, 10, 24, 22, 59),
      DateTime(2026, 10, 24, 23),
      DateTime(2026, 10, 24, 23, 30),
      DateTime(2026, 10, 25),
      DateTime(2026, 10, 31, 22, 30),
      DateTime(2026, 10, 31, 23, 30),
    ];
    // The same wall time twice: every instant of the fold hour a clock can name.
    List<DateTime> bothOf(DateTime wall) => [
          for (final d in [
            wall.subtract(const Duration(hours: 1)),
            wall,
            wall.add(const Duration(hours: 1)),
          ])
            if (d.year == wall.year &&
                d.month == wall.month &&
                d.day == wall.day &&
                d.hour == wall.hour &&
                d.minute == wall.minute)
              d
        ];
    final sclFoldBoth = bothOf(DateTime(2026, 4, 4, 23, 30));
    final beiFoldBoth = bothOf(DateTime(2026, 10, 24, 23, 30));
    await run('dst weekly across the spring gap (Sunday start)', t('dw1', RecurrencePattern.weekly, DateTime(2026, 8, 30)), sclGapNows);
    await run('dst biweekly across the spring gap', t('dw2', RecurrencePattern.biweekly, DateTime(2026, 8, 23)), sclGapNows);
    await run('dst weekly starting on the gap day', t('dw3', RecurrencePattern.weekly, DateTime(2026, 9, 6)), sclGapNows);
    await run('dst weekly starting 00:30 on the gap day', t('dw4', RecurrencePattern.weekly, DateTime(2026, 9, 6, 0, 30)), sclGapNows);
    await run('dst monthly dom 6 through the gap', t('dm1', RecurrencePattern.monthly, DateTime(2026, 7, 6), dom: 6), sclGapNows);
    await run('dst monthly dom 6 cursor on the gap', t('dm2', RecurrencePattern.monthly, DateTime(2026, 7, 6), dom: 6, next: DateTime(2026, 9, 6)), sclGapNows);
    await run('dst weekly day before gap with time', t('dw5', RecurrencePattern.weekly, DateTime(2026, 8, 30, 23, 30)), sclGapNows);
    await run('dst weekly across the fall fold', t('df1', RecurrencePattern.weekly, DateTime(2026, 3, 28, 23, 30)), sclFoldNows);
    await run('dst weekly midnight across the fold day', t('df2', RecurrencePattern.weekly, DateTime(2026, 3, 28)), sclFoldNows);
    await run('dst biweekly across the fold', t('df3', RecurrencePattern.biweekly, DateTime(2026, 3, 21, 23, 30)), sclFoldNows);
    await run('dst monthly dom 4 with fold time', t('df4', RecurrencePattern.monthly, DateTime(2026, 1, 4, 23, 30), dom: 4), sclFoldNows);
    await run('dst weekly cursor in the fold hour', t('df5', RecurrencePattern.weekly, DateTime(2026, 3, 28, 23, 30), next: DateTime(2026, 4, 4, 23, 30)), sclFoldNows);
    await run('dst weekly fold hour, clock at either 23:30', t('df6', RecurrencePattern.weekly, DateTime(2026, 3, 28, 23, 30)), sclFoldBoth);
    await run('dst weekly across the Beirut spring gap', t('bw1', RecurrencePattern.weekly, DateTime(2026, 3, 22)), beiGapNows);
    await run('dst biweekly across the Beirut gap', t('bw2', RecurrencePattern.biweekly, DateTime(2026, 3, 15)), beiGapNows);
    await run('dst monthly dom 29 through the Beirut gap', t('bm1', RecurrencePattern.monthly, DateTime(2026, 1, 29), dom: 29), beiGapNows);
    await run('dst weekly starting on the Beirut gap day', t('bw3', RecurrencePattern.weekly, DateTime(2026, 3, 29, 0, 30)), beiGapNows);
    await run('dst weekly across the Beirut fold', t('bf1', RecurrencePattern.weekly, DateTime(2026, 10, 17, 23, 30)), beiFoldNows);
    await run('dst monthly dom 24 with fold time', t('bf2', RecurrencePattern.monthly, DateTime(2026, 8, 24, 23, 30), dom: 24), beiFoldNows);
    await run('dst weekly Beirut fold hour, clock at either 23:30', t('bf3', RecurrencePattern.weekly, DateTime(2026, 10, 17, 23, 30)), beiFoldBoth);
    await run('dst weekly midnight across Beirut fold day', t('bf4', RecurrencePattern.weekly, DateTime(2026, 10, 17)), beiFoldNows);
    writeJson('$fixturesRoot/$zoneDir/generator_dst.json', {'tz': parityTz, 'cases': List.of(cases)});
    cases.clear();
    withUs = false;
  });

  test('safe to spend', () async {
    final results = <Map<String, Object?>>[];
    final transactions = [
      Transaction(id: 's1', type: TransactionTyp.income, description: 'Pay', amount: 3000.0, category: 'Salary', date: DateTime(2026, 3, 1)),
      Transaction(id: 's2', type: TransactionTyp.expense, description: 'Midnight today', amount: 10.0, category: 'Groceries', date: DateTime(2026, 3, 8)),
      Transaction(id: 's3', type: TransactionTyp.expense, description: 'Today 09:00', amount: 20.0, category: 'Groceries', date: DateTime(2026, 3, 8, 9)),
      Transaction(id: 's4', type: TransactionTyp.expense, description: 'Yesterday late', amount: 40.0, category: 'Eating Out', date: DateTime(2026, 3, 7, 23, 59)),
      Transaction(id: 's5', type: TransactionTyp.expense, description: 'Future', amount: 99.0, category: 'Groceries', date: DateTime(2026, 3, 25)),
      Transaction(id: 's6', type: TransactionTyp.expense, description: 'Last day noon', amount: 7.0, category: 'Groceries', date: DateTime(2026, 2, 28, 12)),
      Transaction(id: 's7', type: TransactionTyp.expense, description: 'Nov', amount: 0.1, category: 'Groceries', date: DateTime(2026, 11, 2)),
      Transaction(id: 's8', type: TransactionTyp.expense, description: 'Nov', amount: 0.2, category: 'Groceries', date: DateTime(2026, 11, 2)),
    ];
    final recurring = [
      RecurringTransaction(id: 'r1', type: TransactionTyp.expense, description: 'Gym', amount: 45.0, category: 'Health', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 2, 22), dayOfWeek: 7),
      RecurringTransaction(id: 'r2', type: TransactionTyp.income, description: 'Pay', amount: 1850.0, category: 'Salary', pattern: RecurrencePattern.biweekly, startDate: DateTime(2026, 2, 23), dayOfWeek: 1),
      RecurringTransaction(id: 'r3', type: TransactionTyp.expense, description: 'Rent', amount: 1500.0, category: 'Housing', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 1, 31), dayOfMonth: 31),
      RecurringTransaction(id: 'r4', type: TransactionTyp.expense, description: 'Groceries sub', amount: 60.0, category: 'Groceries', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 1, 20), dayOfMonth: 20),
      RecurringTransaction(id: 'r5', type: TransactionTyp.expense, description: 'Off', amount: 5.0, category: 'General', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 1, 20), dayOfMonth: 20, isActive: false),
      RecurringTransaction(id: 'r6', type: TransactionTyp.expense, description: 'With time', amount: 11.0, category: 'General', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 3, 1, 1, 30), dayOfWeek: 7),
    ];
    final limits = <String, double>{'Groceries': 400.0, 'Eating Out': 30.0, 'Stale Cat': 50.0, 'Health': 100.0};
    pinClock(DateTime(2026, 3, 8, 10, 30));
    final goals = [
      SavingsGoal(id: 'g1', name: 'Trip', targetAmount: 3000.0, currentAmount: 500.0, targetDate: DateTime(2026, 12, 20), createdAt: DateTime(2026, 1, 1)),
      SavingsGoal(id: 'g2', name: 'Done', targetAmount: 100.0, currentAmount: 100.0, targetDate: DateTime(2026, 12, 20), createdAt: DateTime(2026, 1, 1)),
      SavingsGoal(id: 'g3', name: 'Overdue', targetAmount: 800.0, currentAmount: 200.0, targetDate: DateTime(2026, 1, 1), createdAt: DateTime(2025, 1, 1)),
    ];
    for (final (month, asOf) in [
      (DateTime(2026, 3), DateTime(2026, 3, 8, 10, 30)),
      (DateTime(2026, 3), DateTime(2026, 3, 1)),
      (DateTime(2026, 3), DateTime(2026, 3, 31, 23, 59)),
      (DateTime(2026, 2), DateTime(2026, 3, 8, 10, 30)),
      (DateTime(2026, 4), DateTime(2026, 3, 8, 10, 30)),
      (DateTime(2026, 11), DateTime(2026, 11, 1, 8)),
      (DateTime(2026, 11), DateTime(2026, 11, 2, 0, 0)),
      (DateTime(2026, 10), DateTime(2026, 10, 4, 12)),
    ]) {
      pinClock(asOf);
      final b = const SafeToSpendCalculator().calculate(
        transactions: transactions,
        recurringTransactions: recurring,
        categoryBudgetLimits: limits,
        savingsGoals: goals,
        month: month,
        asOf: asOf,
      );
      results.add(breakdownJson(b));
      pinClock(DateTime(2026, 1, 1, 12));
    }
    writeJson('$fixturesRoot/$zoneDir/safe_to_spend.json', {
      'tz': parityTz,
      'transactions': transactions.map((t) => t.toJson()).toList(),
      'recurring': recurring.map((r) => r.toJson()).toList(),
      'limits': limits,
      'goals': goals.map((g) => g.toJson()).toList(),
      'goalClockNote': 'suggestedMonthlyContribution uses the clock; the clock was pinned to asOf for each result',
      'results': results,
    });

    // Midnight DST (America/Santiago, Asia/Beirut; ordinary times elsewhere):
    // rows, templates and as-of clocks on, just before and just after each
    // gap and fold. Each date carries epoch microseconds (a fold-hour wall
    // time names two instants); the fold cases run at both.
    final dstTransactions = [
      Transaction(id: 'd1', type: TransactionTyp.income, description: 'Pay', amount: 3000.0, category: 'Salary', date: DateTime(2026, 9, 1)),
      Transaction(id: 'd2', type: TransactionTyp.expense, description: 'Before gap', amount: 11.0, category: 'Groceries', date: DateTime(2026, 9, 5, 23, 59, 59, 999)),
      Transaction(id: 'd3', type: TransactionTyp.expense, description: 'Gap midnight', amount: 12.0, category: 'Groceries', date: DateTime(2026, 9, 6)),
      Transaction(id: 'd4', type: TransactionTyp.expense, description: 'Gap 00:30', amount: 13.0, category: 'Eating Out', date: DateTime(2026, 9, 6, 0, 30)),
      Transaction(id: 'd5', type: TransactionTyp.expense, description: 'After gap', amount: 14.0, category: 'Groceries', date: DateTime(2026, 9, 6, 1)),
      Transaction(id: 'd6', type: TransactionTyp.expense, description: 'Fold 23:15', amount: 21.0, category: 'Groceries', date: DateTime(2026, 4, 4, 23, 15)),
      Transaction(id: 'd7', type: TransactionTyp.expense, description: 'Fold 23:30', amount: 22.0, category: 'Groceries', date: DateTime(2026, 4, 4, 23, 30)),
      Transaction(id: 'd8', type: TransactionTyp.expense, description: 'Fold 23:45', amount: 23.0, category: 'Eating Out', date: DateTime(2026, 4, 4, 23, 45)),
      Transaction(id: 'd9', type: TransactionTyp.expense, description: 'After fold', amount: 24.0, category: 'Groceries', date: DateTime(2026, 4, 5)),
      Transaction(id: 'd10', type: TransactionTyp.income, description: 'Fold pay', amount: 500.0, category: 'Salary', date: DateTime(2026, 4, 4, 23, 30)),
      Transaction(id: 'd11', type: TransactionTyp.expense, description: 'Beirut gap 00:30', amount: 31.0, category: 'Groceries', date: DateTime(2026, 3, 29, 0, 30)),
      Transaction(id: 'd12', type: TransactionTyp.expense, description: 'Beirut before gap', amount: 32.0, category: 'Groceries', date: DateTime(2026, 3, 28, 23, 59, 59, 999)),
      Transaction(id: 'd13', type: TransactionTyp.expense, description: 'Beirut fold 23:15', amount: 41.0, category: 'Groceries', date: DateTime(2026, 10, 24, 23, 15)),
      Transaction(id: 'd14', type: TransactionTyp.expense, description: 'Beirut fold 23:45', amount: 42.0, category: 'Eating Out', date: DateTime(2026, 10, 24, 23, 45)),
      Transaction(id: 'd15', type: TransactionTyp.expense, description: 'Beirut after fold', amount: 43.0, category: 'Groceries', date: DateTime(2026, 10, 25)),
    ];
    final dstRecurring = [
      RecurringTransaction(id: 'dr1', type: TransactionTyp.expense, description: 'Weekly over gap', amount: 45.0, category: 'Health', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 8, 30), dayOfWeek: 7),
      RecurringTransaction(id: 'dr2', type: TransactionTyp.income, description: 'Biweekly over gap', amount: 850.0, category: 'Salary', pattern: RecurrencePattern.biweekly, startDate: DateTime(2026, 8, 23), dayOfWeek: 7),
      RecurringTransaction(id: 'dr3', type: TransactionTyp.expense, description: 'Monthly dom 6', amount: 60.0, category: 'Housing', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 7, 6), dayOfMonth: 6),
      RecurringTransaction(id: 'dr4', type: TransactionTyp.expense, description: 'Weekly fold time', amount: 15.0, category: 'Groceries', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 3, 28, 23, 30), dayOfWeek: 6),
      RecurringTransaction(id: 'dr5', type: TransactionTyp.expense, description: 'Weekly over Beirut gap', amount: 25.0, category: 'Health', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 3, 22), dayOfWeek: 7),
      RecurringTransaction(id: 'dr6', type: TransactionTyp.expense, description: 'Monthly dom 29', amount: 70.0, category: 'Housing', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 1, 29), dayOfMonth: 29),
      RecurringTransaction(id: 'dr7', type: TransactionTyp.expense, description: 'Weekly Beirut fold time', amount: 16.0, category: 'Groceries', pattern: RecurrencePattern.weekly, startDate: DateTime(2026, 10, 17, 23, 30), dayOfWeek: 6),
      RecurringTransaction(id: 'dr8', type: TransactionTyp.income, description: 'Cursor on gap', amount: 100.0, category: 'Salary', pattern: RecurrencePattern.monthly, startDate: DateTime(2026, 7, 6), dayOfMonth: 6, nextOccurrence: DateTime(2026, 9, 6)),
    ];
    final dstLimits = <String, double>{'Groceries': 300.0, 'Eating Out': 80.0, 'Health': 100.0};
    final dstGoals = [
      SavingsGoal(id: 'dg1', name: 'Gap goal', targetAmount: 1000.0, currentAmount: 100.0, targetDate: DateTime(2026, 9, 6), createdAt: DateTime(2026, 4, 4, 23, 30)),
      SavingsGoal(id: 'dg2', name: 'Later', targetAmount: 2000.0, currentAmount: 300.0, targetDate: DateTime(2026, 12, 6), createdAt: DateTime(2026, 3, 29, 0, 30)),
    ];
    final dstCases = <Map<String, Object?>>[];
    void dstCase(DateTime month, DateTime asOf) {
      pinClock(asOf);
      final b = const SafeToSpendCalculator().calculate(
        transactions: dstTransactions,
        recurringTransactions: dstRecurring,
        categoryBudgetLimits: dstLimits,
        savingsGoals: dstGoals,
        month: month,
        asOf: asOf,
      );
      dstCases.add({
        'month': dt(month),
        'asOf': dt(asOf),
        'result': breakdownJson(b),
      });
      pinClock(DateTime(2026, 1, 1, 12));
    }

    // Every instant whose local wall time is the given one (two in a fold).
    List<DateTime> sameWall(int y, int m, int d, int h, int mi) {
      final wall = DateTime(y, m, d, h, mi);
      return [
        for (final x in [
          wall.subtract(const Duration(hours: 1)),
          wall,
          wall.add(const Duration(hours: 1)),
        ])
          if (x.year == y && x.month == m && x.day == d && x.hour == h && x.minute == mi) x
      ];
    }

    for (final asOf in [
      DateTime(2026, 9, 5, 23, 59, 59, 999),
      DateTime(2026, 9, 6),
      DateTime(2026, 9, 6, 0, 30),
      DateTime(2026, 9, 6, 1),
      DateTime(2026, 9, 6, 12),
      DateTime(2026, 9, 7),
      DateTime(2026, 9, 30, 23, 59),
      DateTime(2026, 10, 1),
    ]) {
      dstCase(DateTime(2026, 9), asOf);
    }
    for (final asOf in [
      DateTime(2026, 4, 4, 22, 59),
      DateTime(2026, 4, 4, 23),
      ...sameWall(2026, 4, 4, 23, 15),
      ...sameWall(2026, 4, 4, 23, 30),
      ...sameWall(2026, 4, 4, 23, 45),
      DateTime(2026, 4, 4, 23, 59, 59, 999),
      DateTime(2026, 4, 5),
      DateTime(2026, 4, 30, 12),
    ]) {
      dstCase(DateTime(2026, 4), asOf);
    }
    for (final asOf in [
      DateTime(2026, 3, 28, 23, 59),
      DateTime(2026, 3, 29),
      DateTime(2026, 3, 29, 0, 30),
      DateTime(2026, 3, 29, 1),
      DateTime(2026, 3, 31, 23, 59),
    ]) {
      dstCase(DateTime(2026, 3), asOf);
    }
    for (final asOf in [
      DateTime(2026, 10, 24, 22, 59),
      ...sameWall(2026, 10, 24, 23, 15),
      ...sameWall(2026, 10, 24, 23, 30),
      ...sameWall(2026, 10, 24, 23, 45),
      DateTime(2026, 10, 25),
      DateTime(2026, 10, 31, 23, 59),
    ]) {
      dstCase(DateTime(2026, 10), asOf);
    }
    // A month that is not the as-of month (closed past, open future).
    dstCase(DateTime(2026, 9), DateTime(2026, 10, 24, 23, 30));
    dstCase(DateTime(2026, 4), DateTime(2026, 3, 29, 0, 30));

    // Randomised cases whose dates sit on the transition days.
    final dstRandom = Random(909090 + parityTz.codeUnits.fold(0, (a, b) => a + b));
    const dstDays = [(2026, 9, 6), (2026, 4, 4), (2026, 3, 29), (2026, 10, 24), (2026, 10, 25), (2026, 9, 5), (2026, 4, 5), (2026, 3, 28)];
    DateTime dstTime() {
      final (y, m, d) = dstDays[dstRandom.nextInt(dstDays.length)];
      final hour = const [0, 0, 1, 23, 23, 22, 12][dstRandom.nextInt(7)];
      return DateTime(y, m, d, hour, dstRandom.nextInt(60), dstRandom.nextInt(3) == 0 ? 59 : 0,
          dstRandom.nextInt(3) == 0 ? 999 : 0);
    }

    double dstMoney() => (dstRandom.nextInt(20000) + 1) / 100.0;
    final dstRandomCases = <Map<String, Object?>>[];
    for (var i = 0; i < 120; i++) {
      final asOf = dstTime();
      final month = DateTime(asOf.year, asOf.month);
      final transactions = [
        for (var n = 0; n < dstRandom.nextInt(12) + 2; n++)
          Transaction(
            id: 'x$i-t$n',
            type: dstRandom.nextInt(3) == 0 ? TransactionTyp.income : TransactionTyp.expense,
            description: 'x',
            amount: dstMoney(),
            category: const ['Groceries', 'Eating Out', 'Health'][dstRandom.nextInt(3)],
            date: dstTime(),
            createdAt: DateTime(2024),
            updatedAt: DateTime(2024),
          ),
      ];
      final recurring = <RecurringTransaction>[];
      for (var r = 0; r < dstRandom.nextInt(4); r++) {
        final pattern = RecurrencePattern.values[dstRandom.nextInt(3)];
        final start = dstTime();
        recurring.add(RecurringTransaction(
          id: 'x$i-rt$r',
          type: dstRandom.nextInt(3) == 0 ? TransactionTyp.income : TransactionTyp.expense,
          description: 'rt',
          amount: dstMoney(),
          category: 'Groceries',
          pattern: pattern,
          startDate: start,
          nextOccurrence: dstTime(),
          dayOfMonth: pattern == RecurrencePattern.monthly ? dstRandom.nextInt(31) + 1 : null,
          dayOfWeek: pattern == RecurrencePattern.monthly ? null : start.weekday,
          isActive: dstRandom.nextInt(5) != 0,
        ));
      }
      final limits = <String, double>{
        if (dstRandom.nextBool()) 'Groceries': dstMoney(),
        if (dstRandom.nextBool()) 'Eating Out': dstMoney(),
      };
      pinClock(asOf);
      final goals = [
        for (var g = 0; g < dstRandom.nextInt(3); g++)
          SavingsGoal(
            id: 'x$i-g$g',
            name: 'g',
            targetAmount: 1000.0 + dstMoney(),
            currentAmount: dstMoney(),
            targetDate: dstTime(),
            createdAt: dstTime(),
          ),
      ];
      final b = const SafeToSpendCalculator().calculate(
        transactions: transactions,
        recurringTransactions: recurring,
        categoryBudgetLimits: limits,
        savingsGoals: goals,
        month: month,
        asOf: asOf,
      );
      dstRandomCases.add({
        'month': dt(month),
        'asOf': dt(asOf),
        'transactions': transactions.map((t) => t.toJson()).toList(),
        'recurring': recurring.map((r) => r.toJson()).toList(),
        'limits': limits,
        'goals': goals.map((g) => g.toJson()).toList(),
        'result': breakdownJson(b),
      });
      pinClock(DateTime(2026, 1, 1, 12));
    }
    writeJson('$fixturesRoot/$zoneDir/safe_to_spend_dst.json', {
      'tz': parityTz,
      'transactions': dstTransactions.map((t) => t.toJson()).toList(),
      'recurring': dstRecurring.map((r) => r.toJson()).toList(),
      'limits': dstLimits,
      'goals': dstGoals.map((g) => g.toJson()).toList(),
      'goalClockNote': 'suggestedMonthlyContribution uses the clock; the clock was pinned to asOf for each result',
      'results': dstCases,
      'randomCases': dstRandomCases,
    });
  });

  test('safe to spend, randomized differential corpus', () async {
    final random = Random(424242 + parityTz.codeUnits.fold(0, (a, b) => a + b));
    const categories = ['Groceries', 'Eating Out', 'Housing', 'Health', 'Travel'];
    DateTime randomTime(DateTime month) {
      final day = random.nextInt(34) - 2; // spills into neighbour months
      final kind = random.nextInt(4);
      if (kind == 0) return DateTime(month.year, month.month, day);
      return DateTime(month.year, month.month, day, random.nextInt(24),
          random.nextInt(60), random.nextInt(60), random.nextInt(1000), random.nextInt(1000));
    }

    double money() => (random.nextInt(200000) + 1) / 100.0;
    final cases = <Map<String, Object?>>[];
    for (var i = 0; i < 400; i++) {
      final month = DateTime(2024 + random.nextInt(4), random.nextInt(12) + 1);
      final transactions = [
        for (var t = 0; t < random.nextInt(25); t++)
          Transaction(
            id: 'r$i-t$t',
            type: random.nextInt(3) == 0 ? TransactionTyp.income : TransactionTyp.expense,
            description: 'x',
            amount: money(),
            category: categories[random.nextInt(categories.length)],
            date: randomTime(month),
            createdAt: DateTime(2024),
            updatedAt: DateTime(2024),
          ),
      ];
      final recurring = <RecurringTransaction>[];
      for (var r = 0; r < random.nextInt(5); r++) {
        final pattern = RecurrencePattern.values[random.nextInt(3)];
        final start = randomTime(DateTime(month.year, month.month - random.nextInt(3)));
        recurring.add(RecurringTransaction(
          id: 'r$i-rt$r',
          type: random.nextInt(3) == 0 ? TransactionTyp.income : TransactionTyp.expense,
          description: 'rt',
          amount: money(),
          category: categories[random.nextInt(categories.length)],
          pattern: pattern,
          startDate: start,
          nextOccurrence: randomTime(month),
          dayOfMonth: pattern == RecurrencePattern.monthly
              ? (random.nextInt(5) == 0 ? null : random.nextInt(31) + 1)
              : null,
          dayOfWeek: pattern == RecurrencePattern.monthly ? null : start.weekday,
          isActive: random.nextInt(5) != 0,
        ));
      }
      final limits = <String, double>{
        for (final c in categories)
          if (random.nextBool()) c: random.nextInt(4) == 0 ? 0.0 : money(),
      };
      final asOfMonth = DateTime(month.year, month.month + random.nextInt(3) - 1);
      final asOf = randomTime(asOfMonth);
      pinClock(asOf);
      final goals = [
        for (var g = 0; g < random.nextInt(3); g++)
          SavingsGoal(
            id: 'r$i-g$g',
            name: 'g',
            targetAmount: money() * 10,
            currentAmount: money() * random.nextInt(12),
            targetDate: DateTime(asOf.year, asOf.month + random.nextInt(30) - 6, random.nextInt(28) + 1),
            createdAt: DateTime(2023),
          ),
      ];
      final b = const SafeToSpendCalculator().calculate(
        transactions: transactions,
        recurringTransactions: recurring,
        categoryBudgetLimits: limits,
        savingsGoals: goals,
        month: month,
        asOf: asOf,
      );
      cases.add({
        'month': month.toIso8601String(),
        'asOf': asOf.toIso8601String(),
        'transactions': transactions.map((t) => t.toJson()).toList(),
        'recurring': recurring.map((r) => r.toJson()).toList(),
        'limits': limits,
        'goals': goals.map((g) => g.toJson()).toList(),
        'result': breakdownJson(b),
      });
      pinClock(DateTime(2026, 1, 1, 12));
    }
    writeJson('$fixturesRoot/$zoneDir/safe_to_spend_random.json', {'tz': parityTz, 'cases': cases});
  });

  test('csv export', () async {
    if (!writeZoneIndependent) return;
    final temp = await Directory.systemTemp.createTemp('parity_csv');
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    final share = FakeShare();
    SharePlatform.instance = share;
    final model = TransactionModel();
    final rows = <Transaction>[
      for (final (i, (desc, cat, amount, date)) in [
        ('Salary, bonus', 'Salary', 4200.0, DateTime(2026, 1, 1)),
        ('Book "Dart"', 'General', 39.99, DateTime(2026, 1, 3, 12)),
        ('line1\nline2', 'General', 1.0, DateTime(2026, 1, 3, 12)),
        ('carriage\rreturn', 'General', 0.015, DateTime(2026, 1, 4)),
        ('=SUM(A1)', 'General', 0.995, DateTime(2026, 1, 5)),
        ('  padded ', ' Cat ', 1.005, DateTime(2026, 1, 6)),
        ('tab\there', 'General', 2.675, DateTime(2026, 1, 7)),
        ('', 'General', 0.125, DateTime(2026, 1, 8)),
        ('Café ☕️ 😀', 'Eating Out', 1234567.891, DateTime(2026, 1, 9)),
        ('negative', 'General', -12.5, DateTime(2026, 1, 10)),
        ('tiny negative', 'General', -0.001, DateTime(2026, 1, 11)),
        ('huge', 'General', 1e21, DateTime(2026, 1, 12)),
        ('big', 'General', 123456789012.345, DateTime(2026, 1, 13)),
        ('leap', 'General', 29.0, DateTime(2024, 2, 29, 23, 59, 59, 999, 999)),
        ('same instant a', 'General', 1.0, DateTime(2026, 1, 3, 12)),
      ].indexed)
        Transaction(
          id: 'csv-$i',
          type: i == 0 ? TransactionTyp.income : TransactionTyp.expense,
          description: desc,
          amount: amount,
          category: cat,
          date: date,
        ),
    ];
    model.transactions = rows;
    pinClock(DateTime(2026, 2, 3, 4, 5, 6));
    await model.exportTransactionsToCSV(null);
    final path = share.shared.single;
    final bytes = File(path).readAsBytesSync();
    writeJson('$fixturesRoot/logic/csv_export.json', {
      'transactions': rows.map((t) => t.toJson()).toList(),
      'fileName': path.split('/').last,
      'base64': base64Encode(bytes),
      'text': utf8.decode(bytes),
      'emptyLedgerText': await (() async {
        final empty = TransactionModel();
        share.shared.clear();
        await empty.exportTransactionsToCSV(null);
        return File(share.shared.single).readAsStringSync();
      })(),
    });
  });

  test('money formatting', () {
    if (!writeZoneIndependent) return;
    final values = <double>[
      0, -0.0, 0.001, -0.001, 0.005, 0.015, 0.125, 0.995, 1.005, 2.675, 2.5,
      12.5, 999, 999.995, 1234, 1234.5, 1234.56, -1234.56, 1234567, 1500000000,
      0.1 + 0.2, 1e-7, 123456789.12,
    ];
    final currencies = ['USD', 'CAD', 'EUR', 'GBP', 'AUD', 'JPY', 'CNY', 'INR', 'KRW', 'MXN', 'BRL'];
    final locales = <String?>[null, 'en_US', 'en_CA', 'en_GB', 'en_AU', 'de_DE', 'fr_FR', 'es_ES', 'ja_JP'];
    final out = <Map<String, Object?>>[];
    for (final currency in currencies) {
      for (final locale in locales) {
        MoneyFormatter.configure(currencyCode: currency, locale: locale);
        for (final v in values) {
          out.add({
            'currency': currency,
            'locale': locale,
            'value': v,
            'format2': MoneyFormatter.format(v),
            'format0': MoneyFormatter.format(v, decimalDigits: 0),
            'compact1': MoneyFormatter.format(v, decimalDigits: 1, compact: true),
            'signed2': MoneyFormatter.formatSigned(v),
            'signedPlus2': MoneyFormatter.formatSigned(v, plusForPositive: true),
            'number2': MoneyFormatter.formatNumber(v),
          });
        }
      }
    }
    MoneyFormatter.configure(currencyCode: 'USD', hideBalances: true);
    final hidden = {
      'format': MoneyFormatter.format(12.5),
      'signed': MoneyFormatter.formatSigned(-12.5),
    };
    MoneyFormatter.configure(currencyCode: 'USD');
    writeJson('$fixturesRoot/logic/money_format.json', {'vectors': out, 'hidden': hidden});
  });

  test('number encoding', () {
    if (!writeZoneIndependent) return;
    final random = Random(20260928);
    final doubles = <double>[
      0.0, -0.0, 1.0, -1.0, 100.0, 0.1, 0.2, 0.1 + 0.2, 1e-7, 1e-6, 1.234e-6,
      0.00001, 0.000025, 1e20, 1e21, 1.5e300, 5e-324, 2.2250738585072014e-308,
      1.7976931348623157e308, 123456789.12, 123456789012345680000.0,
      9007199254740992.0, 9007199254740993.0, 4.35, 1200.0, 0.015, 2.675,
      1e15, 1e16, 1e17, 123e-20, 0.5, 1 / 3, 2 / 3, 1e100,
    ];
    for (var i = 0; i < 3000; i++) {
      final bits = (random.nextInt(1 << 32) << 32) | random.nextInt(1 << 32);
      final bytes = ByteData(8)..setUint64(0, bits);
      final value = bytes.getFloat64(0);
      if (value.isFinite) doubles.add(value);
    }
    for (var i = 0; i < 2000; i++) {
      // Money-like values: cents over a wide range.
      doubles.add((random.nextInt(100000000) - 50000000) / 100.0);
      doubles.add(random.nextDouble() * pow(10, random.nextInt(30) - 10));
    }
    final ints = <int>[0, 1, -1, 42, 9007199254740993, -9223372036854775808, 9223372036854775807];
    writeJson('$fixturesRoot/logic/numbers.json', {
      'doubles': [
        for (final d in doubles)
          {
            'bits': bitsHex(d),
            'json': jsonEncode(d),
            'toString': d.toString(),
            'fixed2': d.abs() < 1e21 ? d.toStringAsFixed(2) : null,
          }
      ],
      'ints': [for (final i in ints) {'value': i.toString(), 'json': jsonEncode(i)}],
      'strings': [
        for (final s in [
          'plain', 'a/b', 'é', '😀', '\u0000\u0001\u0008\u0009\u000a\u000b\u000c\u000d\u001f\u007f',
          '"quote" and \\ backslash', '  ', '\uD83D', '\uDE00', 'x\uDE00\uD83Dy', '﻿',
        ])
          {'codeUnits': s.codeUnits, 'json': jsonEncode(s)}
      ],
      'decodeReencode': [
        for (final raw in [
          '{"b":1,"a":2,"b":3}', '[1.0,1,1e2,1E2,-0,-0.0,1.5e3,0.1e1]',
          '12345678901234567890', '-9223372036854775809', '"\\u00e9\\/"',
          '{"x":[],"y":{}}', ' { "s" : "t" } ',
        ])
          {'input': raw, 'reencoded': jsonEncode(jsonDecode(raw))}
      ],
    });
  });

  test('ordering', () {
    if (!writeZoneIndependent) return;
    final rows = [
      Transaction(id: 'b', type: TransactionTyp.expense, description: 'x', amount: 1.0, category: 'G', date: DateTime(2026, 3, 1), createdAt: DateTime(2026, 3, 1, 9), updatedAt: DateTime(2026, 3, 1, 9)),
      Transaction(id: 'a', type: TransactionTyp.expense, description: 'x', amount: 1.0, category: 'G', date: DateTime(2026, 3, 1, 23), createdAt: DateTime(2026, 3, 1, 9), updatedAt: DateTime(2026, 3, 1, 9)),
      Transaction(id: 'c', type: TransactionTyp.expense, description: 'x', amount: 1.0, category: 'G', date: DateTime(2026, 2, 28, 23, 30), createdAt: DateTime(2026, 3, 2), updatedAt: DateTime(2026, 3, 2)),
      Transaction(id: 'd', type: TransactionTyp.expense, description: 'x', amount: 1.0, category: 'G', date: DateTime(2026, 3, 1), createdAt: DateTime(2026, 3, 1, 10), updatedAt: DateTime(2026, 3, 1, 10)),
    ];
    final sorted = List.of(rows)..sort(Transaction.compareNewestFirst);
    writeJson('$fixturesRoot/logic/ordering.json', {
      'transactions': rows.map((t) => t.toJson()).toList(),
      'newestFirst': sorted.map((t) => t.id).toList(),
    });
  });
}
