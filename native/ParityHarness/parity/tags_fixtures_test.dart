// Emits native/Fixtures/tags/mutations.json : tag and rule management from
// the real Dart code.
//
// Scenarios of real CategorizationProvider calls (addTag, deleteTag,
// addRule, deleteRule) through a real AtomicFinancialStore (files in a temp
// directory) with seeded UUIDs, recording per step the op with its resolved
// arguments, Dart's ArgumentError copy, how many commits the store made,
// the `transactionTags` / `categorizationRules` sections whose content
// changed (their JSON), the provider's memory (`tags`, and `rules` in the
// getter's priority order) and, at `check` steps, which rule `suggest`
// picks for a list of probes.
//
// Swift writes one commit per edit and nothing when the content did not
// change (Dart rewrites unchanged lists and makes two commits per
// deleteTag); the steps record Dart's commit count for that comparison.
//
// `sort_*` scenarios hold 33, 34, 40 and 70 rules with tied priorities:
// Dart's List.sort is an insertion sort (stable) up to 33 elements and a
// dual-pivot quicksort from 34, so from there `rules` reorders ties.
//
// `malformed` records Dart's all-or-nothing load (one bad row empties the
// list; the next write destroys the stored rows). Swift keeps the rows.
//
// `canary`: the real Tags & rules page adds a rule through its dialog (two
// chips tapped in reverse list order) and refuses a duplicate tag with its
// snackbar; the rule's stored JSON is the shape Swift's RuleDraft makes.

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/categorization_rule.dart';
import 'package:budget_app/categorization_settings_page.dart';
import 'package:budget_app/common.dart';
import 'package:budget_app/parity_clock.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

const sections = ['transactionTags', 'categorizationRules'];

Future<Map<String, String?>> sectionStrings() async {
  final stored = (await AtomicFinancialStore.instance.read()).sections;
  return {
    for (final name in sections)
      name: stored[name] == null ? null : jsonEncode(stored[name]),
  };
}

String? number(double? value) => value?.toString();

/// The provider's memory, one JSON line per row: tags in list order, rules
/// in the `rules` getter's order (Dart's sort).
Map<String, Object?> memory(CategorizationProvider provider) => {
      'tags': [
        for (final t in provider.tags) jsonEncode([t.id, t.name, t.colorToken])
      ],
      'rules': [
        for (final r in provider.rules)
          jsonEncode([
            r.id,
            r.merchantPattern,
            r.matchType.name,
            r.transactionType?.name,
            number(r.minimumAmount),
            number(r.maximumAmount),
            r.category,
            r.tagIds,
            r.priority,
            r.isEnabled,
          ])
      ],
    };

TransactionTyp? typeNamed(Object? name) => switch (name) {
      'expense' => TransactionTyp.expense,
      'income' => TransactionTyp.income,
      _ => null,
    };

/// An int is an index into the provider's `tags` at the time of the op;
/// a string is an id as is.
String tagRef(CategorizationProvider provider, Object? ref) =>
    ref is int ? provider.tags[ref].id : ref as String;

/// An int is an index into `rules` (priority order); a string is an id.
String ruleRef(CategorizationProvider provider, Object? ref) =>
    ref is int ? provider.rules[ref].id : ref as String;

Future<Map<String, Object?>> runScenario({
  required String name,
  required bool byteComparable,
  Map<String, Object?> initial = const {},
  required List<List> ops,
  int seed = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('tags_fixture');
  final store = AtomicFinancialStore.instance;
  await store.resetForTesting(directory: dir);
  if (initial.isNotEmpty) await store.updateSections(initial);
  final initialSections = jsonEncode((await store.read()).sections);
  pinClock(DateTime(2026, 9, 28, 9, 15, 30, 250, 125));

  seedUuids(seed);
  final provider = CategorizationProvider();
  await provider.load();
  // Ids the load generated for rows without one, tags first (load order).
  Set<Object?> storedIds(String section) => {
        for (final row in (initial[section] as List? ?? const []))
          if (row is Map) row['id']
      };
  final tagIds = storedIds('transactionTags');
  final ruleIds = storedIds('categorizationRules');
  final launched = {
    'sections': await sectionStrings(),
    'memory': memory(provider),
    'generatedIds': [
      for (final t in provider.tags)
        if (!tagIds.contains(t.id)) t.id,
      for (final r in provider.rules)
        if (!ruleIds.contains(r.id)) r.id,
    ],
  };

  final recorded = <Map<String, Object?>>[];
  for (final op in ops) {
    final before = await sectionStrings();
    final revision = (await store.read()).revision;
    final step = <String, Object?>{'op': op[0]};
    String? error;
    try {
      switch (op[0]) {
        case 'addTag':
          final count = provider.tags.length;
          step['name'] = op[1];
          step['colorToken'] = op.length > 2 ? op[2] : 'accent';
          try {
            await provider.addTag(op[1] as String,
                colorToken: step['colorToken'] as String);
          } finally {
            step['newId'] =
                provider.tags.length > count ? provider.tags.last.id : null;
          }
        case 'deleteTag':
          step['id'] = tagRef(provider, op[1]);
          await provider.deleteTag(step['id'] as String);
        case 'addRule':
          final spec = op[1] as Map<String, Object?>;
          final rule = CategorizationRule(
            id: spec['id'] as String?,
            merchantPattern: spec['pattern'] as String,
            matchType: MerchantMatchType.values
                .byName(spec['match'] as String? ?? 'contains'),
            transactionType: typeNamed(spec['type']),
            minimumAmount: spec['min'] as double?,
            maximumAmount: spec['max'] as double?,
            category: spec['category'] as String,
            tagIds: [
              for (final ref in spec['tags'] as List? ?? const [])
                tagRef(provider, ref)
            ],
            priority: spec['priority'] as int? ?? 0,
            isEnabled: spec['enabled'] as bool? ?? true,
          );
          step.addAll({
            'id': rule.id,
            'merchantPattern': spec['pattern'],
            'matchType': rule.matchType.name,
            'transactionType': rule.transactionType?.name,
            'minimumAmount': rule.minimumAmount,
            'maximumAmount': rule.maximumAmount,
            'category': rule.category,
            'tagIds': rule.tagIds,
            'priority': rule.priority,
            'isEnabled': rule.isEnabled,
          });
          await provider.addRule(rule);
        case 'deleteRule':
          step['id'] = ruleRef(provider, op[1]);
          await provider.deleteRule(step['id'] as String);
        case 'check':
          step['probes'] = [
            for (final probe in op[1] as List)
              {
                'type': probe[0],
                'description': probe[1],
                'amount': probe[2],
                'rule': provider
                    .suggest(
                      type: typeNamed(probe[0])!,
                      description: probe[1] as String,
                      amount: probe[2] as double,
                    )
                    ?.rule
                    .id,
              }
          ];
        default:
          throw ArgumentError('unknown op ${op[0]}');
      }
    } on ArgumentError catch (e) {
      error = e.message?.toString() ?? 'Invalid tag';
    }
    final after = await sectionStrings();
    step.addAll({
      'error': error,
      'commits': (await store.read()).revision - revision,
      'sections': {
        for (final s in sections)
          if (after[s] != before[s]) s: after[s]
      },
      'memory': memory(provider),
    });
    recorded.add(step);
  }

  final result = {
    'name': name,
    'byteComparable': byteComparable,
    'initialSections': initialSections,
    'launched': launched,
    'steps': recorded,
  };
  await store.resetForTesting();
  await dir.delete(recursive: true);
  seedParityUuids(null);
  pinClock(null);
  return result;
}

// --- Scenarios ---------------------------------------------------------------

final probes = [
  ['expense', 'whole foods market', 12.5],
  ['expense', '  WHOLE FOODS\u{FEFF}', 0.0],
  ['income', 'ACME PAYROLL inc', 1000.0],
  ['income', 'acme payroll', 999.99],
  ['expense', 'acme payroll', 5000.0],
  ['expense', 'Rent', 10.0],
  ['income', 'rent', 10.0],
  ['expense', 'starbucks', 0.3],
  ['expense', 'STARBUCKS', 0.1 + 0.2],
  ['expense', 'starbucks', 20.0],
  ['expense', 'starbucks', 20.01],
  ['expense', 'neg', -0.0],
  ['expense', 'neg', 5.0],
  ['expense', 'neg', 5.000000000000001],
  ['expense', 'first', 1.0],
  ['income', 'First Again', 1.0],
  ['expense', 'second', 1.0],
  ['expense', 'x', 1e21],
  ['expense', '☕️ "q" \\   \u0000 cup', 3.0],
  ['expense', 'café', 3.0],
  ['expense', 'nothing', 0.0],
];

final canonicalOps = <List>[
  ['addTag', 'Work'],
  ['addTag', '  Home  '],
  ['addTag', 'Vacation 🏖️', 'cyan'],
  ['addTag', '\u{FEFF}x\u{FEFF}'],
  ['addTag', '\u0085a'],
  ['addTag', ' b '],
  ['addTag', '　c'],
  ['addTag', ''],
  ['addTag', '   '],
  ['addTag', '\u{FEFF}'],
  ['addTag', 'work'],
  ['addTag', 'WORK'],
  ['addTag', ' work '],
  ['addTag', 'Quote "q" \\ back'],
  ['addRule', {'pattern': '  Whole Foods ', 'type': 'expense', 'category': 'Groceries', 'tags': [1, 0]}],
  ['addRule', {'pattern': 'ACME PAYROLL', 'match': 'startsWith', 'type': 'income', 'min': 1000.0, 'category': 'Salary'}],
  ['addRule', {'pattern': 'rent', 'match': 'exact', 'category': 'Housing', 'enabled': false}],
  ['addRule', {'pattern': 'Starbucks', 'type': 'expense', 'min': 0.1 + 0.2, 'max': 20.0, 'category': 'Eating Out', 'tags': [0], 'priority': 2}],
  ['addRule', {'pattern': 'x', 'type': 'expense', 'min': 1e21, 'max': 1e-7, 'category': 'C', 'priority': -1}],
  ['addRule', {'pattern': 'neg', 'type': 'expense', 'min': -0.0, 'max': 5.0, 'category': 'C', 'priority': 9007199254740993}],
  ['addRule', {'pattern': '☕️ "q" \\   \u0000', 'type': 'expense', 'category': 'Café', 'tags': [2, 2, 0]}],
  ['addRule', {'pattern': 'Café', 'match': 'contains', 'category': 'Café'}],
  ['addRule', {'id': 'fixed-1', 'pattern': 'first', 'type': 'expense', 'category': 'A'}],
  ['addRule', {'id': 'fixed-2', 'pattern': 'second', 'type': 'expense', 'category': 'B'}],
  ['addRule', {'id': 'fixed-1', 'pattern': 'first again', 'type': 'income', 'category': 'A2'}],
  ['check', probes],
  ['deleteTag', 0],
  ['deleteTag', 'unknown-id'],
  ['deleteTag', 2],
  ['deleteTag', 1],
  ['deleteRule', 'fixed-2'],
  ['deleteRule', 'nope'],
  ['deleteRule', 0],
  ['check', probes],
  ['addTag', 'Work'],
  ['addTag', 'vacation 🏖️'],
];

final unicodeNames = [
  'Café', 'Café', 'CAFÉ', 'CAFÉ', 'İstanbul', 'istanbul',
  'ISTANBUL', 'ß', 'SS', 'ss', 'Σ', 'σ', 'ς', '\u{10D0}', '\u{1C90}',
  '\u{13A0}', '\u{AB70}', '𐐀', '𐐨', 'ǅ', 'Ǆ', 'ǆ', '👍🏽', '👍', 'Ａ', 'ａ',
  'ﬁ', 'FI', 'Ω', 'ω', 'Ω', 'K', 'K', 'k',
];

List<Map<String, Object?>> tiedRules(int count, int Function(int) priority) => [
      for (var i = 0; i < count; i++)
        CategorizationRule(
          id: 'r${i.toString().padLeft(2, '0')}',
          merchantPattern: i.isEven ? 'shop' : 'shop more',
          category: 'C$i',
          transactionType: TransactionTyp.expense,
          priority: priority(i),
        ).toJson()
    ];

final sortProbes = [
  ['expense', 'shop', 1.0],
  ['expense', 'shop more', 1.0],
];

final sortOps = <List>[
  ['check', sortProbes],
  ['deleteRule', 'r01'],
  ['check', sortProbes],
  ['addRule', {'id': 'r00', 'pattern': 'shop', 'type': 'expense', 'category': 'moved'}],
  ['check', sortProbes],
];

Map<String, Object?> foreignSections() => {
      'transactionTags': [
        {'name': '  Padded  ', 'id': 'f1'},
        {'id': 'f2', 'name': 'NoColor'},
        {'name': 'No id', 'colorToken': 'red'},
        {
          'id': 'f1',
          'name': 'Dup id',
          'colorToken': 'x',
          'extra': [1]
        },
        {'id': 'f5', 'name': null, 'colorToken': null},
      ],
      'categorizationRules': [
        {
          'id': 'fr1',
          'merchantPattern': '  Pad ',
          'matchType': 'fuzzy',
          'transactionType': 'weird',
          'minimumAmount': 5,
          'maximumAmount': 10,
          'category': 'Cat',
          'tagIds': ['f1', 1, null, 'f2', 'f1'],
          'priority': 2.7,
          'isEnabled': true,
          'future': {'x': 1},
        },
        {
          'merchantPattern': 'noid',
          'category': 'C',
          'tagIds': ['f2']
        },
        {'id': 'fr3', 'merchantPattern': 'missing'},
        {
          'isEnabled': false,
          'priority': -2.7,
          'category': 'Z',
          'merchantPattern': 'reordered',
          'id': 'fr4',
          'tagIds': ['gone'],
          'matchType': 7,
        },
        {'id': 'fr1', 'merchantPattern': 'dup id', 'category': 'D'},
        {'id': 'fr6', 'merchantPattern': 'Pad', 'category': 'E', 'priority': 2},
      ],
    };

final foreignOps = <List>[
  [
    'check',
    [
      ['expense', 'pad', 5.0],
      ['income', 'pad', 10.0],
      ['expense', 'pad', 10.5],
      ['expense', 'noid', 1.0],
      ['expense', 'missing', 1.0],
      ['expense', 'reordered', 1.0],
    ]
  ],
  ['addTag', 'padded'],
  ['addTag', 'no ID'],
  ['addTag', ''],
  ['deleteTag', 'f1'],
  ['deleteTag', 'gone'],
  ['deleteTag', 1],
  [
    'addRule',
    {'id': 'fr1', 'pattern': 'replaced', 'type': 'income', 'category': 'R', 'tags': [0]}
  ],
  ['deleteRule', 'fr3'],
  ['deleteTag', 0],
];

Map<String, Object?> malformedSections() => {
      'transactionTags': [
        {'id': 'm1', 'name': 'Ok'},
        {'id': 5, 'name': 'bad id'},
      ],
      'categorizationRules': [
        {'id': 'mr1', 'merchantPattern': 'ok', 'category': 'C'},
        'row as string',
        {'id': 'mr3', 'merchantPattern': 'typed', 'transactionType': 7},
      ],
    };

Future<List<Map<String, Object?>>> allScenarios() async => [
      await runScenario(
          name: 'canonical', byteComparable: true, ops: canonicalOps),
      await runScenario(
          name: 'names_unicode',
          byteComparable: true,
          seed: 2,
          ops: [
            for (final name in unicodeNames) ['addTag', name]
          ]),
      await runScenario(
          name: 'typical',
          byteComparable: true,
          seed: 3,
          initial: await typicalSections(),
          ops: [
            ['addTag', 'work'],
            ['addTag', 'Vacation 🏖'],
            ['deleteTag', 0],
            [
              'addRule',
              {'pattern': 'Whole Foods', 'type': 'expense', 'category': 'Groceries', 'tags': [0]}
            ],
            ['deleteRule', 1],
            [
              'check',
              [
                ['expense', 'Starbucks', 20.0],
                ['expense', 'whole foods', 1.0],
                ['income', 'ACME PAYROLL', 1000.0],
              ]
            ],
          ]),
      for (final (count, label, priority) in [
        (33, 'tied', (int i) => 0),
        (34, 'tied', (int i) => 0),
        (40, 'mixed', (int i) => i % 3),
        (70, 'tied', (int i) => 0),
      ])
        await runScenario(
            name: 'sort_${count}_$label',
            byteComparable: true,
            seed: 4,
            initial: {'categorizationRules': tiedRules(count, priority)},
            ops: sortOps),
      await runScenario(
          name: 'foreign',
          byteComparable: false,
          seed: 5,
          initial: foreignSections(),
          ops: foreignOps),
      await runScenario(
          name: 'malformed',
          byteComparable: false,
          seed: 6,
          initial: malformedSections(),
          ops: [
            ['addTag', 'New'],
            ['deleteRule', 'mr1'],
          ]),
    ];

/// The tags and rules the typical store fixture holds (written by the
/// Flutter provider), read through the store from native/Fixtures/store.
Future<Map<String, Object?>> typicalSections() async {
  final dir = await Directory.systemTemp.createTemp('tags_typical');
  for (final file in Directory('$fixturesRoot/store/typical/input')
      .listSync()
      .whereType<File>()) {
    file.copySync('${dir.path}/${file.uri.pathSegments.last}');
  }
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final stored = (await AtomicFinancialStore.instance.read()).sections;
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  return {for (final s in sections) s: stored[s]};
}

// --- The canary: the real page's dialogs -------------------------------------

late Map<String, Object?> canaryResult;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canary: the real page adds a rule and refuses a duplicate tag',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = CategorizationProvider();
    late List<String> tagIds;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('tags_canary');
      await AtomicFinancialStore.instance.resetForTesting(directory: dir);
      seedUuids(7);
      await provider.load();
      await provider.addTag('Work');
      await provider.addTag('Home');
      tagIds = [for (final t in provider.tags) t.id];
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<CategorizationProvider>.value(value: provider),
        ],
        child: const MaterialApp(home: CategorizationSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // Merchant rules > ADD: text, then the chips Home and Work, then Add.
    await tester.tap(find.text('ADD').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '  Whole Foods ');
    await tester.tap(find.widgetWithText(FilterChip, 'Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Work'));
    await tester.pumpAndSettle();
    late int before;
    await tester.runAsync(() async =>
        before = (await AtomicFinancialStore.instance.read()).revision);
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester, from: before);
    late String rules;
    await tester.runAsync(
        () async => rules = (await sectionStrings())['categorizationRules']!);

    // Tags > ADD with a case variant of an existing tag.
    await tester.tap(find.text('ADD').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, ' work ');
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    final snackBar = find.descendant(
        of: find.byType(SnackBar), matching: find.byType(Text));
    expect(snackBar, findsOneWidget);
    final message = tester.widget<Text>(snackBar).data;

    canaryResult = {
      'tagIds': tagIds,
      'firstExpenseCategory': expenseCategories.keys.first,
      'rules': rules,
      'duplicateSnackBar': message,
    };
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await AtomicFinancialStore.instance.resetForTesting();
    });
    seedParityUuids(null);
  });

  test('tag and rule mutations', () async {
    final scenarios = await allScenarios();
    writeJson('${fixtureDir('tags').path}/mutations.json', {
      'tz': parityTz,
      'scenarios': scenarios,
      'canary': canaryResult,
    });
  });
}
