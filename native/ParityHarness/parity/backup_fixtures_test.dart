// Emits native/Fixtures/backup/ : the Backup stream's Dart oracle.
//
// Zone independent (written from the New York run):
//   dart_sort.json      Dart's `List.sort` on random lists with many ties, as
//                       the permutation it produces (Swift `DartSort`).
//   indent_vectors.json `JsonEncoder.withIndent('  ')` of hand-picked and
//                       random values.
// Per zone (tz/<zone>/):
//   encode.json         `encodeBackup` of what `_exportBackup` reads from the
//                       models, for the store fixtures and hand-made stores.
//   export_flow.json    the real SettingsPage `_exportBackup` (file name,
//                       share subject, snackbar, bytes) through fakes.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:budget_app/app_settings_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:budget_app/backup.dart';
import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/category_provider.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/settings_page.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixture_runner.dart';
import 'harness_support.dart';

/// Zone-independent files are written once, from the first zone run.
final bool writesZoneIndependent = parityTz == 'America/New_York';

const appVersion = '3.4.0';

/// The sections a restore writes, in `FinancialSections` order.
const storeSections = [
  FinancialSections.transactions,
  FinancialSections.netWorthEntries,
  FinancialSections.selectedNetWorthMonth,
  FinancialSections.categoryBudgetLimits,
  FinancialSections.savingsGoals,
  FinancialSections.recurringTransactions,
  FinancialSections.categories,
  FinancialSections.transactionTags,
  FinancialSections.categorizationRules,
  FinancialSections.appSettings,
];

/// `exportedAt` for every encode case (local, with microseconds).
final exportedAt = DateTime(2026, 9, 29, 14, 3, 7, 123, 456);

String zoneDir() => '$fixturesRoot/backup/tz/${parityTz.replaceAll('/', '_')}';

/// Text, or checksum and length above 200 kB (like `sectionsJson`).
Object expectedText(String text) {
  final bytes = utf8.encode(text);
  if (bytes.length <= 200000) return text;
  return {'fnv': fnv(bytes), 'length': bytes.length};
}

/// A store loaded like a launch (`_initializeApp` without the generator):
/// from a store fixture's input files, or from hand-made sections.
Future<AppHarness> loadStore(
    {Directory? input,
    Map<String, dynamic>? sections,
    Map<String, Object> prefs = const {}}) async {
  final work = await scratch('backup_store');
  final dir = Directory('${work.path}/financial_store');
  if (input != null && input.existsSync()) copyDir(input, dir);
  SharedPreferences.setMockInitialValues(Map.of(prefs));
  pinClock(launchNow);
  seedUuids(2001);
  await store.resetForTesting(directory: dir);
  if (sections != null) {
    await store.replace(
        FinancialSnapshot(schemaVersion: 2, revision: 0, sections: sections));
    await store.resetForTesting(directory: dir);
  }
  lastLoadedSections = (await store.read()).sections;
  final app = AppHarness();
  await app.initialize(generate: false);
  return app;
}

/// The sections `loadStore` found before the launch wrote anything.
Map<String, dynamic> lastLoadedSections = {};

/// Hand-made stores for the export: every awkward value the typed fields
/// must reproduce.
class CustomStore {
  final String name;
  final Map<String, dynamic> sections;
  final Map<String, Object> prefs;
  final String? themeMode;
  const CustomStore(this.name, this.sections,
      {this.prefs = const {}, this.themeMode = 'system'});
}

Map<String, dynamic> tx(String id, String description, Object amount,
        {String type = 'expense',
        String category = 'General',
        String date = '2026-09-01T00:00:00.000',
        Object? tagIds = const <String>[],
        Map<String, dynamic> extra = const {}}) =>
    {
      'id': id,
      'type': type,
      'description': description,
      'amount': amount,
      'category': category,
      'date': date,
      'recurringTemplateId': null,
      'tagIds': tagIds,
      'createdAt': '2026-09-01T08:00:00.000',
      'updatedAt': '2026-09-01T08:00:00.000',
      ...extra,
    };

Map<String, dynamic> rule(String id, int priority,
        {String pattern = 'x', List<String> tagIds = const []}) =>
    {
      'id': id,
      'merchantPattern': pattern,
      'matchType': 'contains',
      'transactionType': null,
      'minimumAmount': null,
      'maximumAmount': null,
      'category': 'General',
      'tagIds': tagIds,
      'priority': priority,
      'isEnabled': true,
    };

List<CustomStore> customStores() {
  final tiedRules = [
    for (var i = 0; i < 40; i++) rule('tie-$i', (i * 7) % 3, pattern: 'p$i')
  ];
  return [
    CustomStore('strings', {
      'transactions': [
        tx('s1', 'Café "x" 😀 \\ /    \u007f', 12.5,
            tagIds: ['tag-a']),
        tx('s2', 'bad \uD83D surrogate and \uDC00 trail', 1.0,
            category: 'Café'),
        tx('s3', 'controls \u0000\u0001\b\t\n\u000b\f\r\u001f', 2.0,
            category: 'Café'),
        tx('s4', '', 3.0, tagIds: ['tag-a', 7, null, 'tag-\uD800']),
        tx('s\uD800', 'lone surrogate id', 4.0),
      ],
      'transactionTags': [
        {'id': 'tag-a', 'name': '  Padded ﻿', 'colorToken': 'cyan'},
        {'id': 'tag-\uD800', 'name': '\uD800 lone', 'colorToken': 'accent'},
        {'id': 'tag-c', 'name': null, 'colorToken': null},
      ],
      'categorizationRules': [
        {
          ...rule('r1', 1, pattern: '  Star\uD83Dbucks \t'),
          'matchType': 'weird',
          'transactionType': 'INCOME',
          'minimumAmount': 5,
          'maximumAmount': 20.5,
          'tagIds': ['tag-a', 3],
          'category': null,
        },
        {'id': 'r2', 'priority': 2.9},
      ],
    }),
    CustomStore('dates', {
      'transactions': [
        tx('d1', 'utc', 1.0, date: '2026-03-06T00:00:00.000Z'),
        tx('d2', 'offset', 1.0, date: '2026-03-06T10:00:00+05:30'),
        tx('d3', 'date only', 1.0, date: '2026-03-05'),
        tx('d4', 'micros', 1.0, date: '2026-03-05T10:30:01.002003'),
        tx('d5', 'ny gap', 1.0, date: '2026-03-08T02:30:00'),
        tx('d6', 'ny overlap', 1.0, date: '2026-11-01T01:30:00'),
        tx('d7', 'lord howe gap', 1.0, date: '2026-10-04T02:15:00'),
        tx('d8', 'lord howe overlap', 1.0, date: '2026-04-05T01:45:00'),
        {
          'id': 'd9',
          'type': 'income',
          'description': 'no stamps',
          'amount': 5,
          'category': 'Salary',
          'date': '2026-01-31T23:59:59.999999',
        },
        {
          ...tx('d10', 'bad stamps', 1.0),
          'createdAt': 12,
          'updatedAt': 'nope',
        },
        tx('d11', 'far year', 1.0, date: '+012345-01-01T00:00:00.000'),
      ],
      'netWorthEntries': [
        {
          'id': 'nw1',
          'name': 'Legacy',
          'type': 'other',
          'createdAt': '2025-12-01',
          'snapshots': [
            {'monthKey': '2025-12', 'amount': 800},
            {
              'monthKey': '2026-01',
              'updatedAt': '2026-01-15T09:30:00.000Z',
              'amount': 900.5
            },
            {'recordedAt': '2026-02-28T23:59:59.999', 'amount': -0.0},
          ],
        },
        {
          'id': 'nw2',
          'name': 'Empty',
          'type': 'liability',
          'createdAt': '2026-01-01T00:00:00.000',
        },
      ],
      'savingsGoals': [
        {
          'id': 'g1',
          'name': '  Trip ',
          'targetAmount': '1500.50',
          'currentAmount': -3,
          'targetDate': '2026-12-24T18:00:00.000Z',
          'createdAt': '2026-01-01',
          'completedAt': '2026-06-01T00:00:00.000',
        },
        {
          'id': 'g2',
          'name': '',
          'targetAmount': 100,
          'currentAmount': 100,
          'targetDate': '',
          'createdAt': 5,
        },
      ],
      'recurringTransactions': [
        {
          'id': 'rt1',
          'type': 'expense',
          'description': 'Rent',
          'amount': 1500.0,
          'category': 'Housing',
          'pattern': 'monthly',
          'startDate': '2026-01-31',
          'nextOccurrence': '2026-10-31T00:00:00.000',
          'dayOfMonth': 31,
          'extra': [1],
        },
        {
          'id': 'rt2',
          'type': 'income',
          'description': 'Pay',
          'amount': 800.5,
          'category': 'Salary',
          'pattern': 'biweekly',
          'startDate': '2026-09-01T09:00:00.000Z',
          'nextOccurrence': '2026-10-13T09:00:00.000Z',
          'dayOfWeek': 2,
          'isActive': false,
        },
      ],
    }),
    // Midnight DST: America/Santiago has no 2026-09-06 00:00-00:59 (Dart moves
    // it to 01:xx) and repeats 2026-04-04 23:00-23:59; Asia/Beirut has no
    // 2026-03-29 00:00-00:59 and repeats 2026-10-24 23:00-23:59. Elsewhere
    // these are ordinary times, so a restore then export is the identity.
    CustomStore('dst_dates', {
      'transactions': [
        tx('x1', 'santiago before gap', 1.0, date: '2026-09-05T23:59:59.999'),
        tx('x2', 'santiago gap midnight', 2.0, date: '2026-09-06T00:00:00'),
        tx('x3', 'santiago gap half past', 3.0, date: '2026-09-06T00:30:00.000'),
        tx('x4', 'santiago gap last ms', 4.0, date: '2026-09-06T00:59:59.999'),
        tx('x5', 'santiago after gap', 5.0, date: '2026-09-06T01:00:00.000'),
        tx('x6', 'santiago fold', 6.0, date: '2026-04-04T23:30:00'),
        tx('x7', 'santiago fold start', 7.0, date: '2026-04-04T23:00:00.000'),
        tx('x8', 'santiago fold end', 8.0, date: '2026-04-04T23:59:59.999'),
        tx('x9', 'santiago after fold', 9.0, date: '2026-04-05T00:00:00.000'),
        tx('x10', 'beirut gap', 10.0, date: '2026-03-29T00:30:00'),
        tx('x11', 'beirut gap midnight', 11.0, date: '2026-03-29T00:00:00.000'),
        tx('x12', 'beirut fold', 12.0, date: '2026-10-24T23:30:00.000'),
        tx('x13', 'beirut after fold', 13.0, date: '2026-10-25T00:00:00.000'),
        tx('x14', 'micros in gap', 14.0, date: '2026-09-06T00:30:00.123456'),
      ],
      'netWorthEntries': [
        {
          'id': 'xnw1',
          'name': 'Fold account',
          'type': 'asset',
          'createdAt': '2026-04-04T23:30:00.000',
          'snapshots': [
            {
              'monthKey': '2026-04',
              'recordedAt': '2026-04-04T23:30:00.000',
              'updatedAt': '2026-04-04T23:30:00.000',
              'amount': 100.5,
            },
            {
              'monthKey': '2026-09',
              'recordedAt': '2026-09-06T00:15:00.000',
              'updatedAt': '2026-09-06T00:15:00.000',
              'amount': 120.25,
            },
            {'recordedAt': '2026-03-29T00:30:00.000', 'amount': 90},
          ],
        },
      ],
      'savingsGoals': [
        {
          'id': 'xg1',
          'name': 'Gap target',
          'targetAmount': 500.0,
          'currentAmount': 50.0,
          'targetDate': '2026-09-06T00:00:00.000',
          'createdAt': '2026-04-04T23:30:00.000',
        },
        {
          'id': 'xg2',
          'name': 'Fold completed',
          'targetAmount': 100.0,
          'currentAmount': 100.0,
          'targetDate': '2026-10-24T23:30:00.000',
          'createdAt': '2026-03-29T00:00:00.000',
          'completedAt': '2026-04-04T23:45:00.000',
        },
      ],
      'recurringTransactions': [
        {
          'id': 'xrt1',
          'type': 'expense',
          'description': 'Weekly over the Santiago gap',
          'amount': 12.5,
          'category': 'General',
          'pattern': 'weekly',
          'startDate': '2026-08-30T00:00:00.000',
          'nextOccurrence': '2026-09-06T00:00:00.000',
          'dayOfWeek': 7,
        },
        {
          'id': 'xrt2',
          'type': 'income',
          'description': 'Monthly in the Beirut gap',
          'amount': 99.0,
          'category': 'Salary',
          'pattern': 'monthly',
          'startDate': '2026-01-29T00:00:00.000',
          'nextOccurrence': '2026-03-29T00:30:00.000',
          'dayOfMonth': 29,
        },
        {
          'id': 'xrt3',
          'type': 'expense',
          'description': 'Fold hour cursor',
          'amount': 3.0,
          'category': 'General',
          'pattern': 'weekly',
          'startDate': '2026-03-28T23:30:00.000',
          'nextOccurrence': '2026-04-04T23:30:00.000',
          'dayOfWeek': 6,
          'isActive': false,
        },
      ],
    }),
    CustomStore('numbers', {
      'transactions': [
        tx('n1', 'int', 12),
        tx('n2', 'neg zero', -0.0),
        tx('n3', 'big', 1e21),
        tx('n4', 'tiny', 1e-7),
        tx('n5', 'denormal', 5e-324),
        tx('n6', 'sum', 0.1 + 0.2),
        tx('n7', 'huge', 1.5e300),
        tx('n8', 'negative', -12.5),
        tx('n9', 'int64 max', 9223372036854775807),
        tx('n10', 'int zero', 0),
      ],
      'categoryBudgetLimits': {
        'Groceries': 250,
        'Zero': 0,
        'Negative': -5.0,
        'Café': 10,
        'Café': 20.25,
        'Big': 1e21,
        'Tiny': 5e-324,
      },
    }),
    CustomStore('rules_ties_small', {
      'categorizationRules': [
        for (var i = 0; i < 12; i++) rule('small-$i', i % 3, pattern: 'p$i')
      ],
    }),
    CustomStore('rules_ties_40', {
      'transactionTags': [
        {'id': 't1', 'name': 'One', 'colorToken': 'accent'}
      ],
      'categorizationRules': tiedRules,
    }),
    CustomStore(
        'settings_section',
        {
          'appSettings': {
            'baseCurrencyCode': ' eur ',
            'localeOverride': 'de_DE',
            'appLockEnabled': true,
            'autoLockTimeoutSeconds': 900,
            'hideBalances': true,
            'future': 1,
          },
        },
        themeMode: 'dark'),
    CustomStore(
        'settings_prefs_only',
        {
          'appSettings': {'autoLockTimeoutSeconds': 29.9},
        },
        prefs: {
          'base_currency_code': 'usd',
          'locale_override': '',
          'app_lock_enabled': true,
          'hide_balances': false,
        },
        themeMode: 'light'),
    CustomStore('theme_null', {}, themeMode: null),
    CustomStore(
        'blank_ids',
        {
          'transactions': [
            tx('', 'empty id', 1.0),
            tx('   ', 'spaces id', 1.0),
            tx('﻿', 'bom id', 1.0),
            {...tx('x', 'no id', 1.0)}..remove('id'),
            tx('dup', 'first dup', 1.0),
            tx('dup', 'second dup', 2.0),
          ],
          'transactionTags': [
            {'name': 'No id'},
          ],
          'categorizationRules': [
            {'merchantPattern': 'no id', 'category': 'Groceries'},
          ],
          'savingsGoals': [
            {'name': 'No id', 'targetAmount': 10.0},
          ],
          'recurringTransactions': [
            {
              'type': 'expense',
              'description': 'no id',
              'amount': 5.0,
              'category': 'General',
              'pattern': 'weekly',
              'startDate': '2026-12-01T00:00:00.000',
              'nextOccurrence': '2026-12-01T00:00:00.000',
            },
          ],
        }),
    CustomStore('legacy_categories', {
      'categories': [
        {
          'id': 'expense-general',
          'type': 'expense',
          'name': 'General',
          'sortOrder': 5
        },
        {'id': 'income-salary', 'type': 'income', 'name': 'Salary'},
        {
          'id': 'expense-old',
          'type': 'expense',
          'name': 'Old',
          'isArchived': true,
          'sortOrder': 5,
          'iconIdentifier': 'nope',
          'colorToken': 'teal',
          'isBuiltIn': true,
          'future': true,
        },
      ],
      'transactions': [
        tx('l1', 'a', 1.0, category: '  Brand New '),
        tx('l2', 'b', 1.0, category: 'old'),
        tx('l3', 'c', 1.0, type: 'income', category: 'Bonus'),
      ],
      'recurringTransactions': [
        {
          'id': 'lr',
          'type': 'expense',
          'description': 'x',
          'amount': 5.0,
          'category': 'From Template',
          'pattern': 'monthly',
          'startDate': '2026-12-01T00:00:00.000',
          'nextOccurrence': '2026-12-01T00:00:00.000',
          'dayOfMonth': 1,
        },
      ],
      'categoryBudgetLimits': {'Budget Only': 50, 'Nope': 0},
    }),
    CustomStore('unreadable_transaction', {
      'transactions': [
        tx('u1', 'readable', 1.0),
        {'id': 'u2', 'type': 'expense', 'amount': 1.0},
        tx('u3', 'readable too', 2.0),
      ],
    }),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dart_sort.json', () {
    if (!writesZoneIndependent) return;
    final random = Random(20260929);
    final lengths = [
      for (var n = 0; n <= 80; n++) n,
      100, 128, 200, 333, 500, 1000, 2000,
    ];
    final cases = <Map<String, Object?>>[];
    int? firstUnstable;
    for (final n in lengths) {
      for (final range in [1, 2, 3, 7, 40, 1 << 30]) {
        final keys = List<int>.generate(n, (_) => random.nextInt(range));
        final ascending = List<int>.generate(n, (i) => i)
          ..sort((a, b) => keys[a].compareTo(keys[b]));
        final descending = List<int>.generate(n, (i) => i)
          ..sort((a, b) => keys[b].compareTo(keys[a]));
        final stable = List<int>.generate(n, (i) => i)
          ..sort((a, b) {
            final byKey = keys[a].compareTo(keys[b]);
            return byKey != 0 ? byKey : a.compareTo(b);
          });
        var isStable = true;
        for (var i = 0; i < n; i++) {
          if (stable[i] != ascending[i]) isStable = false;
        }
        if (!isStable && (firstUnstable == null || n < firstUnstable)) {
          firstUnstable = n;
        }
        cases.add({
          'keys': keys,
          'ascending': ascending,
          'descending': descending,
        });
      }
    }
    final file = File('$fixturesRoot/backup/dart_sort.json')
      ..parent.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode({
          'commit': parityCommit,
          'firstUnstableLength': firstUnstable,
          'cases': cases,
        })}\n');
  });

  test('indent_vectors.json', () {
    if (!writesZoneIndependent) return;
    const indent = JsonEncoder.withIndent('  ');
    final inputs = <String>[
      '[]', '{}', '"s"', '""', '1', '-0', '-0.0', '0', '2.0', '1e21', '1E21',
      '1e-7', '5e-324', '1.7976931348623157e308', '12345678901234567890',
      '9223372036854775807', '-9223372036854775808', '0.1e1', '10e-1', 'null',
      'true', 'false', '[1]', '[[]]', '[{}]', '{"a":{}}', '{"a":[]}',
      '[[],{},[[]],[{}],{"a":[]}]',
      '{"a":[],"b":{},"c":[[],{}],"d":[1,2.0,-0.0,1e21,1e-7,null,true],'
          '"e":{"x":{},"y":[{}]},"z":"é\u{1F600}\\u0001\\u007f /\\"\\\\\\n\\t",'
          '"n":null}',
      r'"\u0000\u0001\u0007\b\t\n\u000b\f\r\u000e\u001f \u007f\u0080 "',
      r'"  ﻿￿\/\\\""',
      r'"\ud800"', r'"\udc00x"', r'"😀"', r'"a\ud83d"',
      r'"\udc00\ud800"', r'["\ud800",{"\udfff":"😀\ud83d"}]',
      '{"a":1,"a":2}', '{"b":1,"a":2,"b":{"c":[]}}',
      r'{"Café":1,"Café":2,"é":3}',
      '[[[[[[[[[[{"deep":[1,[2,[3,{}]]]}]]]]]]]]]]',
      '  {"spaced" : [ 1 , 2 ] }\n',
      '{"transactions":[{"id":"t1","amount":12.5,"tagIds":["a","b"],'
          '"recurringTemplateId":null}],"categoryBudgetLimits":{}}',
    ];
    final random = Random(424242);
    String randomString() {
      final units = <int>[];
      final length = random.nextInt(8);
      for (var i = 0; i < length; i++) {
        switch (random.nextInt(6)) {
          case 0:
            units.add(random.nextInt(0x20));
          case 1:
            units.add(0xD800 + random.nextInt(0x800));
          case 2:
            units.add(0x20 + random.nextInt(0x60));
          case 3:
            units.add(0x80 + random.nextInt(0x780));
          case 4:
            units.addAll('\u{1F600}'.codeUnits);
          default:
            units.add(0x2000 + random.nextInt(0xDD00 - 0x2000));
        }
      }
      return String.fromCharCodes(units);
    }

    Object? randomValue(int depth) {
      final kind = random.nextInt(depth > 3 ? 6 : 8);
      switch (kind) {
        case 0:
          return null;
        case 1:
          return random.nextBool();
        case 2:
          return random.nextInt(1 << 32) - (1 << 31);
        case 3:
          final choices = [
            0.0, -0.0, 1.5, 100.0, 1e21, 1e-7, 5e-324, 0.1 + 0.2,
            random.nextDouble() * pow(10, random.nextInt(40) - 20),
          ];
          return choices[random.nextInt(choices.length)];
        case 4:
        case 5:
          return randomString();
        case 6:
          return [
            for (var i = random.nextInt(4); i > 0; i--) randomValue(depth + 1)
          ];
        default:
          return {
            for (var i = random.nextInt(4); i > 0; i--)
              randomString(): randomValue(depth + 1)
          };
      }
    }

    for (var i = 0; i < 200; i++) {
      inputs.add(jsonEncode(randomValue(0)));
    }
    writeJson('$fixturesRoot/backup/indent_vectors.json', {
      'commit': parityCommit,
      'cases': [
        for (final input in inputs)
          {'json': input, 'indented': indent.convert(jsonDecode(input))}
      ],
    });
  });

  test('encode.json', () async {
    final cases = <Map<String, Object?>>[];
    for (final name in [
      'fresh_install',
      'typical',
      'old_schema',
      'unknown_data',
      'large_10k'
    ]) {
      final input = Directory('$fixturesRoot/store/$name/input');
      final prefs = prefsFrom(File('$fixturesRoot/store/$name/prefs.json'));
      for (final theme in name == 'typical'
          ? ['system', 'dark', 'light']
          : ['system']) {
        final app = await loadStore(input: input, prefs: prefs);
        final text = encodeBackup(exportData(app, themeFrom(theme)),
            appVersion: appVersion, exportedAt: exportedAt);
        cases.add({
          'name': '$name/$theme',
          'store': name,
          'themeMode': theme,
          'generatedIds': generatedIds(text, lastLoadedSections),
          'expected': expectedText(text),
        });
      }
    }
    for (final custom in customStores()) {
      final app = await loadStore(sections: custom.sections, prefs: custom.prefs);
      final text = encodeBackup(exportData(app, themeFrom(custom.themeMode)),
          appVersion: appVersion, exportedAt: exportedAt);
      cases.add({
        'name': custom.name,
        'sections': jsonEncode(custom.sections),
        'prefs': typedPrefs(custom.prefs),
        'themeMode': custom.themeMode,
        'generatedIds': generatedIds(text, lastLoadedSections),
        'expected': expectedText(text),
      });
    }
    final fileNames = [
      for (final date in [
        exportedAt,
        DateTime(2026, 1, 2, 3, 4, 5),
        DateTime(999, 12, 31, 23, 59, 59, 999, 999),
        DateTime(2026, 3, 8, 3, 0),
      ])
        {
          'date': iso(date),
          'fileName':
              'budgie_backup_${DateFormat('yyyyMMdd_HHmmss').format(date)}.json',
        }
    ];
    writeJson('${zoneDir()}/encode.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'launchNow': iso(launchNow),
      'appVersion': appVersion,
      'exportedAt': iso(exportedAt),
      'fileNames': fileNames,
      'cases': cases,
    });
  });

  testWidgets('export_flow.json: the real page exports what encodeBackup gives',
      (tester) async {
    quietLayoutErrors();
    tester.view.physicalSize = const Size(1000, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late AppHarness app;
    late Directory temp;
    await tester.runAsync(() async {
      app = await loadStore(
          input: Directory('$fixturesRoot/store/typical/input'));
      temp = await Directory.systemTemp.createTemp('backup_export_tmp');
    });
    final share = FakeShare();
    SharePlatform.instance = share;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    PackageInfo.setMockInitialValues(
        appName: 'Budgie',
        packageName: 'com.example.budget',
        version: appVersion,
        buildNumber: '1',
        buildSignature: '');
    final exportNow = DateTime(2026, 9, 28, 9, 15, 30, 250, 125);
    pinClock(exportNow);
    final theme = ThemeProvider();
    await pumpSettings(tester, app, theme);
    await tester.tap(find.text('Export backup'));
    await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    final snackbar = snackbarText(tester);
    final file = File(share.files.single.path);
    final bytes = await tester.runAsync(() => file.readAsBytes());
    final expected = encodeBackup(exportData(app, theme.themeMode),
        appVersion: appVersion, exportedAt: exportNow);
    expect(utf8.decode(bytes!), expected);
    writeJson('${zoneDir()}/export_flow.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'now': iso(exportNow),
      'fileName': file.uri.pathSegments.last,
      'subject': share.subject,
      'fileCount': share.files.length,
      'snackbar': snackbar,
      'themeMode': theme.themeMode.name,
      'bytes': expectedText(utf8.decode(bytes)),
    });
    await tester.pumpWidget(const SizedBox());
  });

  // Backup files: Flutter exports of fixture stores, and variants.
  final files = <String, List<int>>{};
  setUpAll(() async {
    Future<String> exportOf(AppHarness app, String theme) async =>
        encodeBackup(exportData(app, themeFrom(theme)),
            appVersion: appVersion, exportedAt: exportedAt);
    final typical = await exportOf(
        await loadStore(input: Directory('$fixturesRoot/store/typical/input')),
        'dark');
    final fresh = await exportOf(await loadStore(), 'light');
    final dates = await exportOf(
        await loadStore(
            sections: customStores().firstWhere((c) => c.name == 'dates').sections),
        'system');
    final dstDates = await exportOf(
        await loadStore(
            sections: customStores()
                .firstWhere((c) => c.name == 'dst_dates')
                .sections),
        'system');
    final strings = await exportOf(
        await loadStore(
            sections:
                customStores().firstWhere((c) => c.name == 'strings').sections),
        'system');
    final ties = await exportOf(
        await loadStore(
            sections: customStores()
                .firstWhere((c) => c.name == 'rules_ties_40')
                .sections),
        'system');
    files['typical export'] = utf8.encode(typical);
    files['fresh export'] = utf8.encode(fresh);
    files['dates export'] = utf8.encode(dates);
    files['dst dates export'] = utf8.encode(dstDates);
    files['strings export'] = utf8.encode(strings);
    files['rules ties export'] = utf8.encode(ties);
    // Schema 1: the six keys of the first backup format (commit 427de7e).
    final v1 = jsonDecode(dates) as Map<String, dynamic>;
    v1['schemaVersion'] = 1;
    final v1Data = v1['data'] as Map<String, dynamic>;
    v1Data.removeWhere((key, _) => !const [
          'transactions',
          'netWorthEntries',
          'categoryBudgetLimits',
          'savingsGoals',
          'recurringTransactions',
          'themeMode'
        ].contains(key));
    files['v1 dates'] = utf8.encode(const JsonEncoder.withIndent('  ').convert(v1));
    files.addAll(decodeCorpus());
    files.addAll(restoreFiles());
  });

  test('decode.json', () async {
    pinClock(launchNow);
    seedUuids(3001);
    final cases = <Map<String, Object?>>[];
    for (final entry in files.entries) {
      final name = entry.key;
      final bytes = entry.value;
      final result = <String, Object?>{};
      try {
        final data = decodeBackup(utf8.decode(bytes, allowMalformed: true));
        String list(List<dynamic> items) =>
            jsonEncode(items.map((item) => item.toJson()).toList());
        final decoded = <String, Object?>{
          'counts': [
            data.transactions.length,
            data.netWorthEntries.length,
            data.categoryBudgetLimits.length,
            data.savingsGoals.length,
            data.recurringTransactions.length,
          ],
          'transactions': list(data.transactions),
          'netWorthEntries': list(data.netWorthEntries),
          'categoryBudgetLimits': jsonEncode(data.categoryBudgetLimits),
          'savingsGoals': list(data.savingsGoals),
          'recurringTransactions': list(data.recurringTransactions),
          'themeMode': data.themeMode?.name,
          'categories': list(data.categories),
          'transactionTags': list(data.transactionTags),
          'baseCurrencyCode': data.baseCurrencyCode,
          'localeOverride': data.localeOverride,
          'appLockEnabled': data.appLockEnabled,
          'autoLockTimeoutSeconds': data.autoLockTimeoutSeconds,
          'hideBalances': data.hideBalances,
        };
        // Rules can hold an amount Dart cannot encode; the restore then
        // fails at its first store write.
        try {
          decoded['categorizationRules'] = list(data.categorizationRules);
        } catch (error) {
          decoded['categorizationRules'] = null;
          result['restoreFails'] = error.toString();
        }
        final known = <String>{};
        collectStrings(
            jsonDecode(utf8.decode(bytes, allowMalformed: true).replaceFirst(
                RegExp('^﻿'), '')),
            known);
        decoded['generatedIds'] = generatedIds(
            jsonEncode({
              for (final key in [
                'transactions',
                'netWorthEntries',
                'savingsGoals',
                'recurringTransactions',
                'categories',
                'transactionTags',
                'categorizationRules'
              ])
                key: decoded[key] == null ? [] : jsonDecode(decoded[key] as String)
            }),
            {'known': known.toList()});
        result['ok'] = decoded;
      } on FormatException catch (error) {
        result['error'] = error.message;
      } catch (error) {
        result['other'] = error.toString();
      }
      cases.add({'name': name, 'file': base64Encode(bytes), ...result});
    }
    writeJson('${zoneDir()}/decode.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'now': iso(launchNow),
      'cases': cases,
    });
  });

  final restoreCases = <Map<String, Object?>>[];
  for (final spec in restoreSpecs()) {
    testWidgets('restore: ${spec.name}', (tester) async {
      quietLayoutErrors();
      tester.view.physicalSize = const Size(1000, 8000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final bytes = files[spec.file]!;
      final out = <String, Object?>{
        'name': spec.name,
        'current': spec.current,
        'file': spec.file,
        if (spec.cancel) 'cancel': true,
      };
      out['flutter'] = await runRestore(tester, spec, bytes);
      final filled = await tester.runAsync(() => d10Filled(spec, bytes));
      if (filled != null) {
        out['d10'] = await runRestore(tester, spec, filled);
      }
      restoreCases.add(out);
    });
  }

  test('write restore.json', () {
    writeJson('${zoneDir()}/restore.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'launchNow': iso(launchNow),
      'files': {
        for (final spec in restoreSpecs()) spec.file: base64Encode(files[spec.file]!)
      },
      'cases': restoreCases,
    });
  });
}

// MARK: - Decode corpus

/// Hand-made files for `decodeBackup`: each check, in order, and every
/// input shape the research found (bytes as the picker returns them).
Map<String, List<int>> decodeCorpus() {
  List<int> s(String text) => utf8.encode(text);
  String env(String data, {String sv = '3'}) =>
      '{"schemaVersion":$sv,"data":$data}';
  const cat =
      '{"id":"expense-a","type":"expense","name":"A"},{"id":"income-b","type":"income","name":"B"}';
  const txOk =
      '{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01"}';
  final bom = [0xEF, 0xBB, 0xBF];
  String nested(int depth) => '${'[' * depth}${']' * depth}';
  return {
    'empty': s(''),
    'whitespace': s(' \n'),
    'bom1': [...bom, ...s(env('{}'))],
    'bom2': [...bom, ...bom, ...s(env('{}'))],
    'bom3': [...bom, ...bom, ...bom, ...s(env('{}'))],
    'bom after space': [0x20, ...bom, ...s(env('{}'))],
    'truncated bom': [0xEF, 0xBB, ...s(env('{}'))],
    'array': s('[]'),
    'string': s('"x"'),
    'number': s('3'),
    'null': s('null'),
    'trailing garbage': s('${env('{}')} x'),
    'sv double': s(env('{}', sv: '3.0')),
    'sv exponent': s(env('{}', sv: '3e0')),
    'sv string': s(env('{}', sv: '"3"')),
    'sv null': s(env('{}', sv: 'null')),
    'sv missing': s('{"data":{}}'),
    'sv 4': s(env('{}', sv: '4')),
    'sv 4 no data': s('{"schemaVersion":4}'),
    'sv 0': s(env('{}', sv: '0')),
    'sv -5': s(env('{}', sv: '-5')),
    'sv -0': s(env('{}', sv: '-0')),
    'sv 1': s(env('{}', sv: '1')),
    'sv 2': s(env('{}', sv: '2')),
    'sv bigint': s(env('{}', sv: '99999999999999999999')),
    'sv int64 min': s(env('{}', sv: '-9223372036854775808')),
    'no data': s('{"schemaVersion":3}'),
    'data null': s('{"schemaVersion":3,"data":null}'),
    'data list': s('{"schemaVersion":3,"data":[]}'),
    'data string': s('{"schemaVersion":3,"data":"x"}'),
    'data empty': s(env('{}')),
    'all keys null': s(env('{"transactions":null,"netWorthEntries":null,'
        '"categoryBudgetLimits":null,"savingsGoals":null,'
        '"recurringTransactions":null,"themeMode":null,"categories":null,'
        '"transactionTags":null,"categorizationRules":null,'
        '"baseCurrencyCode":null,"localeOverride":null,"appLockEnabled":null,'
        '"autoLockTimeoutSeconds":null,"hideBalances":null}')),
    'invalid utf8 in value': [
      ...s('{"schemaVersion":3,"data":{"transactions":[{"id":"a","type":"expense","description":"x'),
      0xFF, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0xE2, 0x82, 0x20, 0xF0, 0x9F, 0x98,
      0x20, 0xF4, 0x90, 0x80, 0x80, 0xF0, 0x9F, 0x98, 0x80,
      ...s('y","amount":1,"category":"c","date":"2026-01-01"}]}}'),
    ],
    'invalid utf8 in currency': [
      ...s('{"schemaVersion":3,"data":{"baseCurrencyCode":"U'),
      0xFF,
      ...s('D"}}'),
    ],
    'currency 2': s(env('{"baseCurrencyCode":"US"}')),
    'currency 4': s(env('{"baseCurrencyCode":"USDX"}')),
    'currency lower padded': s(env('{"baseCurrencyCode":" eur\\t"}')),
    'currency bom padded': s(env('{"baseCurrencyCode":"\\ufeffgbp\\u00a0"}')),
    'currency astral': s(env('{"baseCurrencyCode":"\\ud801\\udc28a"}')),
    'currency sharp s': s(env('{"baseCurrencyCode":"\\u00dfab"}')),
    'currency int': s(env('{"baseCurrencyCode":1}')),
    'currency null': s(env('{"baseCurrencyCode":null}')),
    'currency + bad tx': s(env('{"baseCurrencyCode":"US","transactions":[1]}')),
    'currency + bad locale':
        s(env('{"baseCurrencyCode":"US","localeOverride":1}')),
    'tx not list': s(env('{"transactions":{}}')),
    'tx item not map': s(env('{"transactions":[1]}')),
    'tx bad type': s(env(
        '{"transactions":[{"id":"a","type":"x","description":"d","amount":1,"category":"c","date":"2026-01-01"}]}')),
    'tx type uppercase': s(env(
        '{"transactions":[{"id":"a","type":"EXPENSE","description":"d","amount":1,"category":"c","date":"2026-01-01"}]}')),
    'tx ok': s(env('{"transactions":[$txOk]}')),
    'tx amount inf': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1e999,"category":"c","date":"2026-01-01"}]}')),
    'tx amount -inf': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":-1e999,"category":"c","date":"2026-01-01"}]}')),
    'tx amount str': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":"1","category":"c","date":"2026-01-01"}]}')),
    'tx no desc': s(env(
        '{"transactions":[{"id":"a","type":"expense","amount":1,"category":"c","date":"2026-01-01"}]}')),
    'tx null category': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":null,"date":"2026-01-01"}]}')),
    'tx bad date': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"nope"}]}')),
    'tx date int': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":5}]}')),
    'tx id int': s(env(
        '{"transactions":[{"id":5,"type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01"}]}')),
    'tx template int': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01","recurringTemplateId":1}]}')),
    'tx tagIds obj': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01","tagIds":{}}]}')),
    'tx tagIds mixed': s(env(
        '{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01","tagIds":["x",1,null]}]}')),
    'tx blank and dup ids': s(env('{"transactions":['
        '{"id":"","type":"expense","description":"blank","amount":1,"category":"c","date":"2026-01-01"},'
        '{"id":"\\ufeff","type":"expense","description":"bom","amount":1,"category":"c","date":"2026-01-01"},'
        '{"type":"income","description":"missing","amount":2.5,"category":"c","date":"2026-01-02","createdAt":"2026-01-03T00:00:00.000Z"},'
        '{"id":"dup","type":"expense","description":"first","amount":1,"category":"c","date":"2026-01-01"},'
        '{"id":"dup","type":"expense","description":"second","amount":1,"category":"c","date":"2026-01-01"}]}')),
    'tx dup key': s(env(
        '{"transactions":[{"id":"a","type":"x","type":"income","description":"d","amount":"1","amount":2,"category":"c","date":"2026-01-01"}]}')),
    'limits list': s(env('{"categoryBudgetLimits":[]}')),
    'limits str val': s(env('{"categoryBudgetLimits":{"a":"1"}}')),
    'limits null val': s(env('{"categoryBudgetLimits":{"a":null}}')),
    'limits neg zero': s(env('{"categoryBudgetLimits":{"a":-5,"b":0,"c":2}}')),
    'limits inf': s(env('{"categoryBudgetLimits":{"a":1e999}}')),
    'limits dup keys': s(env(
        '{"categoryBudgetLimits":{"a":"x","b":1,"a":3,"Caf\\u00e9":1,"Cafe\\u0301":2,"\\ud800":4}}')),
    'goal nan str': s(env(
        '{"savingsGoals":[{"id":"g","name":"n","targetAmount":"NaN","currentAmount":1}]}')),
    'goal inf str': s(env(
        '{"savingsGoals":[{"id":"g","name":"n","targetAmount":"Infinity","currentAmount":1}]}')),
    'goal -inf str': s(env(
        '{"savingsGoals":[{"id":"g","name":"n","targetAmount":"-Infinity","currentAmount":1}]}')),
    'goal empty obj': s(env('{"savingsGoals":[{}]}')),
    'goal name int': s(env('{"savingsGoals":[{"id":"g","name":5}]}')),
    'goal full': s(env(
        '{"savingsGoals":[{"id":"g","name":"  Trip ","targetAmount":" 1500.5 ","currentAmount":-2,"targetDate":"2026-12-01","createdAt":"2026-01-01T00:00:00.000Z","completedAt":"x"}]}')),
    'rec int amount': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5,"category":"c","pattern":"weekly","startDate":"2026-01-01","nextOccurrence":"2026-01-01"}]}')),
    'rec monthly no day': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"monthly","startDate":"2026-01-01","nextOccurrence":"2026-01-01"}]}')),
    'rec monthly day 0': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"monthly","startDate":"2026-01-01","nextOccurrence":"2026-01-01","dayOfMonth":0}]}')),
    'rec monthly day 32': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"monthly","startDate":"2026-01-01","nextOccurrence":"2026-01-01","dayOfMonth":32}]}')),
    'rec monthly day 31': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"monthly","startDate":"2026-01-31","nextOccurrence":"2026-10-31","dayOfMonth":31}]}')),
    'rec day double': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"monthly","startDate":"2026-01-01","nextOccurrence":"2026-01-01","dayOfMonth":5.0}]}')),
    'rec weekly day 99': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"weekly","startDate":"2026-01-01","nextOccurrence":"2026-12-01","dayOfMonth":99}]}')),
    'rec bad pattern': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"daily","startDate":"2026-01-01","nextOccurrence":"2026-01-01"}]}')),
    'rec isActive str': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":5.0,"category":"c","pattern":"weekly","startDate":"2026-01-01","nextOccurrence":"2026-12-01","isActive":"no"}]}')),
    'rec no id': s(env(
        '{"recurringTransactions":[{"type":"income","description":"d","amount":5.5,"category":"c","pattern":"biweekly","startDate":"2026-01-01","nextOccurrence":"2026-12-01","isActive":false}]}')),
    'rec amount inf': s(env(
        '{"recurringTransactions":[{"id":"r","type":"expense","description":"d","amount":1e999,"category":"c","pattern":"weekly","startDate":"2026-01-01","nextOccurrence":"2026-12-01"}]}')),
    'nw bad type': s(env(
        '{"netWorthEntries":[{"id":"n","name":"n","type":"other","createdAt":"2026-01-01"}]}')),
    'nw no id': s(env(
        '{"netWorthEntries":[{"name":"n","type":"asset","createdAt":"2026-01-01"}]}')),
    'nw legacy snap': s(env(
        '{"netWorthEntries":[{"id":"n","name":"n","type":"asset","createdAt":"2026-01-01","snapshots":[{"monthKey":"2026-02","amount":5},{"monthKey":"2026-03","updatedAt":"2026-03-09T10:00:00.000","amount":6}]}]}')),
    'nw snap no date': s(env(
        '{"netWorthEntries":[{"id":"n","name":"n","type":"liability","createdAt":"2026-01-01","snapshots":[{"amount":7.5}]}]}')),
    'nw snap inf': s(env(
        '{"netWorthEntries":[{"id":"n","name":"n","type":"asset","createdAt":"2026-01-01","snapshots":[{"recordedAt":"2026-02-01","amount":1e999}]}]}')),
    'nw snap bad date': s(env(
        '{"netWorthEntries":[{"id":"n","name":"n","type":"asset","createdAt":"2026-01-01","snapshots":[{"recordedAt":"nope","amount":1}]}]}')),
    'cats dup id': s(env(
        '{"categories":[$cat,{"id":"expense-a","type":"expense","name":"A2"}]}')),
    'cats nfc nfd ids': s(env(
        '{"categories":[$cat,{"id":"Caf\\u00e9","type":"expense","name":"x"},{"id":"Cafe\\u0301","type":"expense","name":"y"}]}')),
    'cats no income': s(env(
        '{"categories":[{"id":"expense-a","type":"expense","name":"A"}]}')),
    'cats archived income': s(env(
        '{"categories":[{"id":"expense-a","type":"expense","name":"A"},{"id":"i","type":"income","name":"B","isArchived":true}]}')),
    'cats ok': s(env('{"categories":[$cat]}')),
    'cats empty': s(env('{"categories":[]}')),
    'cats type weird': s(env(
        '{"categories":[{"id":"x","type":"weird","name":"A"},{"id":"i","type":"income","name":"B"}]}')),
    'cats sortOrder inf': s(env(
        '{"categories":[{"id":"x","type":"expense","name":"A","sortOrder":1e999},{"id":"i","type":"income","name":"B"}]}')),
    'cats sortOrder frac': s(env(
        '{"categories":[{"id":"x","type":"expense","name":"A","sortOrder":-2.7,"iconIdentifier":null,"colorToken":"red","isArchived":false,"isBuiltIn":true,"extra":1},{"id":"i","type":"income","name":"B","sortOrder":9}]}')),
    'cats name missing': s(env(
        '{"categories":[{"id":"x","type":"expense"},{"id":"i","type":"income","name":"B"}]}')),
    'cats bool str': s(env(
        '{"categories":[{"id":"x","type":"expense","name":"A","isArchived":"no"},{"id":"i","type":"income","name":"B"}]}')),
    'tags dup': s(env(
        '{"transactionTags":[{"id":"t","name":"a"},{"id":"t","name":"b"}]}')),
    'tags no id': s(env(
        '{"transactionTags":[{"name":"  a "},{"colorToken":"red"}]}')),
    'tags name int': s(env('{"transactionTags":[{"id":"t","name":1}]}')),
    'rule unknown tag': s(env(
        '{"transactionTags":[],"categorizationRules":[{"id":"r","merchantPattern":"x","category":"c","tagIds":["zz"]}]}')),
    'rule known tag': s(env(
        '{"transactionTags":[{"id":"zz","name":"Z"}],"categorizationRules":[{"id":"r","merchantPattern":" x ","category":"c","tagIds":["zz",5],"matchType":"exact","transactionType":"weird"}]}')),
    'rule dup id': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x"},{"id":"r","merchantPattern":"y"}]}')),
    'rule inf min': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x","category":"c","minimumAmount":1e999}]}')),
    'rule inf min + bad currency': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x","category":"c","maximumAmount":-1e999}],"baseCurrencyCode":"x"}')),
    'rule priority inf': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x","category":"c","priority":1e999}]}')),
    'rule priority frac': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x","category":"c","priority":2.9},{"id":"q","priority":-0.5}]}')),
    'rule min str': s(env(
        '{"categorizationRules":[{"id":"r","merchantPattern":"x","minimumAmount":"5"}]}')),
    'locale int': s(env('{"localeOverride":5}')),
    'locale padded': s(env('{"localeOverride":" de_DE "}')),
    'locale blank': s(env('{"localeOverride":"   "}')),
    'locale null': s(env('{"localeOverride":null}')),
    'lock str': s(env('{"appLockEnabled":"yes"}')),
    'hide int': s(env('{"hideBalances":1}')),
    'settings full': s(env(
        '{"baseCurrencyCode":"jpy","localeOverride":"fr_FR","appLockEnabled":true,"autoLockTimeoutSeconds":900,"hideBalances":true}')),
    'timeout neg': s(env('{"autoLockTimeoutSeconds":-1}')),
    'timeout neg frac': s(env('{"autoLockTimeoutSeconds":-0.5}')),
    'timeout frac': s(env('{"autoLockTimeoutSeconds":29.9}')),
    'timeout huge': s(env('{"autoLockTimeoutSeconds":1e30}')),
    'timeout inf': s(env('{"autoLockTimeoutSeconds":1e999}')),
    'timeout inf + bad tx': s(env('{"autoLockTimeoutSeconds":1e999,"transactions":[1]}')),
    'timeout str': s(env('{"autoLockTimeoutSeconds":"5"}')),
    'theme weird': s(env('{"themeMode":"purple"}')),
    'theme system': s(env('{"themeMode":"system"}')),
    'theme int': s(env('{"themeMode":1}')),
    'app wrong': s('{"schemaVersion":3,"app":"other","data":{}}'),
    'dup key': s('{"schemaVersion":9,"schemaVersion":3,"data":{}}'),
    'dup data key': s('{"schemaVersion":3,"data":[],"data":{"transactions":[$txOk]}}'),
    'deep nesting 128': s(env('{"x":${nested(126)}}')),
    'deep nesting 200': s(env('{"x":${nested(200)}}')),
  };
}

// MARK: - Restore through the real page

class RestoreSpec {
  final String name;
  final String current;
  final String file;
  final bool cancel;
  const RestoreSpec(this.name, this.current, this.file, {this.cancel = false});
}

List<RestoreSpec> restoreSpecs() => const [
      RestoreSpec('typical over fresh', 'fresh_install', 'typical export'),
      RestoreSpec('typical over typical', 'typical', 'typical export'),
      RestoreSpec('fresh over typical', 'typical', 'fresh export'),
      RestoreSpec('dates over typical', 'typical', 'dates export'),
      RestoreSpec('dst dates over typical', 'typical', 'dst dates export'),
      RestoreSpec('dst dates over fresh', 'fresh_install', 'dst dates export'),
      RestoreSpec('strings over fresh', 'fresh_install', 'strings export'),
      RestoreSpec('rules ties over typical', 'typical', 'rules ties export'),
      RestoreSpec('v1 over typical', 'typical', 'v1 dates'),
      RestoreSpec('empty data over typical', 'typical', 'data empty'),
      RestoreSpec('all null over typical', 'typical', 'all keys null'),
      RestoreSpec('settings over typical', 'typical', 'settings full'),
      RestoreSpec('locale null over typical', 'typical', 'locale null'),
      RestoreSpec('blank and dup ids over fresh', 'fresh_install',
          'tx blank and dup ids'),
      RestoreSpec('due templates over fresh', 'fresh_install', 'due templates'),
      RestoreSpec('limits over typical', 'typical', 'limits neg zero'),
      RestoreSpec('categories empty over typical', 'typical', 'cats empty'),
      RestoreSpec('bom2 malformed over fresh', 'fresh_install', 'bom2 malformed'),
      RestoreSpec('cancel', 'fresh_install', 'typical export', cancel: true),
      RestoreSpec('not valid', 'typical', 'trailing garbage'),
      RestoreSpec('newer', 'typical', 'sv 4'),
      RestoreSpec('no data', 'typical', 'data list'),
      RestoreSpec('corrupt', 'typical', 'tx amount str'),
      RestoreSpec('currency', 'typical', 'currency 2'),
      RestoreSpec('timeout inf', 'typical', 'timeout inf'),
      RestoreSpec('rule min inf', 'typical', 'rule inf min'),
    ];

/// Extra files for the restore cases.
Map<String, List<int>> restoreFiles() {
  List<int> s(String text) => utf8.encode(text);
  return {
    'due templates': s('{"schemaVersion":3,"data":{"recurringTransactions":['
        '{"id":"due-monthly","type":"expense","description":"Rent","amount":1500.0,"category":"Brand New Rent","pattern":"monthly","startDate":"2026-01-31T00:00:00.000","nextOccurrence":"2026-07-31T00:00:00.000","dayOfMonth":31,"dayOfWeek":null,"isActive":true},'
        '{"id":"due-weekly","type":"income","description":"Pay","amount":800.5,"category":"Salary","pattern":"weekly","startDate":"2026-05-04T09:00:00.000","nextOccurrence":"2026-06-01T09:00:00.000","dayOfMonth":null,"dayOfWeek":1,"isActive":true},'
        '{"id":"paused","type":"expense","description":"Paused","amount":9.0,"category":"Paused Cat","pattern":"monthly","startDate":"2026-01-05T00:00:00.000","nextOccurrence":"2026-02-05T00:00:00.000","dayOfMonth":5,"dayOfWeek":null,"isActive":false},'
        '{"id":"today","type":"expense","description":"Today","amount":3.0,"category":"General","pattern":"biweekly","startDate":"2026-09-28T23:00:00.000","nextOccurrence":"2026-09-28T23:00:00.000","dayOfMonth":null,"dayOfWeek":1,"isActive":true}'
        '],"transactions":[],"categories":null}}'),
    'bom2 malformed': [
      0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF,
      ...s('{"schemaVersion":3,"data":{"transactions":[{"id":"m","type":"expense","description":"bad '),
      0xFF, 0xED, 0xA0, 0x80,
      ...s(' end","amount":4.5,"category":"Caf'),
      0xC3, 0xA9,
      ...s('","date":"2026-09-01T12:00:00.000"}]}}'),
    ],
  };
}

/// For a file that leaves keys out (or null), the same file with those keys
/// taken from the current state's Flutter export: what Swift's D10 restore
/// must end up with. Null when nothing is left out or the file is not a
/// valid backup object.
Future<List<int>?> d10Filled(RestoreSpec spec, List<int> bytes) async {
  if (spec.cancel) return null;
  Map<String, dynamic> root;
  try {
    // Only files Flutter restores (a rejected file changes nothing).
    decodeBackup(utf8.decode(bytes, allowMalformed: true));
    root = jsonDecode(utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst(RegExp('^﻿'), '')) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final data = root['data'];
  if (data is! Map<String, dynamic> || root['schemaVersion'] is! int) {
    return null;
  }
  final app = await loadStore(
      input: Directory('$fixturesRoot/store/${spec.current}/input'),
      prefs: prefsFrom(File('$fixturesRoot/store/${spec.current}/prefs.json')));
  final current = (jsonDecode(encodeBackup(exportData(app, null),
      appVersion: appVersion, exportedAt: exportedAt)) as Map)['data'] as Map;
  var changed = false;
  for (final key in current.keys) {
    if (key == 'themeMode') continue;
    final missing = key == 'localeOverride'
        ? !data.containsKey(key)
        : data[key] == null;
    if (missing) {
      data[key] = current[key];
      changed = true;
    }
  }
  if (!changed) return null;
  try {
    return utf8.encode(jsonEncode(root));
  } on JsonUnsupportedObjectError {
    // A non-finite rule bound: Flutter's restore fails on it anyway.
    return null;
  }
}

class FakeFilePicker extends FilePickerPlatform {
  List<int>? bytes;
  List<String>? allowedExtensions;

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
    this.allowedExtensions = allowedExtensions;
    final bytes = this.bytes;
    if (bytes == null) return null;
    return FilePickerResult([
      PlatformFile(
          name: 'backup.json',
          size: bytes.length,
          bytes: Uint8List.fromList(bytes)),
    ]);
  }
}

/// Canonical sections as text (checksum above 20 kB), and the ids in them
/// that neither the file nor the current store had.
Map<String, Object?> sectionsAfter(
    Map<String, dynamic> sections, Set<String> known) {
  final out = <String, Object?>{};
  final generated = <String, Object?>{};
  for (final key in storeSections) {
    final text = jsonEncode(sections[key]);
    final bytes = utf8.encode(text);
    out[key] = bytes.length <= 20000
        ? text
        : {'fnv': fnv(bytes), 'length': bytes.length};
    generated[key] =
        generatedIds(jsonEncode([sections[key]]), {'known': known.toList()});
  }
  return {'sections': out, 'generatedIds': generated};
}

/// One import through the real page over a fresh copy of the current
/// store: dialog, snackbar, then a relaunch's store, preferences and theme.
Future<Map<String, Object?>> runRestore(
    WidgetTester tester, RestoreSpec spec, List<int> bytes) async {
  late AppHarness app;
  late Map<String, dynamic> before;
  late int revisionBefore;
  await tester.runAsync(() async {
    app = await loadStore(
        input: Directory('$fixturesRoot/store/${spec.current}/input'),
        prefs: prefsFrom(File('$fixturesRoot/store/${spec.current}/prefs.json')));
    final snapshot = await store.read();
    before = snapshot.sections;
    revisionBefore = snapshot.revision;
  });
  final picker = FakeFilePicker()..bytes = bytes;
  FilePickerPlatform.instance = picker;
  pinClock(launchNow);
  seedUuids(4001);
  final theme = ThemeProvider();
  await pumpSettings(tester, app, theme);
  final result = <String, Object?>{};
  await tester.tap(find.text('Import backup'));
  await pumpUntil(
      tester,
      () =>
          find.byType(AlertDialog).evaluate().isNotEmpty ||
          find.byType(SnackBar).evaluate().isNotEmpty);
  result['allowedExtensions'] = picker.allowedExtensions;
  final dialogs = find.byType(AlertDialog);
  if (dialogs.evaluate().isNotEmpty) {
    final dialog = tester.widget<AlertDialog>(dialogs);
    result['dialog'] = {
      'title': (dialog.title as Text).data,
      'message': (dialog.content as Text).data,
    };
    await tester.tap(find.text(spec.cancel ? 'Cancel' : 'Replace'));
    await pumpUntil(
        tester,
        () =>
            find.byType(SnackBar).evaluate().isNotEmpty ||
            (spec.cancel &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty &&
                find.byType(AlertDialog).evaluate().isEmpty));
  }
  result['snackbar'] = snackbarText(tester);
  result['themeAfterRestore'] = theme.themeMode.name;
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async {
    await store.resetForTesting(directory: await store.storageDirectory());
    final afterRestore = await store.read();
    result['storeChanged'] = afterRestore.revision != revisionBefore ||
        jsonEncode(afterRestore.sections) != jsonEncode(before);
    // A relaunch: the launch pass materialises legacy categories.
    final relaunched = AppHarness();
    await relaunched.initialize(generate: false);
    final after = await store.read();
    final known = <String>{};
    collectStrings(before, known);
    try {
      collectStrings(
          jsonDecode(utf8
              .decode(bytes, allowMalformed: true)
              .replaceFirst(RegExp('^﻿'), '')),
          known);
    } catch (_) {}
    result['afterRelaunch'] = sectionsAfter(after.sections, known);
    result['prefs'] = await dumpPrefs();
  });
  return result;
}

// MARK: - Driving the real SettingsPage

Future<void> pumpSettings(
    WidgetTester tester, AppHarness app, ThemeProvider theme) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
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

String? snackbarText(WidgetTester tester) {
  final bars = find.byType(SnackBar);
  if (bars.evaluate().isEmpty) return null;
  final texts = tester
      .widgetList<Text>(find.descendant(of: bars.first, matching: find.byType(Text)))
      .map((t) => t.data)
      .toList();
  return texts.join('\n');
}

class FakeShare extends SharePlatform {
  final files = <XFile>[];
  String? subject;

  @override
  Future<ShareResult> shareXFiles(List<XFile> files,
      {String? subject,
      String? text,
      Rect? sharePositionOrigin,
      List<String>? fileNameOverrides}) async {
    this.files.addAll(files);
    this.subject = subject;
    return const ShareResult('dismissed', ShareResultStatus.dismissed);
  }
}

class FakePathProvider extends PathProviderPlatform {
  final String temporary;
  FakePathProvider(this.temporary);

  @override
  Future<String?> getTemporaryPath() async => temporary;
}
