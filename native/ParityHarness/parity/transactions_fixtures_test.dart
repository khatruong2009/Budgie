// Emits native/Fixtures/transactions/tz/<zone>/ : the transaction ledger's
// mutations and the recurring templates' mutations and generation, from the
// real Dart code, through a real AtomicFinancialStore (files in a temp
// directory) with a pinned clock and seeded UUIDs, in several zones
// (run.sh): America/New_York, America/Santiago (DST change at midnight) and
// Australia/Lord_Howe (30-minute change). Dates are built from local
// components, so DST gaps and repeated hours resolve the same way on both
// sides; every instant is also carried as epoch microseconds, because an
// ambiguous wall time has the same ISO text for two different instants.
//
// mutations.json: scenarios of `TransactionModel.addTransaction`,
// `updateTransaction` and `deleteTransactionById`. Per step the op, the
// clock, whether the store was written, the returned bool, the stored
// `transactions` section and the model's memory (every field).
//
// templates.json: scenarios of `RecurringTransactionModel.add/update/
// deleteRecurringTransaction` (the recurring form's Save, add then generate,
// and its edit) and `TransactionGenerator.generateDueTransactions` through
// the same store. Flutter's edit replaces the template with a fresh row:
// `nextOccurrence` = start date and `isActive` = true, which generates the
// already generated occurrences again. Swift's edit keeps the cursor and the
// pause state (approved difference Q2), restarting the cursor only when the
// schedule changed, past the last occurrence already generated. An edit step
// therefore records Dart's real templates section (`dartTemplates`) and the
// section Swift must write (`sections`), computed below with Dart's own
// arithmetic, and the Dart store is realigned to the Swift result before the
// next step so later steps compare equal (the categories D6 pattern).

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/recurring_transaction.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_generator.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter/material.dart' show isSameDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

String get zoneDir => 'transactions/tz/${parityTz.replaceAll('/', '_')}';

Map<String, Object?> dt(DateTime d) => {
  'iso': d.toIso8601String(),
  'us': d.microsecondsSinceEpoch,
};

Map<String, Object?> txMemory(Transaction t) => {
  'id': t.id,
  'type': t.type.name,
  'description': t.description,
  'amount': bitsHex(t.amount),
  'category': t.category,
  'date': dt(t.date),
  'recurringTemplateId': t.recurringTemplateId,
  'tagIds': t.tagIds,
  'createdAt': dt(t.createdAt),
  'updatedAt': dt(t.updatedAt),
};

Map<String, Object?> templateMemory(RecurringTransaction t) => {
  'id': t.id,
  'type': t.type.name,
  'description': t.description,
  'amount': bitsHex(t.amount),
  'category': t.category,
  'pattern': t.pattern.name,
  'startDate': dt(t.startDate),
  'nextOccurrence': dt(t.nextOccurrence),
  'dayOfMonth': t.dayOfMonth,
  'dayOfWeek': t.dayOfWeek,
  'isActive': t.isActive,
};

TransactionTyp typeOf(Object? name) =>
    name == 'income' ? TransactionTyp.income : TransactionTyp.expense;

/// Stored local date strings (no zone designator) whose Dart round trip
/// changes the text: a wall time inside a DST gap is moved forward by the
/// parse. Dart rewrites every row when it saves a section; Swift keeps the
/// text of a row it did not touch (MIGRATION_SPEC 7.1), so the Swift test
/// maps these strings, and only these, to Dart's text before comparing.
List<List<String>> gapTexts(Object? initial) {
  final strings = <String>{};
  collectStrings(initial, strings);
  final shape = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?$');
  final pairs = <List<String>>[];
  for (final s in strings.toList()..sort()) {
    if (!shape.hasMatch(s)) continue;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) continue;
    final rewritten = parsed.toIso8601String();
    if (rewritten != s) pairs.add([s, rewritten]);
  }
  return pairs;
}

// ---------------------------------------------------------------------------
// Transaction mutations

Map<String, Object?> addOp(
  String type,
  String description,
  double amount,
  String category,
  List date, {
  String? template,
  List<String> tags = const [],
}) => {
  'op': 'add',
  'type': type,
  'description': description,
  'amount': amount,
  'category': category,
  'date': date,
  'template': template,
  'tags': tags,
};

/// `mode`: 'form' is the edit form (`transactionToEdit.copyWith(...)`, tags
/// replaced by the picked ones, or kept with `tags: 'keep'`); 'fresh' is a
/// brand new `Transaction` with another id, createdAt and no template, to
/// show the model keeps the stored ones.
Map<String, Object?> updateOp(
  Object ref,
  String type,
  String description,
  double amount,
  String category,
  List date, {
  Object tags = 'keep',
  String mode = 'form',
}) => {
  'op': 'update',
  'ref': ref,
  'mode': mode,
  'type': type,
  'description': description,
  'amount': amount,
  'category': category,
  'date': date,
  'tags': tags,
};

Map<String, Object?> deleteOp(Object ref) => {'op': 'delete', 'ref': ref};
Map<String, Object?> clockOp(List c) => {'op': 'clock', 'to': c};
Map<String, Object?> clockPlusOp(int micros) => {
  'op': 'clockPlus',
  'micros': micros,
};

/// [count] adds of a deterministic mix, in one step.
Map<String, Object?> addManyOp(int count) => {
  'op': 'addMany',
  'rows': [
    for (var i = 0; i < count; i++)
      {
        'type': i % 5 == 0 ? 'income' : 'expense',
        'description': 'Bulk $i',
        'amount': 10.0 + i * 1.25,
        'category': ['General', 'Groceries', 'Eating Out'][i % 3],
        'date': [2026, 9, 1 + i % 28, 8 + i % 10, i % 60],
      },
  ],
};

String resolveId(TransactionModel model, Object? ref) =>
    ref is int ? model.transactions[ref].id : ref as String;

Future<Map<String, Object?>> runTransactionScenario(
  Map<String, Object?> scenario,
) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('transactions_fixture');
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final store = AtomicFinancialStore.instance;
  seedUuids(scenario['seed'] as int);
  var clock = local(scenario['launch'] as List);
  pinClock(clock);
  final initial = scenario['initial'] as Map<String, Object?>;
  if (initial.isNotEmpty) await store.updateSections(initial);
  final model = TransactionModel();
  await model.getTransactions();
  final loaded = [for (final t in model.transactions) txMemory(t)];
  final loadedSection =
      (await store.read()).sections[FinancialSections.transactions];

  final steps = <Map<String, Object?>>[];
  for (final op in (scenario['ops'] as List).cast<Map<String, Object?>>()) {
    if (op['op'] == 'clock') {
      clock = local(op['to'] as List);
      pinClock(clock);
      steps.add({'op': 'clock', 'now': dt(clock)});
      continue;
    }
    if (op['op'] == 'clockPlus') {
      clock = clock.add(Duration(microseconds: op['micros'] as int));
      pinClock(clock);
      steps.add({'op': 'clock', 'now': dt(clock)});
      continue;
    }
    final before = (await store.read()).revision;
    final step = <String, Object?>{'op': op['op'], 'now': dt(clock)};
    bool? result;
    switch (op['op']) {
      case 'add':
        final date = local(op['date'] as List);
        final amount = (op['amount'] as num).toDouble();
        step.addAll({
          'type': op['type'],
          'description': op['description'],
          'amount': bitsHex(amount),
          'category': op['category'],
          'date': dt(date),
          'template': op['template'],
          'tags': op['tags'],
        });
        final count = model.transactions.length;
        result = await model.addTransaction(
          typeOf(op['type']),
          op['description'] as String,
          amount,
          op['category'] as String,
          date,
          recurringTemplateId: op['template'] as String?,
          tagIds: List<String>.from(op['tags'] as List),
        );
        step['newId'] = model.transactions.length > count
            ? model.transactions.last.id
            : null;
      case 'addMany':
        final rows = <Map<String, Object?>>[];
        final ids = <String>[];
        for (final row in (op['rows'] as List).cast<Map<String, Object?>>()) {
          final date = local(row['date'] as List);
          final amount = (row['amount'] as num).toDouble();
          result = await model.addTransaction(
            typeOf(row['type']),
            row['description'] as String,
            amount,
            row['category'] as String,
            date,
          );
          ids.add(model.transactions.last.id);
          rows.add({
            'type': row['type'],
            'description': row['description'],
            'amount': bitsHex(amount),
            'category': row['category'],
            'date': dt(date),
          });
        }
        step.addAll({'rows': rows, 'newIds': ids});
      case 'update':
        final ref = op['ref'];
        final id = resolveId(model, ref);
        final date = local(op['date'] as List);
        final amount = (op['amount'] as num).toDouble();
        final tags = op['tags'];
        step.addAll({
          'ref': ref is int ? {'index': ref, 'id': id} : {'id': id},
          'mode': op['mode'],
          'type': op['type'],
          'description': op['description'],
          'amount': bitsHex(amount),
          'category': op['category'],
          'date': dt(date),
          'tags': tags,
        });
        final shown = model.transactions.where((t) => t.id == id).firstOrNull;
        final Transaction updated;
        if (op['mode'] == 'fresh') {
          updated = Transaction(
            id: 'ignored-by-the-model',
            type: typeOf(op['type']),
            description: op['description'] as String,
            amount: amount,
            category: op['category'] as String,
            date: date,
            tagIds: List<String>.from(tags as List),
            createdAt: DateTime(2000, 1, 1),
            updatedAt: DateTime(2000, 1, 1),
          );
        } else {
          final base =
              shown ??
              Transaction(
                id: id,
                type: TransactionTyp.expense,
                description: 'Stale',
                amount: 1,
                category: 'General',
                date: date,
              );
          updated = base.copyWith(
            type: typeOf(op['type']),
            description: op['description'] as String,
            amount: amount,
            category: op['category'] as String,
            date: date,
            tagIds: tags == 'keep' ? null : List<String>.from(tags as List),
          );
        }
        result = await model.updateTransaction(id, updated);
      case 'delete':
        final id = resolveId(model, op['ref']);
        final ref = op['ref'];
        step['ref'] = ref is int ? {'index': ref, 'id': id} : {'id': id};
        result = await model.deleteTransactionById(id);
      default:
        throw ArgumentError('unknown op ${op['op']}');
    }
    final snapshot = await store.read();
    final section = snapshot.sections[FinancialSections.transactions];
    step.addAll({
      'result': result,
      'wrote': snapshot.revision != before,
      'section': section == null ? null : jsonEncode(section),
      'memory': [for (final t in model.transactions) txMemory(t)],
      'hasUnsavedChanges': model.hasUnsavedChanges,
    });
    steps.add(step);
  }
  final out = {
    'name': scenario['name'],
    'byteComparable': scenario['byteComparable'],
    'launch': dt(local(scenario['launch'] as List)),
    'initial': initial.isEmpty ? null : jsonEncode(initial),
    'gapTexts': gapTexts(initial),
    'loaded': loaded,
    'loadedSection': loadedSection == null ? null : jsonEncode(loadedSection),
    'steps': steps,
  };
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  return out;
}

Map<String, Object?> stored(
  String id,
  String date, {
  String type = 'expense',
  double amount = 10.0,
  String category = 'General',
  String? template,
}) => {
  'id': id,
  'type': type,
  'description': id,
  'amount': amount,
  'category': category,
  'date': date,
  'recurringTemplateId': template,
  'tagIds': <String>[],
  'createdAt': '2026-09-01T08:00:00.000',
  'updatedAt': '2026-09-01T08:00:00.000',
};

final transactionScenarios = <Map<String, Object?>>[
  {
    // Data the Dart model wrote itself: Swift's in-place patch must produce
    // the same bytes after every step.
    'name': 'canonical',
    'byteComparable': true,
    'seed': 41,
    'launch': [2026, 9, 28, 9, 15, 30, 250, 7],
    'initial': <String, Object?>{},
    'ops': [
      addOp('expense', 'Coffee', 4.5, 'Eating Out', [2026, 9, 27, 8, 30]),
      addOp(
        'income',
        'Pay',
        3200.0,
        'Salary',
        [2026, 9, 1],
        tags: ['tag-a', 'tag-b'],
      ),
      addOp('expense', 'Rent', 1500.0, 'Housing', [
        2026,
        9,
        1,
      ], template: 'tpl-1'),
      addOp('expense', '', 0.1 + 0.2, 'General', [
        2026,
        9,
        28,
        23,
        59,
        59,
        999,
        999,
      ]),
      addOp('income', 'Big', 1e21, 'Salary', [2026, 9, 2]),
      addOp('expense', 'Tiny', 1e-7, 'General', [2026, 9, 2, 0, 0, 0, 1]),
      addOp('expense', 'Negative', -5.0, 'General', [2026, 9, 3]),
      addOp('expense', 'Zero', 0.0, 'General', [2026, 9, 3]),
      addOp(
        'expense',
        'Caf\u00e9 \u2615\ufe0f "q" \\ \u{1F355}',
        12.25,
        'Caf\u00e9',
        [2025, 12, 31, 23, 59, 59, 999],
      ),
      addOp('expense', 'line1\nline2\t\u007f<>&', 7.0, 'General', [2026, 9, 4]),
      // Same clock as the adds: updatedAt moves one microsecond each time.
      updateOp(0, 'expense', 'Coffee beans', 6.75, 'Groceries', [
        2026,
        9,
        27,
        8,
        30,
      ]),
      updateOp(0, 'expense', 'Coffee beans', 6.75, 'Groceries', [
        2026,
        9,
        27,
        8,
        30,
      ]),
      clockPlusOp(1000000),
      updateOp(
        0,
        'expense',
        'Coffee',
        4.5,
        'Eating Out',
        [2026, 9, 26, 9],
        mode: 'fresh',
        tags: ['fresh'],
      ),
      // The template link survives a fresh row with none, and a type change.
      updateOp(
        2,
        'income',
        'Rent refund',
        1500.0,
        'Salary',
        [2026, 9, 5],
        mode: 'fresh',
        tags: <String>[],
      ),
      updateOp(2, 'expense', 'Rent', 1500.0, 'Housing', [2026, 9, 1]),
      // Tags: kept, cleared, replaced.
      updateOp(1, 'income', 'Pay', 3200.0, 'Salary', [2026, 9, 1]),
      updateOp(1, 'income', 'Pay', 3200.0, 'Salary', [
        2026,
        9,
        1,
      ], tags: <String>[]),
      updateOp(
        1,
        'income',
        'Pay',
        3200.0,
        'Salary',
        [2026, 9, 1],
        tags: ['x', 'y', 'z'],
      ),
      updateOp('missing-id', 'expense', 'Ghost', 1.0, 'General', [2026, 9, 1]),
      // The clock before the stored updatedAt: old + 1 microsecond.
      clockOp([2026, 9, 28, 9, 15, 29]),
      updateOp(3, 'expense', 'Back in time', 9.99, 'General', [2026, 9, 28]),
      updateOp(3, 'expense', 'Back in time', 9.99, 'General', [2026, 9, 28]),
      clockOp([2026, 9, 28, 9, 15, 30, 250, 7]),
      deleteOp('missing-id'),
      deleteOp(0),
      deleteOp(0),
      deleteOp(2),
      addManyOp(36),
      deleteOp(17),
      deleteOp('missing-id'),
      deleteOp(0),
      addOp('expense', 'After delete', 1.0, 'General', [2026, 9, 28]),
    ],
  },
  {
    // Data another writer produced: unknown keys, int and string-free
    // amounts, a blank id, a duplicate id, missing createdAt/updatedAt, a
    // date-only string, non-string tags, a template link. Dart rewrites the
    // whole section; Swift patches rows in place (bytes differ by design).
    // Memory must agree after every step.
    'name': 'foreign',
    'byteComparable': false,
    'seed': 42,
    'launch': [2026, 6, 15, 12],
    'initial': <String, Object?>{
      'transactions': [
        {
          'id': 't-int',
          'type': 'expense',
          'description': ' int amount ',
          'amount': 12,
          'category': 'Groceries',
          'date': '2026-06-01T10:00:00.000',
          'recurringTemplateId': 'tpl-x',
          'tagIds': ['a', 5, 'b'],
          'createdAt': '2026-06-01T10:00:01.000',
          'updatedAt': '2026-06-01T10:00:02.000',
          'note': {
            'keep': [1, 2.50],
          },
        },
        {
          'id': '',
          'type': 'income',
          'description': 'blank id',
          'amount': 100.5,
          'category': 'Salary',
          'date': '2026-06-02',
        },
        {
          'id': 't-dup',
          'type': 'expense',
          'description': 'dup A',
          'amount': 1.5,
          'category': 'General',
          'date': '2026-06-03T00:00:00.000',
          'createdAt': '2026-06-03T00:00:00.000',
          'updatedAt': '2026-06-03T00:00:00.000',
        },
        {
          'id': 't-dup',
          'type': 'expense',
          'description': 'dup B',
          'amount': 2.5,
          'category': 'General',
          'date': '2026-06-04T00:00:00.000',
          'createdAt': '2026-06-04T00:00:00.000',
          'updatedAt': '2026-06-04T00:00:00.000',
        },
        {
          'id': 't-utc',
          'type': 'expense',
          'description': 'utc',
          'amount': 3.0,
          'category': 'General',
          'date': '2026-06-05T12:00:00.000Z',
          'createdAt': '2026-06-05T12:00:00.000Z',
        },
        {
          'id': 't-old',
          'type': 'weird',
          'description': 'unknown type reads as income',
          'amount': 4.0,
          'category': 'General',
          'date': '2026-06-06T00:00:00.000',
        },
      ],
    },
    'ops': [
      updateOp(
        0,
        'expense',
        'int amount',
        13.0,
        'Groceries',
        [2026, 6, 1, 10],
        tags: ['a'],
      ),
      updateOp(1, 'income', 'blank id', 100.5, 'Salary', [2026, 6, 2]),
      updateOp(2, 'expense', 'dup A', 1.5, 'General', [2026, 6, 3]),
      updateOp(3, 'expense', 'dup B edited', 2.5, 'General', [2026, 6, 4]),
      updateOp(4, 'expense', 'utc', 3.0, 'General', [2026, 6, 5, 8]),
      updateOp(5, 'expense', 'was income', 4.0, 'General', [2026, 6, 6]),
      deleteOp(1),
      deleteOp(0),
      addOp('expense', 'New', 5.0, 'General', [2026, 6, 15]),
      deleteOp('t-dup'),
    ],
  },
  {
    // DST and repeated hours. New York skips 02:00-03:00 on 2026-03-08 and
    // repeats 01:00-02:00 on 2026-11-01; Santiago skips 00:00-01:00 on
    // 2026-09-06 and repeats 23:00-24:00 on 2026-04-04; Lord Howe skips
    // 02:00-02:30 on 2026-10-04 and repeats 01:30-02:00 on 2026-04-05. In
    // the zones where a time is ordinary it is simply an ordinary time.
    // The clock is moved by elapsed time (clockPlus) to reach the second
    // occurrence of a repeated hour and to go back before updatedAt.
    'name': 'dst',
    'byteComparable': true,
    'seed': 43,
    'launch': [2026, 9, 6, 0, 30],
    'initial': <String, Object?>{},
    'ops': [
      clockOp([2026, 9, 6, 0, 30]),
      addOp('expense', 'Santiago gap', 10.0, 'General', [2026, 9, 6, 0, 30]),
      addOp('expense', 'Santiago gap midnight', 11.0, 'General', [2026, 9, 6]),
      addOp('expense', 'Santiago before', 12.0, 'General', [
        2026,
        9,
        5,
        23,
        59,
        59,
        999,
      ]),
      clockOp([2026, 4, 4, 23, 30]),
      addOp('expense', 'Santiago fold', 20.0, 'General', [2026, 4, 4, 23, 30]),
      addOp('income', 'Santiago fold income', 21.0, 'Salary', [
        2026,
        4,
        4,
        23,
        59,
        59,
        999,
      ]),
      // One hour of elapsed time later: the second 23:30 in Santiago.
      clockPlusOp(3600 * 1000000),
      updateOp(3, 'expense', 'Santiago fold later', 20.5, 'General', [
        2026,
        4,
        4,
        23,
        30,
      ]),
      addOp('expense', 'Second 23:30', 22.0, 'General', [2026, 4, 5, 0, 30]),
      // Back one hour: before the stored updatedAt, so old + 1 microsecond.
      clockPlusOp(-3600 * 1000000),
      updateOp(3, 'expense', 'Santiago fold earlier', 20.25, 'General', [
        2026,
        4,
        4,
        23,
        30,
      ]),
      // Move a row into the Santiago gap.
      updateOp(0, 'expense', 'Santiago gap moved', 10.0, 'General', [
        2026,
        9,
        6,
        0,
        0,
      ]),
      updateOp(2, 'expense', 'Santiago before moved', 12.0, 'General', [
        2026,
        9,
        6,
        0,
        59,
        59,
        999,
      ]),
      clockOp([2026, 3, 8, 2, 30]),
      addOp('expense', 'NY gap', 30.0, 'General', [2026, 3, 8, 2, 30]),
      addOp('expense', 'NY gap after', 31.0, 'General', [2026, 3, 8, 3]),
      clockOp([2026, 11, 1, 1, 30]),
      addOp('expense', 'NY fold', 40.0, 'General', [2026, 11, 1, 1, 30]),
      clockPlusOp(3600 * 1000000),
      updateOp(8, 'expense', 'NY fold later', 40.5, 'General', [
        2026,
        11,
        1,
        1,
        30,
      ]),
      clockOp([2026, 10, 4, 2, 15]),
      addOp('expense', 'Lord Howe gap', 50.0, 'General', [2026, 10, 4, 2, 15]),
      addOp('expense', 'Lord Howe gap edge', 51.0, 'General', [
        2026,
        10,
        4,
        2,
        29,
        59,
        999,
      ]),
      clockOp([2026, 4, 5, 1, 45]),
      addOp('expense', 'Lord Howe fold', 60.0, 'General', [2026, 4, 5, 1, 45]),
      clockPlusOp(1800 * 1000000),
      updateOp(11, 'expense', 'Lord Howe fold later', 60.5, 'General', [
        2026,
        4,
        5,
        1,
        45,
      ]),
      deleteOp(0),
      deleteOp(10),
      addOp('expense', 'End', 1.0, 'General', [2026, 9, 6, 12]),
    ],
  },
  {
    // Stored wall times in a gap or a repeated hour, as another writer (or an
    // earlier version in another zone) left them. Dart parses a gap time
    // one hour later and writes that text when it saves the section (only
    // that text differs from what Swift keeps: see `gapTexts`).
    'name': 'dst-stored',
    'byteComparable': true,
    'seed': 44,
    'launch': [2026, 9, 28, 9, 15],
    'initial': <String, Object?>{
      'transactions': [
        stored('s-gap', '2026-09-06T00:00:00.000'),
        stored('s-gap-half', '2026-09-06T00:30:00.000'),
        stored('s-gap-edge', '2026-09-06T00:59:59.999'),
        stored('s-fold', '2026-04-04T23:30:00.000'),
        stored('s-ny-gap', '2026-03-08T02:30:00.000'),
        stored('s-ny-fold', '2026-11-01T01:30:00.000'),
        stored('s-lh-gap', '2026-10-04T02:15:00.000'),
        stored('s-lh-fold', '2026-04-05T01:45:00.000'),
        stored('s-day', '2026-09-06T12:00:00.000'),
      ],
    },
    'ops': [
      updateOp(0, 'expense', 's-gap edited', 10.0, 'General', [
        2026,
        9,
        6,
        0,
        0,
      ]),
      updateOp(1, 'expense', 's-gap-half', 10.0, 'General', [
        2026,
        9,
        6,
        0,
        30,
      ]),
      updateOp(3, 'expense', 's-fold edited', 10.0, 'General', [
        2026,
        4,
        4,
        23,
        30,
      ]),
      deleteOp(2),
      addOp('expense', 'New', 1.0, 'General', [2026, 9, 28]),
      updateOp(3, 'expense', 's-ny-gap edited', 10.0, 'General', [
        2026,
        3,
        8,
        2,
        30,
      ]),
      deleteOp('s-lh-gap'),
    ],
  },
];

// ---------------------------------------------------------------------------
// Recurring templates

Map<String, Object?> addTemplateOp(
  String type,
  String description,
  double amount,
  String category,
  String pattern,
  List start, {
  int? dom,
}) => {
  'op': 'addT',
  'type': type,
  'description': description,
  'amount': amount,
  'category': category,
  'pattern': pattern,
  'start': start,
  'dom': dom,
};

/// The recurring form's edit: `start` is 'keep' (the form's untouched start
/// date) or a picked day.
Map<String, Object?> editTemplateOp(
  Object ref,
  String type,
  String description,
  double amount,
  String category,
  String pattern,
  Object start, {
  int? dom,
}) => {
  'op': 'editT',
  'ref': ref,
  'type': type,
  'description': description,
  'amount': amount,
  'category': category,
  'pattern': pattern,
  'start': start,
  'dom': dom,
};

Map<String, Object?> deleteTemplateOp(Object ref) => {
  'op': 'deleteT',
  'ref': ref,
};
Map<String, Object?> generateOp() => {'op': 'generate'};

RecurrencePattern patternOf(Object? name) =>
    RecurrencePattern.values.firstWhere((p) => p.name == name);

/// What the recurring form's Save builds (recurring_transaction_form.dart:
/// 658-674): the day of the month for monthly only, the weekday wheel for
/// weekly and biweekly only (here the start's weekday, which is what Swift
/// writes; nothing reads it), and a cursor at the start date, active.
RecurringTransaction formTemplate(
  String? id,
  Map<String, Object?> op,
  DateTime start,
) {
  final pattern = patternOf(op['pattern']);
  return RecurringTransaction(
    id: id,
    type: typeOf(op['type']),
    description: op['description'] as String,
    amount: (op['amount'] as num).toDouble(),
    category: op['category'] as String,
    pattern: pattern,
    startDate: start,
    dayOfMonth: pattern == RecurrencePattern.monthly ? op['dom'] as int : null,
    dayOfWeek: pattern == RecurrencePattern.monthly ? null : start.weekday,
  );
}

/// Swift's edit (`FinancialData.updateTemplate`, approved divergence Q2),
/// computed with Dart's arithmetic: the edited fields on the stored row, the
/// pause state kept, and the cursor kept unless the schedule (pattern, start
/// date text, day of month) changed; then it restarts at the new start date
/// and is stepped until it is after the last generated occurrence's day.
RecurringTransaction swiftEdit(
  RecurringTransaction previous,
  RecurringTransaction form,
  DateTime? lastGenerated,
) {
  final scheduleChanged =
      previous.pattern != form.pattern ||
      previous.startDate.toIso8601String() !=
          form.startDate.toIso8601String() ||
      previous.dayOfMonth != form.dayOfMonth;
  var cursor = previous.nextOccurrence;
  if (scheduleChanged) {
    cursor = form.startDate;
    if (lastGenerated != null) {
      var guard = 0;
      while ((cursor.isBefore(lastGenerated) ||
              isSameDay(cursor, lastGenerated)) &&
          guard < 5000) {
        cursor = form
            .copyWith(nextOccurrence: cursor)
            .calculateNextOccurrence();
        guard += 1;
      }
    }
  }
  return form.copyWith(nextOccurrence: cursor, isActive: previous.isActive);
}

String resolveTemplateId(RecurringTransactionModel model, Object? ref) =>
    ref is int ? model.recurringTransactions[ref].id : ref as String;

Future<Map<String, Object?>> runTemplateScenario(
  Map<String, Object?> scenario,
) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('templates_fixture');
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final store = AtomicFinancialStore.instance;
  seedUuids(scenario['seed'] as int);
  var clock = local(scenario['launch'] as List);
  pinClock(clock);
  final initial = scenario['initial'] as Map<String, Object?>;
  if (initial.isNotEmpty) await store.updateSections(initial);
  final transactions = TransactionModel();
  final recurring = RecurringTransactionModel();
  await transactions.getTransactions();
  await recurring.loadRecurringTransactions();
  final generator = TransactionGenerator(
    transactionModel: transactions,
    recurringModel: recurring,
  );

  Future<Map<String, String?>> sections() async {
    final s = (await store.read()).sections;
    return {
      for (final name in [
        FinancialSections.recurringTransactions,
        FinancialSections.transactions,
      ])
        name: s[name] == null ? null : jsonEncode(s[name]),
    };
  }

  var previous = await sections();
  final loaded = {
    'templates': [
      for (final t in recurring.recurringTransactions) templateMemory(t),
    ],
    'transactions': [for (final t in transactions.transactions) txMemory(t)],
  };

  final steps = <Map<String, Object?>>[];
  for (final op in (scenario['ops'] as List).cast<Map<String, Object?>>()) {
    if (op['op'] == 'clock') {
      clock = local(op['to'] as List);
      pinClock(clock);
      steps.add({'op': 'clock', 'now': dt(clock)});
      continue;
    }
    if (op['op'] == 'clockPlus') {
      clock = clock.add(Duration(microseconds: op['micros'] as int));
      pinClock(clock);
      steps.add({'op': 'clock', 'now': dt(clock)});
      continue;
    }
    final revision = (await store.read()).revision;
    final step = <String, Object?>{'op': op['op'], 'now': dt(clock)};
    bool? result;
    Map<String, Object?>? swiftRow;
    String? editedId;
    final txCount = transactions.transactions.length;
    switch (op['op']) {
      case 'addT':
        final start = local(op['start'] as List);
        final template = formTemplate(null, op, start);
        step.addAll({
          'type': op['type'],
          'description': op['description'],
          'amount': bitsHex(template.amount),
          'category': op['category'],
          'pattern': op['pattern'],
          'start': dt(start),
          'dom': op['dom'],
          'newId': template.id,
        });
        result = await recurring.addRecurringTransaction(template);
      case 'generate':
        await generator.generateDueTransactions();
        step['newTransactionIds'] = [
          for (final t in transactions.transactions.skip(txCount)) t.id,
        ];
      case 'editT':
        final ref = op['ref'];
        final id = resolveTemplateId(recurring, ref);
        editedId = id;
        final shown = recurring.getRecurringTransaction(id);
        final start = op['start'] == 'keep'
            ? (shown?.startDate ?? local([2026, 1, 1]))
            : local(op['start'] as List);
        final form = formTemplate(id, op, start);
        step.addAll({
          'ref': ref is int ? {'index': ref, 'id': id} : {'id': id},
          'type': op['type'],
          'description': op['description'],
          'amount': bitsHex(form.amount),
          'category': op['category'],
          'pattern': op['pattern'],
          'start': dt(start),
          'keepStart': op['start'] == 'keep',
          'dom': op['dom'],
        });
        final last = transactions.transactions
            .where((t) => t.recurringTemplateId == id)
            .map((t) => t.date)
            .fold<DateTime?>(null, (m, d) => m == null || d.isAfter(m) ? d : m);
        if (shown != null) swiftRow = swiftEdit(shown, form, last).toJson();
        result = await recurring.updateRecurringTransaction(id, form);
      case 'deleteT':
        final ref = op['ref'];
        final id = resolveTemplateId(recurring, ref);
        step['ref'] = ref is int ? {'index': ref, 'id': id} : {'id': id};
        result = await recurring.deleteRecurringTransaction(id);
      default:
        throw ArgumentError('unknown op ${op['op']}');
    }
    var after = await sections();
    if (op['op'] == 'editT' && swiftRow != null) {
      // Approved difference: record Dart's real section, then realign the
      // store and the model to what Swift writes.
      final dartTemplates = after[FinancialSections.recurringTransactions];
      final list = (jsonDecode(dartTemplates!) as List).cast<Map>();
      final expected = [
        for (final row in list)
          row['id'] == editedId ? swiftRow : row.cast<String, Object?>(),
      ];
      step['dartTemplates'] = dartTemplates;
      step['differs'] = jsonEncode(expected) != dartTemplates;
      await store.updateSections({
        FinancialSections.recurringTransactions: expected,
      });
      await recurring.loadRecurringTransactions();
      after = await sections();
    }
    final snapshot = await store.read();
    step.addAll({
      'result': result,
      'wrote': snapshot.revision != revision,
      'sections': {
        for (final e in after.entries)
          if (e.value != previous[e.key]) e.key: e.value,
      },
      'templates': [
        for (final t in recurring.recurringTransactions) templateMemory(t),
      ],
      'transactions': [for (final t in transactions.transactions) txMemory(t)],
      'hasUnsavedChanges':
          transactions.hasUnsavedChanges || recurring.hasUnsavedChanges,
    });
    previous = after;
    steps.add(step);
  }
  final out = {
    'name': scenario['name'],
    'byteComparable': scenario['byteComparable'],
    'launch': dt(local(scenario['launch'] as List)),
    'initial': initial.isEmpty ? null : jsonEncode(initial),
    'gapTexts': gapTexts(initial),
    'loaded': loaded,
    'steps': steps,
  };
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  return out;
}

final templateScenarios = <Map<String, Object?>>[
  {
    // The form's add (then generate), its edit, delete, and generation after
    // each, at a fixed launch clock.
    'name': 'form',
    'byteComparable': true,
    'seed': 51,
    'launch': [2026, 9, 28, 9, 15, 30, 250, 7],
    'initial': <String, Object?>{},
    'ops': [
      addTemplateOp('expense', 'Gym', 30.0, 'Health', 'weekly', [
        2026,
        9,
        28,
        9,
        15,
        30,
        250,
        7,
      ]),
      generateOp(),
      addTemplateOp('income', 'Pay', 3200.0, 'Salary', 'monthly', [
        2026,
        8,
        31,
      ], dom: 31),
      generateOp(),
      addTemplateOp('expense', 'Rent', 1500.0, 'Housing', 'biweekly', [
        2026,
        8,
        3,
      ]),
      generateOp(),
      clockPlusOp(8 * 24 * 3600 * 1000000),
      generateOp(),
      // Edits that leave the schedule alone: Dart resets the cursor to the
      // start date and reactivates; Swift keeps both.
      editTemplateOp(
        0,
        'expense',
        'Gym plus',
        35.0,
        'Health',
        'weekly',
        'keep',
      ),
      editTemplateOp(
        1,
        'income',
        'Pay',
        3300.0,
        'Salary',
        'monthly',
        'keep',
        dom: 31,
      ),
      generateOp(),
      // Schedule changes: a new start, pattern or day of month.
      editTemplateOp(0, 'expense', 'Gym plus', 35.0, 'Health', 'weekly', [
        2026,
        10,
        1,
      ]),
      editTemplateOp(1, 'income', 'Pay', 3300.0, 'Salary', 'monthly', [
        2026,
        8,
        31,
      ], dom: 15),
      editTemplateOp(2, 'expense', 'Rent', 1500.0, 'Housing', 'monthly', [
        2026,
        9,
        1,
      ], dom: 1),
      generateOp(),
      editTemplateOp(
        'missing-id',
        'expense',
        'Ghost',
        1.0,
        'General',
        'weekly',
        [2026, 10, 1],
      ),
      deleteTemplateOp(0),
      deleteTemplateOp('missing-id'),
      clockPlusOp(40 * 24 * 3600 * 1000000),
      generateOp(),
      deleteTemplateOp(0),
      deleteTemplateOp(0),
      generateOp(),
    ],
  },
  {
    // Templates written by another writer: unknown keys, a paused template,
    // an old cursor, a cursor in the future; edit and delete them.
    'name': 'foreign',
    'byteComparable': false,
    'seed': 52,
    'launch': [2026, 9, 28, 9, 15, 30, 250, 7],
    'initial': <String, Object?>{
      'recurringTransactions': [
        {
          'id': 'r-paused',
          'type': 'expense',
          'description': 'Paused',
          'amount': 10.0,
          'category': 'General',
          'pattern': 'weekly',
          'startDate': '2026-08-03T00:00:00.000',
          'nextOccurrence': '2026-08-03T00:00:00.000',
          'dayOfMonth': null,
          'dayOfWeek': 1,
          'isActive': false,
          'color': 'teal',
        },
        {
          'id': 'r-old',
          'type': 'expense',
          'description': 'Old cursor',
          'amount': 20.0,
          'category': 'General',
          'pattern': 'monthly',
          'startDate': '2026-01-15T00:00:00.000',
          'nextOccurrence': '2026-07-15T00:00:00.000',
          'dayOfMonth': 15,
          'dayOfWeek': null,
          'isActive': true,
        },
        {
          'id': 'r-future',
          'type': 'income',
          'description': 'Future',
          'amount': 30.0,
          'category': 'Salary',
          'pattern': 'biweekly',
          'startDate': '2026-10-05T00:00:00.000',
          'nextOccurrence': '2026-10-05T00:00:00.000',
          'dayOfMonth': null,
          'dayOfWeek': 1,
        },
      ],
      'transactions': [
        stored('g-1', '2026-07-15T00:00:00.000', template: 'r-old'),
        stored('g-2', '2026-08-15T00:00:00.000', template: 'r-old'),
      ],
    },
    'ops': [
      generateOp(),
      editTemplateOp(
        0,
        'expense',
        'Paused edited',
        11.0,
        'General',
        'weekly',
        'keep',
      ),
      editTemplateOp(1, 'expense', 'Old cursor', 20.0, 'General', 'monthly', [
        2026,
        6,
        15,
      ], dom: 15),
      editTemplateOp(2, 'income', 'Future', 31.0, 'Salary', 'biweekly', [
        2026,
        9,
        14,
      ]),
      generateOp(),
      deleteTemplateOp('r-paused'),
      deleteTemplateOp(1),
    ],
  },
  {
    // DST: generation and edits through the gap and repeated hour of each
    // zone (other zones see ordinary times). Weekly and biweekly steps are
    // elapsed time, monthly ones local midnights (a missing midnight becomes
    // 01:00), so each template is checked by instant.
    'name': 'dst',
    'byteComparable': true,
    'seed': 53,
    'launch': [2026, 4, 10, 12],
    'initial': <String, Object?>{},
    'ops': [
      clockOp([2026, 4, 10, 12]),
      addTemplateOp('expense', 'Santiago fold', 10.0, 'General', 'weekly', [
        2026,
        3,
        28,
        23,
        30,
      ]),
      addTemplateOp('expense', 'Lord Howe fold', 11.0, 'General', 'weekly', [
        2026,
        3,
        29,
        1,
        45,
      ]),
      addTemplateOp('expense', 'New York gap', 12.0, 'General', 'weekly', [
        2026,
        3,
        1,
        2,
        30,
      ]),
      generateOp(),
      clockOp([2026, 9, 10, 12]),
      addTemplateOp('expense', 'Santiago gap', 13.0, 'General', 'weekly', [
        2026,
        8,
        30,
      ]),
      addTemplateOp('income', 'Monthly gap', 14.0, 'Salary', 'monthly', [
        2026,
        8,
        6,
      ], dom: 6),
      addTemplateOp('expense', 'Biweekly gap', 15.0, 'General', 'biweekly', [
        2026,
        8,
        23,
      ]),
      generateOp(),
      clockOp([2026, 10, 10, 12]),
      addTemplateOp('expense', 'Lord Howe gap', 16.0, 'General', 'weekly', [
        2026,
        9,
        27,
        2,
        15,
      ]),
      generateOp(),
      clockOp([2026, 11, 10, 12]),
      addTemplateOp('expense', 'New York fold', 17.0, 'General', 'weekly', [
        2026,
        10,
        25,
        1,
        30,
      ]),
      generateOp(),
      // Edits that restart the cursor on, before and after a transition day.
      editTemplateOp(0, 'expense', 'Santiago fold', 10.0, 'General', 'weekly', [
        2026,
        4,
        4,
      ]),
      editTemplateOp(3, 'expense', 'Santiago gap', 13.0, 'General', 'weekly', [
        2026,
        9,
        6,
      ]),
      editTemplateOp(4, 'income', 'Monthly gap', 14.0, 'Salary', 'monthly', [
        2026,
        9,
        6,
      ], dom: 6),
      editTemplateOp(5, 'expense', 'Biweekly gap', 15.0, 'General', 'weekly', [
        2026,
        9,
        6,
      ]),
      editTemplateOp(
        6,
        'expense',
        'Lord Howe gap',
        16.0,
        'General',
        'monthly',
        [2026, 10, 4],
        dom: 4,
      ),
      editTemplateOp(7, 'expense', 'New York fold', 17.0, 'General', 'weekly', [
        2026,
        11,
        1,
      ]),
      clockOp([2026, 12, 1, 12]),
      generateOp(),
      deleteTemplateOp(3),
      deleteTemplateOp(0),
      generateOp(),
    ],
  },
  {
    // Stored wall times in a gap or a repeated hour, edited and generated.
    'name': 'dst-stored',
    'byteComparable': true,
    'seed': 54,
    'launch': [2026, 9, 28, 9, 15],
    'initial': <String, Object?>{
      'recurringTransactions': [
        {
          'id': 'r-gap',
          'type': 'expense',
          'description': 'Gap start',
          'amount': 10.0,
          'category': 'General',
          'pattern': 'weekly',
          'startDate': '2026-08-30T00:00:00.000',
          'nextOccurrence': '2026-09-06T00:00:00.000',
          'dayOfMonth': null,
          'dayOfWeek': 7,
          'isActive': true,
        },
        {
          'id': 'r-gap-monthly',
          'type': 'income',
          'description': 'Gap monthly',
          'amount': 20.0,
          'category': 'Salary',
          'pattern': 'monthly',
          'startDate': '2026-09-06T00:00:00.000',
          'nextOccurrence': '2026-09-06T00:00:00.000',
          'dayOfMonth': 6,
          'dayOfWeek': null,
          'isActive': true,
        },
        {
          'id': 'r-fold',
          'type': 'expense',
          'description': 'Fold',
          'amount': 30.0,
          'category': 'General',
          'pattern': 'biweekly',
          'startDate': '2026-04-04T23:30:00.000',
          'nextOccurrence': '2026-04-04T23:30:00.000',
          'dayOfMonth': null,
          'dayOfWeek': 6,
          'isActive': true,
        },
      ],
    },
    'ops': [
      generateOp(),
      editTemplateOp(
        0,
        'expense',
        'Gap start',
        11.0,
        'General',
        'weekly',
        'keep',
      ),
      editTemplateOp(
        1,
        'income',
        'Gap monthly',
        21.0,
        'Salary',
        'monthly',
        'keep',
        dom: 6,
      ),
      editTemplateOp(2, 'expense', 'Fold', 31.0, 'General', 'biweekly', [
        2026,
        4,
        4,
      ]),
      generateOp(),
      deleteTemplateOp(0),
    ],
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('transaction mutations', () async {
    final out = <Map<String, Object?>>[];
    for (final scenario in transactionScenarios) {
      out.add(await runTransactionScenario(scenario));
    }
    pinClock(null);
    writeJson('$fixturesRoot/$zoneDir/mutations.json', {
      'tz': parityTz,
      'scenarios': out,
    });
  });

  test('recurring template mutations and generation', () async {
    final out = <Map<String, Object?>>[];
    for (final scenario in templateScenarios) {
      out.add(await runTemplateScenario(scenario));
    }
    pinClock(null);
    writeJson('$fixturesRoot/$zoneDir/templates.json', {
      'tz': parityTz,
      'scenarios': out,
    });
  });
}
