// Emits native/Fixtures/csvimport/ : the CSV import stream's Dart oracle,
// from the real Flutter code.
//
// Zone independent (written from the New York run):
//   parser.json  csv 6.0.0 `CsvToListConverter` with the app's exact
//                settings (transaction_model.dart:1050-1056) on the corpus
//                and on seeded random strings, as UTF-16 code units; and
//                `utf8.decode(bytes, allowMalformed: true)`
//                (settings_page.dart:138) on seeded random byte strings.
//   page.json    the real SettingsPage "Import from CSV" row driven through
//                a fake FilePickerPlatform: the picker's arguments, the
//                confirm dialog's title and body, the SnackBar's text and
//                colour, and whether the store was written. Each case also
//                checks that the page shows exactly the copy `messages()`
//                below computes (a verbatim copy of the page's private
//                string logic), so the volume cases can rely on it.
// Per zone (tz/<zone>/import.json; New York, UTC, Lord Howe, Kolkata,
// Santiago):
//   cases   the adversarial corpus through a real store: launch
//           (`_initializeApp` without the generator), `utf8.decode`,
//           `parseTransactionsCsv`, `importTransactions`, then a relaunch
//           (its launch pass materialises the new category names). Records
//           the store before, the error (`e.toString()`) or the summary, the
//           page copy, the transactions section after the import and the
//           categories section after the relaunch.
//   random  seeded random files (the research pipeline generator) parsed
//           by a model holding random existing rows: summary and copy.
//
// Strings the Swift side compares are UTF-16 code-unit arrays; files are
// base64. New transaction ids in a section are replaced, in order, by
// "<new:N>", and a new category id "type-<uuid>" (its slug was taken) by
// "type-<uuid>", since both apps draw them at random. The clock is pinned,
// so every Dart `createdAt` is the launch clock; Swift's are launch + N
// microseconds (D6, strictly increasing), which its test isolates.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:budget_app/app_settings_provider.dart';
import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/category_provider.dart';
import 'package:budget_app/design_system.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/settings_page.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:csv/csv.dart';
import 'package:csv/csv_settings_autodetection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixture_runner.dart';
import 'harness_support.dart';

final bool writesZoneIndependent = parityTz == 'America/New_York';

String zoneDir() =>
    '$fixturesRoot/csvimport/tz/${parityTz.replaceAll('/', '_')}';

const h = 'Date,Type,Category,Description,Amount';

/// transaction_model.dart:1050-1056, for the parser fixture and the
/// per-case `csvRows` diagnostic (after the BOM strip of :1045-1048).
List<List<dynamic>> csvRows(String content) => const CsvToListConverter(
      shouldParseNumbers: false,
      csvSettingsDetector: FirstOccurrenceSettingsDetector(
        eols: ['\r\n', '\n'],
      ),
    ).convert(content);

List<List<List<int>>> rowUnits(List<List<dynamic>> rows) => [
      for (final row in rows) [for (final cell in row) (cell as String).codeUnits]
    ];

// --- Copied verbatim from settings_page.dart (private string logic) --------

/// The copy `_importTransactions` / `_confirmImport` show for [summary]:
/// :141-166 (empty result; `red` = the expense colour, else the default
/// SnackBar), :222-228 (dialog), :179-192 (success).
Map<String, Object?> messages(CsvImportSummary summary) {
  Map<String, Object?>? empty;
  if (summary.transactions.isEmpty) {
    final errorCount = summary.rowErrors.length;
    final String message;
    if (errorCount > 0) {
      message = summary.duplicateCount > 0
          ? 'No new transactions: ${summary.duplicateCount} duplicates '
              'skipped, $errorCount rows could not be read'
          : 'No transactions imported: $errorCount rows could not be read';
    } else {
      message = summary.duplicateCount > 0
          ? 'All transactions in this file already exist'
          : 'No transactions found in this file';
    }
    empty = {'text': message, 'red': errorCount > 0};
  }
  final count = summary.transactions.length;
  final details = <String>[];
  if (summary.duplicateCount > 0) {
    details.add('${summary.duplicateCount} duplicates will be skipped');
  }
  if (summary.rowErrors.isNotEmpty) {
    details.add('${summary.rowErrors.length} rows could not be read');
  }
  return {
    'empty': empty,
    'confirmTitle': 'Import $count transactions?',
    'confirmContent': details.isEmpty ? null : details.join('\n'),
    'success': summary.duplicateCount > 0
        ? 'Imported ${summary.transactions.length} transactions, '
            '${summary.duplicateCount} duplicates skipped'
        : 'Imported ${summary.transactions.length} transactions',
  };
}

/// settings_page.dart:194-206.
String failureText(Object e) => 'Could not import: $e';

// ---------------------------------------------------------------------------

typedef Tx = (String type, String description, double amount, String category, DateTime date);

Transaction build(Tx t) => Transaction(
      type: t.$1 == 'income' ? TransactionTyp.income : TransactionTyp.expense,
      description: t.$2,
      amount: t.$3,
      category: t.$4,
      date: t.$5,
    );

class CsvCase {
  final String name;
  final List<int> bytes;
  final List<Tx> existing;

  /// A store fixture to start from (`Fixtures/store/<name>/input`).
  final String? store;

  CsvCase(this.name, this.bytes, {this.existing = const [], this.store});
}

List<int> b(String text) => utf8.encode(text);

/// `buildExportCsv` of transaction_model_csv_import_test.dart: the export's
/// bytes (exportTransactionsToCSV, transaction_model.dart:995-1042).
List<int> exportOf(List<Transaction> transactions) {
  final rows = <List<dynamic>>[
    ['Date', 'Type', 'Category', 'Description', 'Amount'],
  ];
  final sorted = List<Transaction>.from(transactions)
    ..sort((a, b) => a.date.compareTo(b.date));
  for (final t in sorted) {
    rows.add([
      DateFormat('yyyy-MM-dd').format(t.date),
      t.type == TransactionTyp.income ? 'Income' : 'Expense',
      t.category,
      t.description,
      t.amount.toStringAsFixed(2),
    ]);
  }
  return utf8.encode(const ListToCsvConverter().convert(rows));
}

/// The store fixture's transactions as Flutter loads them.
Future<List<Transaction>> storeTransactions(String name) async {
  final work = await scratch('csv_store');
  final dir = Directory('${work.path}/financial_store');
  copyDir(Directory('$fixturesRoot/store/$name/input'), dir);
  SharedPreferences.setMockInitialValues(
      Map.of(prefsFrom(File('$fixturesRoot/store/$name/prefs.json'))));
  pinClock(launchNow);
  await store.resetForTesting(directory: dir);
  final model = TransactionModel();
  await model.getTransactions();
  return model.transactions;
}

DateTime d(int y, int m, int day) => DateTime(y, m, day);

Future<List<CsvCase>> corpus() async {
  final typical = await storeTransactions('typical');
  final dartExport = base64Decode(jsonDecode(
          File('$fixturesRoot/logic/csv_export.json').readAsStringSync())['base64']
      as String);
  const bom = [0xEF, 0xBB, 0xBF];
  List<int> utf16le(String text) {
    final out = <int>[0xFF, 0xFE];
    for (final unit in text.codeUnits) {
      out..add(unit & 0xFF)..add(unit >> 8);
    }
    return out;
  }

  return [
    CsvCase('canonical CRLF export shape',
        b('$h\r\n2026-01-02,Income,Salary,Paycheck,1000.00\r\n2026-01-03,Expense,Food,"Lunch, out",12.50')),
    CsvCase('LF only, trailing LF',
        b('$h\n2026-01-02,Income,Salary,Paycheck,1000.00\n2026-01-03,Expense,Food,Lunch,12.50\n')),
    CsvCase('bare CR only', b('$h\r2026-01-02,Income,Salary,Paycheck,1000.00\r')),
    CsvCase('CRLF header then LF rows',
        b('$h\r\n2026-01-02,Income,A,B,1\n2026-01-03,Income,A,B,2\n')),
    CsvCase('LF header then CRLF rows',
        b('$h\n2026-01-02,Income,A,B,1\r\n2026-01-03,Income,A,B,2\r\n')),
    CsvCase('quoted LF in an LF file',
        b('$h\n2026-01-02,Expense,Food,"a\nb",1\n')),
    CsvCase('quoted LF in a CRLF file',
        b('$h\r\n2026-01-02,Expense,Food,"a\nb",1\r\n')),
    CsvCase('quoted CRLF in an LF-detected file',
        b('$h\n2026-01-02,Expense,Food,"a\r\nb",1\n')),
    CsvCase('doubled quotes',
        b('$h\n2026-01-02,Expense,Food,"say ""hi""",1\n')),
    CsvCase('text after a closing quote swallows the rest',
        b('$h\n2026-01-02,Expense,Food,"abc"def,1\n2026-01-03,Expense,Food,x,2\n')),
    CsvCase('quote inside an unquoted field',
        b('$h\n2026-01-02,Expense,Food,a"b,1\n')),
    CsvCase('space before a quote',
        b('$h\n2026-01-02,Expense,Food, "a,b",1\n')),
    CsvCase('unterminated quote',
        b('$h\n2026-01-02,Expense,Food,"abc,1\n2026-01-03,Expense,Food,x,2\n')),
    CsvCase('lone quote at EOF', b('$h\n2026-01-02,Expense,Food,x,1\n"')),
    CsvCase('blank lines count in row numbers',
        b('$h\n\n2026-01-02,Expense,Food,x,1\n\n\n2026-13-03,Expense,Food,y,2\n2026-01-03,Expense,Food,z,3\n')),
    CsvCase('whitespace-only and comma-only rows',
        b('$h\n   ,  ,  ,  ,  \n,,,,\n\t\n2026-01-03,Expense,Food,y,2\n')),
    CsvCase('column counts',
        b('$h\n2026-01-02,Expense,Food,x\n2026-01-02,Expense,Food,x,1,extra\n2026-01-02,Expense,Food,a, b,1\n2026-01-02\n')),
    CsvCase('header only', b(h)),
    CsvCase('header and a blank line', b('$h\n\n')),
    CsvCase('empty file', b('')),
    CsvCase('wrong header', b('a,b,c,d,e\n1,2,3,4,5\n')),
    CsvCase('blank line before the header',
        b('\r\n$h\r\n2026-01-02,Income,X,Y,1')),
    CsvCase('six-column header', b('$h,Tags\n2026-01-02,Income,X,Y,1,t\n')),
    CsvCase('semicolon separated',
        b('Date;Type;Category;Description;Amount\n2026-01-02;Income;X;Y;1\n')),
    CsvCase('header spaced and cased',
        b(' date , TYPE ,Category,Description,AMOUNT \n2026-01-02,income,X,Y,1\n')),
    CsvCase('header with dotted capital I',
        b('Date,Type,Category,Descrİption,Amount\n2026-01-02,İncome,X,Y,1\n')),
    CsvCase('one BOM', [...bom, ...b('$h\n2026-01-02,Income,X,Y,1\n')]),
    CsvCase('two BOMs', [...bom, ...bom, ...b('$h\n2026-01-02,Income,X,Y,1\n')]),
    CsvCase('three BOMs', [...bom, ...bom, ...bom, ...b('$h\n2026-01-02,Income,X,Y,1\n')]),
    CsvCase('BOM text after a newline',
        b('$h\n﻿2026-01-02,Income,﻿X,Y﻿,1\n')),
    CsvCase('invalid UTF-8', [
      ...b('$h\n2026-01-02,Expense,Food,caf'), 0xE9, ...b(',1\n'),
      ...b('2026-01-03,Expense,Food,'), 0xC0, 0xAF, ...b(',2\n'),
      ...b('2026-01-04,Expense,Food,'), 0xE2, 0x82, ...b(',3\n'),
      ...b('2026-01-05,Expense,Food,'), 0xED, 0xA0, 0x80, ...b(',4\n'),
    ]),
    CsvCase('UTF-16LE with BOM', utf16le('$h\r\n2026-01-02,Income,X,Y,1')),
    CsvCase('dates', b('$h\n${[
      '2026-02-30', '2026-13-05', '2026-02-29', '2024-02-29', '2026-9-1',
      '2026-02-15T10:30', '2026-02-15 10:30', '2026-02-15T23:30Z',
      '2026-02-15T10:00+05:30', '2026-02-15T23:30-08:00', '2026-02-15T00:30+01:00',
      '20260215', '2026-0215', '02/15/2026', '2026/02/15', 'Feb 15 2026',
      '0005-06-07', '0000-01-01', '1600-01-01', '12345-01-01', '-0001-01-01',
      '+002026-02-15', '+12345-01-01', '2026-02-15T24:00', '2026-02-15T10:60',
      ' 2026-03-04 ', ' 2026-05-06', '2026-02-15T10:30:00.123456',
      '2026-02-15T10:30:00,5', '2026-02-15T10:30:00.1234567', '2026-03-08T02:30',
      '2026-11-01T01:30', '2026-09-06', '2026-04-05T02:15', '2026-10-04T02:15',
      '2018-11-04', '2026-02-15t10:30', '2026-02-15T10', '',
    ].map((date) => '"$date",Expense,Food,x,1').join('\n')}\n')),
    CsvCase('types', b('$h\n${[
      'INCOME', 'expense', ' Expense ', 'Transfer', '', 'İncome', 'expense ',
      'Incomes', 'EXPENSE ', '﻿income',
    ].map((type) => '2026-01-01,"$type",X,x,1').join('\n')}\n')),
    CsvCase(
        'categories and new names',
        b('$h\n${[
          '', '   ', ' Food ', 'food', 'Food', 'Café', 'Café', 'a|b',
          'Coffee Shops', 'COFFEE SHOPS', 'Groceries!', 'groceries', ' Pets ',
          '日本', '😀', '---', 'Gift',
        ].map((c) => '2026-01-01,Expense,"$c",x,1').join('\n')}\n'
            '2026-01-01,Income,Gift,x,1\n2026-01-01,Income,Coffee Shops,x,1\n'
            '2026-01-01,Income,other,x,1\n2026-01-01,Income,Side Hustle,x,1\n')),
    CsvCase('amounts', b('$h\n${[
      '\$1,234.50', '"\$1,234.50"', '"1,23"', '-0', '0', '1e3', '1E3', '.5', '5.', 'NaN',
      '0x1A', '"1.234,56"', '-5', '+5', '"\$ 5"', '"\$ 1,000"', '\$', 'Infinity',
      '-Infinity', '1e999', '007', '"1,000,000.123"', '"€5"', '5.005', '3.005',
      '0.125', '"1,000,00"', '1e21', '9' * 30, '', '1e308', '1e308', ' 5',
      '﻿5', '"\$\$5"', '5\$', '"12,345"', '"1,2345"', '",123"', '"123,"',
      '4.9e-324', '1.7976931348623157e308', '0.1', '\$0.30',
    ].map((a) => '2026-01-01,Income,X,x,$a').join('\n')}\n')),
    CsvCase('descriptions', b('$h\n${[
      '007', '1e3', '  padded  ', '', '"😀 emoji"', '"cr\rhere"', '"tab\there"',
      '=SUM(A1)', '"a, b"', ' nbsp ',
    ].map((desc) => '2026-01-01,Expense,Food,$desc,1').join('\n')}\n')),
    CsvCase('dedupe: surplus copy imports',
        b('$h\n2026-04-01,Expense,Eat,Coffee,4.25\n2026-04-01,Expense,Eat,Coffee,4.25\n2026-04-01,expense, Eat ,Coffee ,4.250\n'),
        existing: [('expense', 'Coffee', 4.25, 'Eat', d(2026, 4, 1))]),
    CsvCase('dedupe: key normalisation',
        b('$h\n2026-05-02,EXPENSE,Eating Out,Lunch,12.00\n2026-05-01,Expense,Transport,Fuel,3.00\n'
            '2026-05-01,Expense,Transport,Fuel,3.01\n2026-05-03,Income,Eat,x,1\n'),
        existing: [
          ('expense', 'Lunch ', 12.0, ' Eating Out', d(2026, 5, 2)),
          ('expense', 'Fuel', 3.005, 'Transport', d(2026, 5, 1)),
          ('income', 'x', 1.0, 'Eat', DateTime(2026, 5, 3, 23, 59, 59, 999, 999)),
        ]),
    CsvCase('dedupe: unescaped | collides; NFC and NFD differ',
        b('$h\n2026-04-01,Expense,c|a,b,1\n2026-04-01,Expense,c,café,1\n2026-04-01,Expense,c,café,1\n'),
        existing: [
          ('expense', 'a|b', 1.0, 'c', d(2026, 4, 1)),
          ('expense', 'café', 1.0, 'c', d(2026, 4, 1)),
        ]),
    CsvCase('dedupe: an existing UTC row keys by its UTC day',
        b('$h\n2026-02-15,Expense,Food,z,1\n2026-02-16,Expense,Food,z,1\n2026-02-15T23:30Z,Expense,Food,z,1\n'),
        existing: [
          ('expense', 'z', 1.0, 'Food', DateTime.utc(2026, 2, 15, 23, 30)),
        ]),
    CsvCase('dedupe: huge and tiny amounts',
        b('$h\n2026-01-01,Income,X,big,1e21\n2026-01-01,Income,X,tiny,0.004\n2026-01-01,Income,X,zero,-0\n'),
        existing: [
          ('income', 'big', 1e21, 'X', d(2026, 1, 1)),
          ('income', 'tiny', 0.0, 'X', d(2026, 1, 1)),
          ('income', 'zero', 0.001, 'X', d(2026, 1, 1)),
        ]),
    CsvCase('singular counts',
        b('$h\n2026-01-01,Expense,Food,dup,1\n2026-01-02,Expense,Food,new,2\n2026-01-03,Expense,,bad,3\n'),
        existing: [('expense', 'dup', 1.0, 'Food', d(2026, 1, 1))]),
    CsvCase('typical export into typical', exportOf(typical), store: 'typical'),
    CsvCase('typical export into a fresh install', exportOf(typical)),
    CsvCase('Dart csv_export.json into a fresh install', dartExport),
    CsvCase('Dart csv_export.json into typical', dartExport, store: 'typical'),
  ];
}

/// [rows] (a transactions section) as text, with ids that are not in
/// [known] replaced in order by "<new:N>".
String normalisedTransactions(List rows, Set<String> known) {
  var n = 0;
  return jsonEncode([
    for (final row in rows)
      row is Map && row['id'] is String && !known.contains(row['id'])
          ? {...row, 'id': '<new:${n++}>'}
          : row
  ]);
}

final uuidId = RegExp(
    r'^(income|expense)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// [rows] (a categories section) as text, with new "type-<uuid>" ids
/// replaced by "type-<uuid>".
String normalisedCategories(List rows, Set<String> known) => jsonEncode([
      for (final row in rows)
        row is Map && row['id'] is String && !known.contains(row['id']) &&
                uuidId.hasMatch(row['id'] as String)
            ? {...row, 'id': '${uuidId.firstMatch(row['id'] as String)!.group(1)}-<uuid>'}
            : row
    ]);

Set<String> idsOf(Object? section) => {
      if (section is List)
        for (final row in section)
          if (row is Map && row['id'] is String) row['id'] as String
    };

Map<String, Object?> summaryJson(CsvImportSummary summary) => {
      'drafts': [
        for (final t in summary.transactions)
          [
            t.date.toIso8601String(),
            t.type.name,
            t.category.codeUnits,
            t.description.codeUnits,
            jsonEncode(t.amount),
          ]
      ],
      'duplicateCount': summary.duplicateCount,
      'rowErrors': [for (final e in summary.rowErrors) e.codeUnits],
    };

/// One corpus case through a real store and a real launch.
Future<Map<String, Object?>> runCase(CsvCase c) async {
  final work = await scratch('csv_case');
  final dir = Directory('${work.path}/financial_store');
  var prefs = <String, Object>{};
  if (c.store != null) {
    copyDir(Directory('$fixturesRoot/store/${c.store}/input'), dir);
    prefs = prefsFrom(File('$fixturesRoot/store/${c.store}/prefs.json'));
  }
  SharedPreferences.setMockInitialValues(Map.of(prefs));
  pinClock(launchNow);
  seedUuids(5001);
  await store.resetForTesting(directory: dir);
  if (c.existing.isNotEmpty) {
    await store.replace(FinancialSnapshot(
        schemaVersion: AtomicFinancialStore.schemaVersion,
        revision: 0,
        sections: {
          FinancialSections.transactions: [
            for (final t in c.existing) build(t).toJson()
          ],
        }));
    await store.resetForTesting(directory: dir);
  }
  final app = AppHarness();
  await app.initialize(generate: false);
  final before = await store.read();
  final out = <String, Object?>{
    'name': c.name,
    'bytes': base64Encode(c.bytes),
    'before': jsonEncode(before.sections),
    'prefs': typedPrefs(prefs),
  };

  final content = utf8.decode(c.bytes, allowMalformed: true); // settings_page.dart:138
  out['csvRows'] = rowUnits(csvRows(
      content.isNotEmpty && content.codeUnitAt(0) == 0xFEFF
          ? content.substring(1)
          : content));
  final CsvImportSummary summary;
  try {
    summary = app.transactionModel.parseTransactionsCsv(content);
  } catch (e) {
    out['error'] = e.toString();
    out['failure'] = failureText(e);
    return out;
  }
  out['summary'] = summaryJson(summary);
  out['messages'] = messages(summary);
  if (summary.transactions.isEmpty) return out;

  await app.transactionModel.importTransactions(summary.transactions);
  final afterImport = await store.read();
  final beforeTransactions = before.sections[FinancialSections.transactions];
  expect(jsonEncode(afterImport.sections[FinancialSections.categories]),
      jsonEncode(before.sections[FinancialSections.categories]),
      reason: 'Flutter import does not touch categories');
  // A relaunch: the launch pass materialises the imported category names.
  await store.resetForTesting(directory: dir);
  final relaunched = AppHarness();
  await relaunched.initialize(generate: false);
  final afterRelaunch = await store.read();
  expect(jsonEncode(afterRelaunch.sections[FinancialSections.transactions]),
      jsonEncode(afterImport.sections[FinancialSections.transactions]));
  out['after'] = {
    'revisionDelta': afterImport.revision - before.revision,
    'hasUnsavedChanges': app.transactionModel.hasUnsavedChanges,
    'reloadedCount': relaunched.transactionModel.transactions.length,
    'transactions': normalisedTransactions(
        afterImport.sections[FinancialSections.transactions] as List,
        idsOf(beforeTransactions)),
    'categories': normalisedCategories(
        afterRelaunch.sections[FinancialSections.categories] as List,
        idsOf(before.sections[FinancialSections.categories])),
  };
  return out;
}

/// Seeded random files, as the research's pipeline generator makes them.
List<({String text, List<Tx> existing})> randomFiles(int count) {
  final rnd = Random(2026);
  const header = ['Date', 'Type', 'Category', 'Description', 'Amount'];
  final dates = ['2026-01-02', '2026-02-30', '2026-9-1', '2026-02-15T10:30', '2026-02-15T23:30Z', '20260215', '2026-02-15 10:30', '02/15/2026', '0005-06-07', '12345-01-01', '-0001-01-01', '2026-02-15T24:00', '2026-02-15T10:00+05:30', '2026-02-15T23:30-08:00', ' 2026-03-04 ', '2026-03-04', '2026-03-04', '2026-03-04', '2024-02-29', '2026-02-29', '', 'abc', '2026-02-15T10:30:00.123456', '2026-02-15T10:30:00,5', ' 2026-05-06', '2026-11-01T01:30', '2026-03-08T02:30', '2018-11-04', '2026-09-06', '2026-10-04T02:15'];
  final types = ['Income', 'Expense', 'income', 'EXPENSE', ' Expense ', 'Transfer', '', 'İncome', 'expense ', 'Expense', 'Expense', 'Income'];
  final cats = ['Food', 'Salary', '', '  ', ' Food ', 'food', 'Café', 'Café', 'a|b', 'a', 'Eating Out', 'Food'];
  final descs = ['Lunch', '', '007', '1e3', 'a, b', 'say "hi"', 'line1\nline2', 'cr\rhere', '  padded  ', 'b|c', 'b', 'café', 'café', '\u{1F600}', 'Lunch', 'Lunch'];
  final amounts = ['12.50', '12.5', '1000', '\$1,234.50', '1,234.50', '1,23', '-0', '0', '1e3', '.5', '5.', 'NaN', '0x1A', '1.234,56', '-5', '+5', '\$ 5', '\$ 1,000', '\$', 'Infinity', '1e999', '007', '€5', '5.005', '1,000,00', '1e21', '3.005', '0.125', '9' * 30, '12.50', '12.50', ''];
  String pick(List<String> l) => l[rnd.nextInt(l.length)];
  String enc(String f, {double quoteP = 0.15}) {
    if (f.contains(RegExp('[,"\r\n]')) || rnd.nextDouble() < quoteP) {
      return '"${f.replaceAll('"', '""')}"';
    }
    return f;
  }

  final files = <({String text, List<Tx> existing})>[];
  for (var n = 0; n < count; n++) {
    final eol = rnd.nextInt(10) < 6 ? '\r\n' : '\n';
    final sb = StringBuffer();
    if (rnd.nextInt(20) == 0) sb.write('﻿');
    final hdr = List<String>.from(header);
    if (rnd.nextInt(12) == 0) {
      hdr[rnd.nextInt(5)] = pick(['x', '', 'date ', 'AMOUNT', 'Descrİption']);
    }
    if (rnd.nextInt(30) == 0) hdr.add('Tags');
    sb.write(hdr.map(enc).join(','));
    final rowCount = rnd.nextInt(6);
    for (var r = 0; r < rowCount; r++) {
      sb.write(rnd.nextInt(25) == 0 ? '\n' : eol);
      if (rnd.nextInt(20) == 0) {
        sb.write(rnd.nextBool() ? '' : '  , ,,,');
        continue;
      }
      final cells = [pick(dates), pick(types), pick(cats), pick(descs), pick(amounts)];
      if (rnd.nextInt(25) == 0) cells.removeLast();
      if (rnd.nextInt(25) == 0) cells.add('x');
      sb.write(cells.map(enc).join(','));
    }
    if (rnd.nextInt(3) == 0) sb.write(eol);
    if (rnd.nextInt(40) == 0) sb.write('"');
    final text = sb.toString();
    // Existing rows: some of this file's own valid rows, so dedupe fires.
    final existing = <Tx>[];
    try {
      for (final t in TransactionModel().parseTransactionsCsv(text).transactions) {
        final tx = (t.type.name, t.description, t.amount, t.category, t.date);
        if (rnd.nextInt(3) == 0) existing.add(tx);
        if (rnd.nextInt(8) == 0) existing.add(tx);
      }
    } on FormatException {
      // Not a valid header: nothing to reuse.
    }
    files.add((text: text, existing: existing));
  }
  return files;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parser.json', () {
    if (!writesZoneIndependent) return;
    final inputs = <(String, String)>[
      ('a,b\r\nc,d', 'a,b\r\nc,d'),
      ('trailing CRLF', 'a,b\r\nc,d\r\n'),
      ('trailing LF', 'a,b\nc,d\n'),
      ('empty', ''),
      ('LF only', '\n'),
      ('blank middle line', 'a,b\r\n\r\nc'),
      ('leading blank lines', '\r\n\r\na'),
      ('trailing comma', 'a,b,'),
      ('lone CR at EOF', 'a,b\r'),
      ('CR before CRLF', 'a\r\r\nb'),
      ('CR only', 'a\rb\rc'),
      ('lone quote', '"'),
      ('lone quote after LF', 'a\n"'),
      ('empty quotes after LF', 'a\n""'),
      ('unterminated after LF', 'a\n"x'),
      ('doubled quote', '"a""b",c'),
      ('mid-field quotes', 'a"b"c,d'),
      ('space before quote', ' "abc",d'),
      ('text after closing quote', '"abc"def,ghi\nx,y'),
      ('CR after closing quote', '"a"\rb,c\r\n1,2'),
      ('CRLF header, LF data', 'a,b\r\nc,d\ne,f'),
      ('LF header, CRLF data', 'a,b\nc,d\r\ne,f'),
      ('quoted LF before first CRLF', 'a,"b\nb"\r\nc'),
      ('BOM kept', '﻿a,b'),
      ('two empty quoted', '"",""'),
      ('numbers stay text', '007,1e3,-0,1.50'),
      ('triple quote', '"""'),
      ('quote quote at end', 'a,""'),
      ('quoted then comma', '"a",b\n"c"\n'),
      ('surrogate pairs', '😀,"😀\n",x'),
    ];
    final rnd = Random(40);
    const alphabet = ['a', 'b', ' ', ',', '"', '\r', '\n', '\r\n', 'é', '1', '﻿', '😀'];
    for (var i = 0; i < 3000; i++) {
      final length = rnd.nextInt(41);
      final sb = StringBuffer();
      for (var k = 0; k < length; k++) {
        sb.write(alphabet[rnd.nextInt(alphabet.length)]);
      }
      inputs.add(('random $i', sb.toString()));
    }
    final decodeCases = <Map<String, Object?>>[];
    final rndBytes = Random(41);
    const segments = [
      [0x61], [0x2C], [0x22], [0x0D, 0x0A], [0x0A], [0xEF, 0xBB, 0xBF],
      [0xC3, 0xA9], [0xE2, 0x82, 0xAC], [0xF0, 0x9F, 0x98, 0x80],
      [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80],
      [0xC0, 0xAF], [0xE0, 0x80, 0xAF], [0xE2, 0x82], [0xF0, 0x9F],
      [0xC3], [0xFF], [0xFE], [0x80], [0xBF],
    ];
    for (var i = 0; i < 2000; i++) {
      final bytes = <int>[];
      final count = rndBytes.nextInt(11);
      for (var k = 0; k < count; k++) {
        if (rndBytes.nextInt(6) == 0) {
          bytes.add(rndBytes.nextInt(256));
        } else {
          bytes.addAll(segments[rndBytes.nextInt(segments.length)]);
        }
      }
      decodeCases.add({
        'hex': [for (final x in bytes) x.toRadixString(16).padLeft(2, '0')].join(),
        'units': utf8.decode(bytes, allowMalformed: true).codeUnits,
      });
    }
    writeJson('$fixturesRoot/csvimport/parser.json', {
      'commit': parityCommit,
      'cases': [
        for (final (name, input) in inputs)
          {'name': name, 'input': input.codeUnits, 'rows': rowUnits(csvRows(input))}
      ],
      'decode': decodeCases,
    });
  });

  test('import.json', () async {
    final cases = <Map<String, Object?>>[];
    for (final c in await corpus()) {
      cases.add(await runCase(c));
    }
    final random = <Map<String, Object?>>[];
    pinClock(launchNow);
    seedUuids(6001);
    for (final file in randomFiles(600)) {
      final model = TransactionModel();
      model.transactions = [for (final t in file.existing) build(t)];
      final bytes = utf8.encode(file.text);
      final out = <String, Object?>{
        'bytes': base64Encode(bytes),
        'existing': jsonEncode([for (final t in model.transactions) t.toJson()]),
      };
      try {
        final summary = model.parseTransactionsCsv(utf8.decode(bytes, allowMalformed: true));
        out['summary'] = summaryJson(summary);
        out['messages'] = messages(summary);
      } catch (e) {
        out['error'] = e.toString();
        out['failure'] = failureText(e);
      }
      random.add(out);
    }
    writeJson('${zoneDir()}/import.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'now': iso(launchNow),
      'cases': cases,
      'random': random,
    });
  });

  final pageCases = <Map<String, Object?>>[];
  for (final spec in pageSpecs()) {
    testWidgets('page: ${spec.name}', (tester) async {
      if (!writesZoneIndependent) return;
      quietLayoutErrors();
      tester.view.physicalSize = const Size(1000, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      pageCases.add(await runPage(tester, spec));
    });
  }

  test('write page.json', () {
    if (!writesZoneIndependent) return;
    writeJson('$fixturesRoot/csvimport/page.json', {
      'commit': parityCommit,
      'cases': pageCases,
    });
  });
}

// MARK: - The real Settings page

class PageSpec {
  final String name;

  /// null: the picker is cancelled.
  final List<int>? bytes;
  final List<Tx> existing;
  final bool cancel;

  PageSpec(this.name, this.bytes, {this.existing = const [], this.cancel = false});
}

List<PageSpec> pageSpecs() {
  final existing = <Tx>[
    ('expense', 'Coffee', 4.25, 'Eating Out', d(2026, 4, 1)),
    ('income', 'Paycheck', 1000.0, 'Salary', d(2026, 4, 1)),
  ];
  return [
    PageSpec('two new rows', b('$h\r\n2026-04-02,Expense,Groceries,Milk,3.49\r\n2026-04-03,Income,Salary,Bonus,50')),
    PageSpec('new rows, a duplicate and row errors',
        b('$h\n2026-04-02,Expense,Groceries,Milk,3.49\n2026-04-01,Expense,Eating Out,Coffee,4.25\n'
            '2026-04-03,Expense,Groceries,Bread,2\n2026-04-31,Expense,Groceries,Bad,1\n'
            '2026-04-04,Expense,Coffee Shops,Latte,5\n2026-04-05,Expense,Food,x\n'),
        existing: existing),
    PageSpec('the same file, cancelled',
        b('$h\n2026-04-02,Expense,Groceries,Milk,3.49\n2026-04-01,Expense,Eating Out,Coffee,4.25\n'),
        existing: existing, cancel: true),
    PageSpec('one of each',
        b('$h\n2026-04-01,Expense,Eating Out,Coffee,4.25\n2026-04-02,Expense,Groceries,Milk,3.49\n2026-04-03,Expense,,x,1\n'),
        existing: existing),
    PageSpec('all duplicates',
        b('$h\n2026-04-01,Expense,Eating Out,Coffee,4.25\n2026-04-01,Income,Salary,Paycheck,1000\n'),
        existing: existing),
    PageSpec('header only', b(h), existing: existing),
    PageSpec('only unreadable rows', b('$h\n2026-02-30,Expense,Food,x,1\nnope\n')),
    PageSpec('one unreadable row', b('$h\nnope\n')),
    PageSpec('duplicates and unreadable rows',
        b('$h\n2026-04-01,Expense,Eating Out,Coffee,4.25\n2026-04-01,Income,Salary,Paycheck,1000\nnope\n'),
        existing: existing),
    PageSpec('one duplicate and one unreadable row',
        b('$h\n2026-04-01,Expense,Eating Out,Coffee,4.25\nnope\n'), existing: existing),
    PageSpec('wrong header', b('When,Kind,Bucket,Note,Value\n2026-04-01,Expense,x,y,1\n')),
    PageSpec('empty file', const []),
    PageSpec('picker cancelled', null),
    PageSpec('BOM and one row', [0xEF, 0xBB, 0xBF, ...b('$h\r\n2026-04-02,Income,Side Hustle,Gig,80')]),
  ];
}

class FakeFilePicker extends FilePickerPlatform {
  List<int>? bytes;
  FileType? type;
  List<String>? allowedExtensions;
  bool? withData;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    this.type = type;
    this.allowedExtensions = allowedExtensions;
    this.withData = withData;
    final bytes = this.bytes;
    if (bytes == null) return null;
    return FilePickerResult([
      PlatformFile(
          name: 'transactions.csv',
          size: bytes.length,
          bytes: Uint8List.fromList(bytes)),
    ]);
  }
}

/// One import through the real page over a fresh store holding [spec]'s
/// existing rows: the dialog, the SnackBar, whether the store was written.
Future<Map<String, Object?>> runPage(WidgetTester tester, PageSpec spec) async {
  late AppHarness app;
  late FinancialSnapshot before;
  CsvImportSummary? summary;
  Object? error;
  await tester.runAsync(() async {
    final work = await scratch('csv_page');
    final dir = Directory('${work.path}/financial_store');
    SharedPreferences.setMockInitialValues({});
    pinClock(launchNow);
    seedUuids(7001);
    await store.resetForTesting(directory: dir);
    if (spec.existing.isNotEmpty) {
      await store.replace(FinancialSnapshot(
          schemaVersion: AtomicFinancialStore.schemaVersion,
          revision: 0,
          sections: {
            FinancialSections.transactions: [
              for (final t in spec.existing) build(t).toJson()
            ],
          }));
      await store.resetForTesting(directory: dir);
    }
    app = AppHarness();
    await app.initialize(generate: false);
    before = await store.read();
    if (spec.bytes != null) {
      try {
        summary = app.transactionModel
            .parseTransactionsCsv(utf8.decode(spec.bytes!, allowMalformed: true));
      } catch (e) {
        error = e;
      }
    }
  });
  final picker = FakeFilePicker()..bytes = spec.bytes;
  FilePickerPlatform.instance = picker;
  await pumpSettings(tester, app);
  final out = <String, Object?>{
    'name': spec.name,
    'bytes': spec.bytes == null ? null : base64Encode(spec.bytes!),
    'existing': jsonEncode(before.sections[FinancialSections.transactions] ?? []),
    if (spec.cancel) 'cancel': true,
  };
  await tester.tap(find.text('Import from CSV'));
  bool idle() =>
      find.byType(AlertDialog).evaluate().isEmpty &&
      find.byType(CircularProgressIndicator).evaluate().isEmpty;
  // The fake picker answers during the tap, before the busy row is built:
  // let the flow run a few frames before "idle" can mean "finished".
  for (var i = 0; i < 3; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  await pumpUntil(
      tester,
      () =>
          find.byType(AlertDialog).evaluate().isNotEmpty ||
          find.byType(SnackBar).evaluate().isNotEmpty ||
          (spec.bytes == null && picker.type != null && idle()));
  out['picker'] = {
    'type': picker.type?.name,
    'allowedExtensions': picker.allowedExtensions,
    'withData': picker.withData,
  };
  final dialogs = find.byType(AlertDialog);
  Map<String, Object?>? dialog;
  if (dialogs.evaluate().isNotEmpty) {
    final widget = tester.widget<AlertDialog>(dialogs);
    dialog = {
      'title': (widget.title as Text).data,
      'content': (widget.content as Text?)?.data,
      'buttons': [
        for (final element in find
            .descendant(of: dialogs, matching: find.byType(TextButton))
            .evaluate())
          ((element.widget as TextButton).child as Text).data
      ],
    };
    await tester.tap(find.text(spec.cancel ? 'Cancel' : 'Import'));
    await pumpUntil(
        tester,
        () =>
            find.byType(SnackBar).evaluate().isNotEmpty ||
            (spec.cancel && idle()));
  }
  out['dialog'] = dialog;
  final bars = find.byType(SnackBar);
  Map<String, Object?>? snackbar;
  if (bars.evaluate().isNotEmpty) {
    final bar = tester.widget<SnackBar>(bars.first);
    final color = bar.backgroundColor;
    snackbar = {
      'text': (bar.content as Text).data,
      'color': color == null
          ? 'default'
          : color == AppColors.expense
              ? 'expense'
              : color == AppColors.income
                  ? 'income'
                  : color.toString(),
    };
  }
  out['snackbar'] = snackbar;
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async {
    final after = await store.read();
    out['storeWritten'] = after.revision != before.revision;
  });

  // The copy the corpus relies on (`messages`) is what the page shows.
  if (spec.bytes != null) {
    if (error != null) {
      expect(dialog, isNull);
      expect(snackbar?['text'], failureText(error!));
      expect(snackbar?['color'], 'expense');
    } else {
      final m = messages(summary!);
      final empty = m['empty'] as Map<String, Object?>?;
      if (empty != null) {
        expect(dialog, isNull);
        expect(snackbar?['text'], empty['text']);
        expect(snackbar?['color'], empty['red'] == true ? 'expense' : 'default');
      } else {
        expect(dialog?['title'], m['confirmTitle']);
        expect(dialog?['content'], m['confirmContent']);
        expect(dialog?['buttons'], ['Cancel', 'Import']);
        if (spec.cancel) {
          expect(snackbar, isNull);
        } else {
          expect(snackbar?['text'], m['success']);
          expect(snackbar?['color'], 'income');
        }
      }
    }
  } else {
    expect(dialog, isNull);
    expect(snackbar, isNull);
  }
  return out;
}

Future<void> pumpSettings(WidgetTester tester, AppHarness app) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: ThemeProvider()),
        ChangeNotifierProvider<TransactionModel>.value(
            value: app.transactionModel),
        ChangeNotifierProvider<RecurringTransactionModel>.value(
            value: app.recurringModel),
        ChangeNotifierProvider<AppSettingsProvider>.value(
            value: app.appSettings),
        ChangeNotifierProvider<CategoryProvider>.value(
            value: app.categoryProvider),
        ChangeNotifierProvider<CategorizationProvider>.value(
            value: app.categorizationProvider),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
  // ThemeProvider and the version load asynchronously.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}
