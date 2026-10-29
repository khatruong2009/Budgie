// Emits native/Fixtures/categories/ : category management from the real
// Dart code.
//
// mutations.json: scenarios of real CategoryProvider calls (add, archive,
// restore, move) and of the Categories page's save path (updateCategory
// followed by the TransactionModel, RecurringTransactionModel and
// CategorizationProvider rename cascade), through a real
// AtomicFinancialStore with a pinned clock and seeded UUIDs. The page's
// orchestration is private to category_settings_page.dart, so it is copied
// verbatim below (`pageSave`); the `canary` test drives the real page
// widget for one rename and fails if the copy has drifted from it.
//
// Per scenario: the sections Swift loads, what Dart's launch pass made of
// them, then per step the op, Dart's error copy, whether the store was
// written, the sections whose content changed (their JSON), and the
// models' memory. Swift writes one commit per edit (Dart up to four); the
// expected Swift `changedSections` are recorded next to Dart's.
//
// D6: Dart's rule pass renames rules of both types; Swift only renames
// rules whose type is the renamed category's type or nil. Where the two
// differ, the step records Dart's real rules section (`dartRules`) and the
// section Swift must write (`sections`), and the Dart store is realigned to
// the Swift result before the next step, so later steps compare equal.
//
// catalog.json: the icon registry order and the editor's colour tokens.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/categorization_rule.dart';
import 'package:budget_app/category_definition.dart';
import 'package:budget_app/category_provider.dart';
import 'package:budget_app/category_settings_page.dart';
import 'package:budget_app/common.dart';
import 'package:budget_app/parity_clock.dart';
import 'package:budget_app/recurring_transaction.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';
import 'store_scenarios.dart';

// --- Copied verbatim from category_settings_page.dart (private members) ----

/// CS:381-390 `_colorTokens`.
const colorTokens = [
  'accent',
  'green',
  'blue',
  'orange',
  'red',
  'purple',
  'pink',
  'cyan',
];

/// CS:334-338 `_friendlyError`.
String friendlyError(Object error) {
  if (error is ArgumentError) return error.message.toString();
  if (error is StateError) return error.message;
  return 'Could not update this category';
}

/// CS:283-331, the tail of `_showCategoryEditor` after the dialog returned
/// true (and the 250 ms wait): `context.read<X>()` is `app.x`, and
/// `context.mounted` is always true. `category` is the row the page showed
/// (null for "Add"); `text` is the name field's text.
Future<void> pageSave(
  AppHarness app,
  BudgetCategoryType selectedType,
  BudgetCategory? category,
  String text,
  String iconIdentifier,
  String colorToken,
) async {
  final provider = app.categoryProvider;
  if (category == null) {
    await provider.addCategory(
      type: selectedType,
      name: text,
      iconIdentifier: iconIdentifier,
      colorToken: colorToken,
    );
  } else {
    final newName = text.trim();
    await provider.updateCategory(
      category.id,
      name: newName,
      iconIdentifier: iconIdentifier,
      colorToken: colorToken,
    );
    if (newName != category.name) {
      final transactionType = category.type == BudgetCategoryType.expense
          ? TransactionTyp.expense
          : TransactionTyp.income;
      await app.transactionModel.renameCategory(
        type: transactionType,
        oldName: category.name,
        newName: newName,
      );
      await app.recurringModel.renameCategory(
        type: transactionType,
        oldName: category.name,
        newName: newName,
      );
      await app.categorizationProvider.renameCategory(
        category.name,
        newName,
      );
    }
  }
}

// ---------------------------------------------------------------------------

const cascadeSections = [
  'categories',
  'transactions',
  'categoryBudgetLimits',
  'recurringTransactions',
  'categorizationRules',
];

BudgetCategoryType categoryType(String name) =>
    name == 'income' ? BudgetCategoryType.income : BudgetCategoryType.expense;

/// The models' memory, one JSON line per row. Transactions only when the
/// section bytes are not compared (byte-comparable steps compare them).
Map<String, Object?> memory(AppHarness app, {required bool transactions}) {
  final rules = List<CategorizationRule>.of(app.categorizationProvider.rules)
    ..sort((a, b) => a.id.compareTo(b.id));
  return {
    'categories': [
      for (final c in app.categoryProvider.categories)
        jsonEncode([
          c.id,
          c.type.name,
          c.name,
          c.iconIdentifier,
          c.colorToken,
          c.sortOrder,
          c.isArchived,
          c.isBuiltIn,
        ])
    ],
    'expensePicker': jsonEncode(expenseCategories.keys.toList()),
    'incomePicker': jsonEncode(incomeCategories.keys.toList()),
    'budgets': jsonEncode([
      for (final e in app.transactionModel.categoryBudgetLimits.entries)
        [e.key, e.value.toString()]
    ]),
    if (transactions)
      'transactions': [
        for (final t in app.transactionModel.transactions)
          jsonEncode([t.id, t.type.name, t.category, iso(t.updatedAt)])
      ],
    'templates': [
      for (final t in app.recurringModel.recurringTransactions)
        jsonEncode([t.id, t.type.name, t.category])
    ],
    'rules': [
      for (final r in rules)
        jsonEncode([r.id, r.transactionType?.name, r.category])
    ],
  };
}

Future<Map<String, String?>> sectionStrings() async {
  final sections = (await AtomicFinancialStore.instance.read()).sections;
  return {
    for (final name in cascadeSections)
      name: sections[name] == null ? null : jsonEncode(sections[name]),
  };
}

/// Dart's rules section after a rename (`after`) with D6 applied: a rule of
/// the other type that had the old name (in `before`, same position: the
/// rename pass keeps the order) gets the old name back. Only rules whose
/// type is the renamed category's type, or nil, follow a rename in Swift.
String? rulesAfterD6(
    String? before, String? after, String typeName, String oldName) {
  if (before == null || after == null) return after;
  final was = jsonDecode(before) as List, now = jsonDecode(after) as List;
  if (was.length != now.length) throw StateError('the rule pass changed the list');
  bool otherType(Object? row) =>
      row is Map &&
      (row['category'] as String? ?? 'General') == oldName &&
      row['transactionType'] != null &&
      (row['transactionType'] == 'income' ? 'income' : 'expense') != typeName;
  return jsonEncode([
    for (var i = 0; i < now.length; i++)
      if (otherType(was[i])) {...now[i] as Map, 'category': oldName} else now[i]
  ]);
}

/// Resolves a category reference: an int indexes the stored list, a string
/// is an id (possibly unknown).
String resolveId(AppHarness app, Object? ref) =>
    ref is int ? app.categoryProvider.categories[ref].id : ref as String;

/// Runs `ops` against the store holding `initial` (or the store the
/// `build` callback makes), recording every step.
Future<Map<String, Object?>> runScenario({
  required String name,
  required bool byteComparable,
  required List launch,
  Map<String, Object?>? initial,
  Future<void> Function(AppHarness app)? build,
  List<List>? ops,
  List<List> Function(AppHarness app, Random random)? generate,
  int seed = 1,
  int steps = 0,
}) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('categories_fixture');
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final store = AtomicFinancialStore.instance;
  seedUuids(seed);
  if (build != null) {
    await build(AppHarness());
  } else if (initial != null && initial.isNotEmpty) {
    await store.updateSections(initial);
  }
  final initialSections = jsonEncode((await store.read()).sections);

  var clock = local(launch);
  pinClock(clock);
  final app = AppHarness();
  await app.initialize(generate: false);
  final launched = {
    'sections': await sectionStrings(),
    'memory': memory(app, transactions: !byteComparable),
  };

  final random = Random(seed);
  final recorded = <Map<String, Object?>>[];
  final opList = ops ?? <List>[];
  var index = 0;
  while (true) {
    List op;
    if (generate != null) {
      if (index >= steps) break;
      op = generate(app, random).first;
    } else {
      if (index >= opList.length) break;
      op = opList[index];
    }
    index++;
    if (op[0] == 'clock') {
      clock = local(op[1] as List);
      pinClock(clock);
      continue;
    }
    // Every step runs a little later than the previous one.
    clock = clock.add(const Duration(seconds: 1, microseconds: 1234));
    pinClock(clock);

    final before = await sectionStrings();
    final revision = (await store.read()).revision;
    final step = <String, Object?>{'op': op[0], 'now': iso(clock)};
    String? error;
    String? cascadeType, oldName;
    try {
      switch (op[0]) {
        case 'add':
          final count = app.categoryProvider.categories.length;
          step.addAll({
            'type': op[1],
            'name': op[2],
            'icon': op[3],
            'color': op[4],
          });
          try {
            await pageSave(app, categoryType(op[1] as String), null,
                op[2] as String, op[3] as String, op[4] as String);
          } finally {
            step['newId'] = app.categoryProvider.categories.length > count
                ? app.categoryProvider.categories.last.id
                : null;
          }
        case 'edit':
          final id = resolveId(app, op[1]);
          final shown = app.categoryProvider.categories
              .where((c) => c.id == id)
              .firstOrNull;
          step.addAll({
            'id': id,
            'name': op[2],
            'icon': op[3],
            'color': op[4],
          });
          if (shown == null) {
            // Unreachable from the page: nothing to edit.
            step['unknown'] = true;
          } else {
            await pageSave(app, shown.type, shown, op[2] as String,
                op[3] as String, op[4] as String);
            if ((op[2] as String).trim() != shown.name) {
              cascadeType = shown.type.name;
              oldName = shown.name;
            }
          }
        case 'archive':
          final id = resolveId(app, op[1]);
          step.addAll({'id': id, 'archived': op[2]});
          await app.categoryProvider.setArchived(id, op[2] as bool);
        case 'move':
          final id = resolveId(app, op[1]);
          step.addAll({'id': id, 'offset': op[2]});
          await app.categoryProvider.moveCategory(id, op[2] as int);
        default:
          throw ArgumentError('unknown op ${op[0]}');
      }
    } on Object catch (e) {
      error = friendlyError(e);
    }
    step['error'] = error;
    final wrote = (await store.read()).revision != revision;
    var after = await sectionStrings();

    // D6: realign Dart's rules to what Swift writes.
    var d6 = false;
    if (cascadeType != null) {
      final expected = rulesAfterD6(before['categorizationRules'],
          after['categorizationRules'], cascadeType, oldName!);
      if (expected != null && expected != after['categorizationRules']) {
        d6 = true;
        step['dartRules'] = after['categorizationRules'];
        await store.updateSections(
            {'categorizationRules': jsonDecode(expected)});
        await app.categorizationProvider.load();
        after = await sectionStrings();
        if (after['categorizationRules'] != expected) {
          throw StateError('D6 realignment failed');
        }
      }
    }

    final changed = [
      for (final s in cascadeSections)
        if (after[s] != before[s]) s
    ];
    step.addAll({
      'wrote': wrote,
      'd6': d6,
      // Swift's one commit: the categories section whenever Dart wrote
      // anything (every write starts with it), then the other sections
      // whose content changed.
      'changedSections': [
        if (wrote) 'categories',
        for (final s in changed)
          if (s != 'categories') s
      ],
      'sections': {for (final s in changed) s: after[s]},
      // Unchanged since the last step that wrote (or the launch) otherwise.
      'memory': wrote ? memory(app, transactions: !byteComparable) : null,
    });
    if (app.transactionModel.hasUnsavedChanges ||
        app.recurringModel.hasUnsavedChanges) {
      throw StateError('a Dart save failed in $name');
    }
    recorded.add(step);
  }

  final result = {
    'name': name,
    'byteComparable': byteComparable,
    'launch': iso(local(launch)),
    'initialSections': initialSections,
    'launched': launched,
    'steps': recorded,
  };
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  seedParityUuids(null);
  pinClock(null);
  return result;
}

// --- Initial states ----------------------------------------------------------

Future<void> addTx(AppHarness app, TransactionTyp type, String description,
    double amount, String category, DateTime date) async {
  if (!await app.transactionModel
      .addTransaction(type, description, amount, category, date)) {
    throw StateError('save failed');
  }
}

Future<void> addTemplate(AppHarness app, TransactionTyp type,
    String description, double amount, String category) async {
  if (!await app.recurringModel.addRecurringTransaction(RecurringTransaction(
    type: type,
    description: description,
    amount: amount,
    category: category,
    pattern: RecurrencePattern.monthly,
    startDate: DateTime(2026, 1, 12),
    dayOfMonth: 12,
  ))) {
    throw StateError('template save failed');
  }
}

/// The typical store plus uses of the same names in every section and in
/// both types: rules typed expense, income and nil; templates; case and
/// NFC/NFD variants; a budget key whose case variant also has a limit.
Future<void> buildCascadeStore(AppHarness app) async {
  await buildTypicalStore(app);
  final clock = TickingClock(DateTime(2026, 9, 21, 10, 0, 0, 0, 7));
  const e = TransactionTyp.expense, i = TransactionTyp.income;
  final rules = app.categorizationProvider;
  final work = rules.tags.first.id;
  for (final rule in [
    CategorizationRule(
        merchantPattern: 'gift shop',
        category: 'Gift',
        transactionType: e,
        tagIds: [work],
        priority: 1),
    CategorizationRule(
        merchantPattern: 'grandma', category: 'Gift', transactionType: i),
    CategorizationRule(merchantPattern: 'present', category: 'Gift'),
    CategorizationRule(
        merchantPattern: 'kibble barn',
        category: 'Pet Food',
        transactionType: e,
        isEnabled: false),
    CategorizationRule(
        merchantPattern: 'pet sitting', category: 'Pet Food', transactionType: i),
    CategorizationRule(
        merchantPattern: 'metro',
        category: 'Transportation',
        transactionType: e,
        minimumAmount: 2.5,
        maximumAmount: 40.0),
  ]) {
    clock.tick();
    await rules.addRule(rule);
  }
  clock.tick();
  await addTemplate(app, e, 'Gift club', 20.0, 'Gift');
  await addTemplate(app, i, 'Allowance', 15.0, 'Gift');
  await addTemplate(app, e, 'Kibble box', 30.0, 'Pet Food');
  for (final (type, description, amount, category) in [
    (e, 'lowercase gift', 5.0, 'gift'),
    (e, 'coffee nfc', 3.5, 'Café'),
    (e, 'coffee nfd', 4.5, 'Café'),
    (i, 'housing refund', 120.0, 'Housing'),
    (e, 'more gifts', 42.0, 'Gift'),
  ]) {
    clock.tick();
    await addTx(app, type, description, amount, category, DateTime(2026, 9, 11));
  }
  final model = app.transactionModel;
  for (final (name, limit) in [
    ('Gift', 75.0),
    ('Housing', 1500.0),
    ('housing', 70.0),
    ('Transportation', 30.0),
  ]) {
    clock.tick();
    await model.setCategoryBudgetLimit(name, limit);
  }
}

/// A small store for the random sequences: names from the sequence pool in
/// every section and both types.
Future<void> buildSequenceStore(AppHarness app) async {
  await app.initialize(generate: false);
  final clock = TickingClock(DateTime(2026, 5, 2, 8, 30, 0, 0, 11));
  const e = TransactionTyp.expense, i = TransactionTyp.income;
  var n = 0;
  for (final (type, category) in [
    (e, 'Gift'),
    (i, 'Gift'),
    (e, 'gift'),
    (e, 'Food'),
    (e, 'Café'),
    (e, 'Café'),
    (i, 'Salary'),
    (e, 'Rent'),
    (e, 'Ꭰ'),
    (i, 'Other'),
    (e, 'Gift'),
  ]) {
    clock.tick();
    n++;
    await addTx(app, type, 'row $n', n * 1.25, category, DateTime(2026, 4, n));
  }
  await addTemplate(app, e, 'Gift club', 20.0, 'Gift');
  await addTemplate(app, i, 'Allowance', 15.0, 'Gift');
  await addTemplate(app, e, 'Rent', 900.0, 'Rent');
  for (final rule in [
    CategorizationRule(
        merchantPattern: 'gift', category: 'Gift', transactionType: e),
    CategorizationRule(
        merchantPattern: 'gift', category: 'Gift', transactionType: i),
    CategorizationRule(merchantPattern: 'any', category: 'Gift'),
    CategorizationRule(
        merchantPattern: 'rent', category: 'Rent', transactionType: i),
    CategorizationRule(
        merchantPattern: 'cafe', category: 'Café', transactionType: e),
  ]) {
    clock.tick();
    await app.categorizationProvider.addRule(rule);
  }
  for (final (name, limit) in [
    ('Gift', 50.0),
    ('Food', 200.0),
    ('food', 25.0),
    ('Café', 12.5),
  ]) {
    clock.tick();
    await app.transactionModel.setCategoryBudgetLimit(name, limit);
  }
}

const namePool = [
  'Gift', 'gift', 'GIFT', 'Food', 'food ', ' Rent', 'Rent', 'Café',
  'Café', 'ß', 'SS', 'İstanbul', 'istanbul', 'Pets', 'Travel',
  'Other', 'Salary', 'X', 'Ꭰ', 'ꭰ', '', '  ', '\u{FEFF}', 'New 1', 'New 2',
];

List<List> randomOp(AppHarness app, Random random) {
  final categories = app.categoryProvider.categories;
  String pick(List<String> from) => from[random.nextInt(from.length)];
  final icons = [...categoryIconRegistry.keys, 'nope'];
  final colors = [...colorTokens, 'teal'];
  final roll = random.nextInt(100);
  if (roll < 25) {
    return [
      [
        'add',
        random.nextBool() ? 'expense' : 'income',
        pick(namePool),
        pick(icons),
        pick(colors)
      ]
    ];
  }
  final target = random.nextInt(categories.length);
  if (roll < 65) {
    final keepName = random.nextInt(4) == 0;
    return [
      [
        'edit',
        target,
        keepName ? categories[target].name : pick(namePool),
        pick(icons),
        pick(colors)
      ]
    ];
  }
  if (roll < 80) {
    return [
      ['archive', target, random.nextInt(3) != 0]
    ];
  }
  return [
    ['move', target, random.nextInt(7) - 3]
  ];
}

// --- Scenarios ---------------------------------------------------------------

final addOps = <List>[
  ['add', 'expense', '  Coffee  ', 'cart', 'green'],
  ['add', 'expense', 'coffee', 'cart', 'green'],
  ['add', 'expense', 'COFFEE', 'cart', 'green'],
  ['add', 'income', 'Coffee', 'money', 'blue'],
  ['add', 'expense', '\tTea\u{FEFF}', 'leaf', 'cyan'],
  ['add', 'expense', '', 'cart', 'accent'],
  ['add', 'expense', '   ', 'cart', 'accent'],
  ['add', 'expense', '\u{FEFF}', 'cart', 'accent'],
  ['add', 'expense', 'Nope Icon', 'nope', 'teal'],
  ['add', 'expense', 'Empty Icon', '', ''],
  ['add', 'expense', 'Café', 'book', 'orange'],
  ['add', 'expense', 'Café', 'book', 'orange'],
  ['add', 'income', 'Side Gig ✨', 'wrench', 'orange'],
  ['add', 'expense', 'A  B', 'car', 'red'],
  ['add', 'expense', '@@@', 'phone', 'pink'],
  ['add', 'expense', '###', 'phone', 'pink'],
  ['add', 'expense', 'Gift!', 'gift', 'purple'],
  ['add', 'expense', 'gift', 'gift', 'purple'],
  ['add', 'income', 'GIFT', 'gift', 'purple'],
  ['archive', 'expense-coffee', true],
  ['add', 'expense', 'Coffee', 'cart', 'green'],
  ['add', 'expense', 'İstanbul', 'airplane', 'blue'],
  ['add', 'expense', 'istanbul', 'airplane', 'blue'],
  ['add', 'expense', 'ISTANBUL', 'airplane', 'blue'],
  ['add', 'expense', 'ß', 'bag', 'pink'],
  ['add', 'expense', 'SS', 'bag', 'pink'],
  ['add', 'expense', 'ẞ', 'bag', 'pink'],
  ['add', 'expense', 'ΑΣ', 'heart', 'red'],
  ['add', 'expense', 'ας', 'heart', 'red'],
  ['add', 'expense', 'Ꭰ', 'film', 'cyan'],
  ['add', 'expense', 'ꭰ', 'film', 'cyan'],
  ['add', 'expense', 'K', 'film', 'cyan'],
  ['add', 'expense', 'k', 'film', 'cyan'],
  ['add', 'expense', 'x' * 300, 'money', 'green'],
  ['add', 'income', '  Side Gig ✨ ', 'wrench', 'orange'],
];

final editOps = <List>[
  ['edit', 'expense-eating-out', 'Eating Out', 'cart', 'red'],
  ['edit', 'expense-eating-out', '  Eating Out ', 'cart', 'red'],
  ['edit', 'expense-groceries', 'Groceries', 'nope', 'teal'],
  ['edit', 'expense-groceries', 'groceries', 'cart', 'green'],
  ['edit', 'expense-groceries', 'Housing', 'cart', 'green'],
  ['edit', 'expense-groceries', 'HOUSING', 'cart', 'green'],
  ['edit', 'expense-groceries', 'Salary', 'cart', 'green'],
  ['edit', 'expense-groceries', '', 'cart', 'green'],
  ['edit', 'expense-groceries', ' \u{FEFF} ', 'cart', 'green'],
  ['edit', 'missing-id', '', 'cart', 'green'],
  ['edit', 'missing-id', 'Ghost', 'cart', 'green'],
  ['archive', 'expense-travel', true],
  ['edit', 'expense-travel', 'Trips', 'airplane', 'cyan'],
  ['edit', 'expense-general', 'Trips', 'airplane', 'cyan'],
  ['edit', 'income-gift', 'Trips', 'gift', 'purple'],
  ['edit', 'income-gift', ' Présents ', 'gift', 'purple'],
  ['edit', 'income-gift', 'Présents', 'gift', 'purple'],
];

final archiveMoveOps = <List>[
  ['archive', 'income-salary', true],
  ['archive', 'income-salary', true],
  ['archive', 'income-investment', true],
  ['archive', 'income-gift', true],
  ['archive', 'income-other', true],
  ['archive', 'income-salary', false],
  ['archive', 'income-other', true],
  ['archive', 'income-salary', false],
  ['archive', 'missing-id', true],
  ['archive', 'missing-id', false],
  ['move', 'expense-general', -1],
  ['move', 'expense-general', 0],
  ['move', 'expense-general', 1],
  ['move', 'expense-general', 100],
  ['move', 'expense-general', -100],
  ['archive', 'expense-housing', true],
  ['archive', 'expense-travel', true],
  ['move', 'expense-transportation', -1],
  ['move', 'expense-transportation', 1],
  ['move', 'expense-housing', 3],
  ['move', 'expense-loan-payment', 1],
  ['move', 'expense-loan-payment', -12],
  ['move', 'income-other', -2],
  ['move', 'income-investment', 9223372036854775807],
  ['archive', 'expense-housing', false],
  ['move', 'expense-housing', -5],
];

final cascadeOps = <List>[
  ['edit', 'expense-gift', 'Presents', 'gift', 'purple'],
  ['edit', 'income-gift', 'Presents', 'gift', 'purple'],
  ['edit', 'expense-housing', 'housing', 'house', 'blue'],
  ['edit', 'expense-pet-food', 'Pets & Food', 'paw', 'green'],
  ['edit', 'expense-caf', 'Coffee', 'book', 'orange'],
  ['edit', 'expense-transportation', 'Transit', 'car', 'purple'],
  ['edit', 'expense-eating-out', 'Eating Out', 'cart', 'orange'],
  ['edit', 'expense-eating-out', ' Eating Out ', 'cart', 'orange'],
  ['edit', 'expense-groceries', 'Food', 'cart', 'green'],
  ['edit', 'expense-groceries', 'Groceries', 'cart', 'green'],
  ['edit', 'expense-travel', 'Trips', 'airplane', 'cyan'],
  ['edit', 'expense-groceries', 'Eating Out', 'cart', 'green'],
  ['edit', 'expense-groceries', '  ', 'cart', 'green'],
  ['edit', 'income-salary', 'Paycheck', 'money', 'green'],
  ['clock', [2020, 1, 2, 3, 4, 5, 6, 7]],
  ['edit', 'expense-gift', 'Gifts', 'gift', 'purple'],
  ['archive', 'expense-clothing', true],
  ['edit', 'expense-clothing', 'Apparel', 'bag', 'pink'],
  ['edit', 'expense-housing', 'HOUSING', 'house', 'blue'],
];

Map<String, Object?> foreignSections() => {
      'categories': [
        {
          'id': 'expense-general',
          'type': 'expense',
          'name': 'General',
          'iconIdentifier': 'square_grid_2x2',
          'colorToken': 'accent',
          'sortOrder': 0,
          'isArchived': false,
          'isBuiltIn': true,
          'future': {
            'x': [1, 2.50]
          },
        },
        {'id': 'expense-food', 'name': 'Food', 'sortOrder': 2.0},
        {
          'isBuiltIn': true,
          'sortOrder': 1,
          'colorToken': 'purple',
          'iconIdentifier': 'gift',
          'name': 'Gift',
          'type': 'expense',
          'id': 'expense-gift',
          'note': 'keep',
        },
        {
          'id': 'income-salary',
          'type': 'income',
          'name': 'Salary',
          'sortOrder': 0,
          'isBuiltIn': true,
          'iconIdentifier': null,
        },
        {'id': 'income-gift', 'type': 'income', 'name': 'Gift', 'sortOrder': 7},
        {
          'id': 'weird',
          'type': 'garbage',
          'name': 'Weird',
          'sortOrder': 5,
          'isArchived': true,
        },
      ],
      'transactions': [
        {
          'id': 't1',
          'type': 'expense',
          'description': 'kept keys',
          'amount': 12,
          'category': 'Food',
          'date': '2026-03-04T00:00:00.000',
          'recurringTemplateId': null,
          'tagIds': [],
          'createdAt': '2026-03-04T10:00:00.000',
          'updatedAt': '2026-03-04T10:00:00.000',
          'merchant': {'name': 'ACME'},
        },
        {
          'updatedAt': '2026-03-05T10:00:00.000Z',
          'createdAt': '2026-03-05T10:00:00.000Z',
          'category': 'Gift',
          'date': '2026-03-05',
          'amount': 20.5,
          'description': 'reordered',
          'type': 'expense',
          'id': 't2',
        },
        {
          'id': 't3',
          'type': 'income',
          'description': 'income gift',
          'amount': 30.0,
          'category': 'Gift',
          'date': '2026-03-06T00:00:00.000',
          'createdAt': '2026-03-06T10:00:00.000',
          'updatedAt': '2026-03-06T10:00:00.000',
        },
      ],
      'recurringTransactions': [
        {
          'id': 'r1',
          'type': 'expense',
          'description': 'food box',
          'amount': 30.0,
          'category': 'Food',
          'pattern': 'monthly',
          'startDate': '2026-01-10T00:00:00.000',
          'nextOccurrence': '2026-02-10T00:00:00.000',
          'dayOfMonth': 10,
          'extra': [1],
        },
      ],
      'categorizationRules': [
        {
          'id': 'rule-1',
          'merchantPattern': '  market ',
          'matchType': 'weird',
          'transactionType': null,
          'category': 'Food',
          'tagIds': ['t', 7],
          'priority': 2.0,
          'future': true,
        },
        {
          'id': 'rule-2',
          'merchantPattern': 'gift',
          'transactionType': 'income',
          'category': 'Gift',
        },
      ],
      'categoryBudgetLimits': {'Food': 100, 'Gift': 50.5, 'Zero': 0},
    };

final foreignOps = <List>[
  ['edit', 'expense-food', 'Groceries', 'cart', 'green'],
  ['edit', 'expense-gift', 'Presents', 'gift', 'purple'],
  ['archive', 'weird', false],
  ['move', 'weird', -9],
  ['edit', 'income-gift', 'Bonus', 'money', 'green'],
  ['add', 'expense', 'Zero', 'cart', 'accent'],
  ['edit', 'expense-zero', 'Zero Two', 'cart', 'accent'],
  ['edit', 'income-salary', 'Salary', 'money', 'green'],
];

Future<List<Map<String, Object?>>> allScenarios() async => [
      await runScenario(
          name: 'add',
          byteComparable: true,
          launch: [2026, 9, 28, 9, 15, 30, 250, 125],
          ops: addOps),
      await runScenario(
          name: 'edit',
          byteComparable: true,
          launch: [2026, 9, 28, 9, 15, 30, 250, 125],
          ops: editOps),
      await runScenario(
          name: 'archive_move',
          byteComparable: true,
          launch: [2026, 9, 28, 9, 15, 30, 250, 125],
          ops: archiveMoveOps),
      await runScenario(
          name: 'cascade',
          byteComparable: true,
          launch: [2026, 9, 28, 9, 15, 30, 250, 125],
          build: buildCascadeStore,
          ops: cascadeOps),
      await runScenario(
          name: 'foreign',
          byteComparable: false,
          launch: [2026, 9, 28, 9, 15, 30, 250, 125],
          initial: foreignSections(),
          ops: foreignOps),
      for (final seed in [11, 22, 33])
        await runScenario(
            name: 'sequence_$seed',
            byteComparable: true,
            launch: [2026, 9, 28, 9, 15, 30, 250, 125],
            build: buildSequenceStore,
            generate: randomOp,
            seed: seed,
            steps: 120),
    ];

// --- The canary: the real page's rename against `pageSave` -----------------

/// Lets the page's chain of real store writes run to the end: waits until
/// the store revision has been still for a while (the cascade is up to
/// four commits, each awaited before the next starts).
Future<void> settle(WidgetTester tester, {required int from}) async {
  var last = from, still = 0;
  for (var i = 0; i < 1000 && (last == from || still < 25); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
    late int revision;
    await tester.runAsync(() async =>
        revision = (await AtomicFinancialStore.instance.read()).revision);
    still = revision == last ? still + 1 : 0;
    last = revision;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('category mutations', () async {
    final dir = fixtureDir('categories').path;
    writeJson('$dir/mutations.json', {
      'tz': parityTz,
      'scenarios': await allScenarios(),
    });
    writeJson('$dir/catalog.json', {
      'iconIdentifiers': categoryIconRegistry.keys.toList(),
      'colorTokens': colorTokens,
    });
  });

  testWidgets('canary: the real page renames like pageSave',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // One store state for both runs.
    late String initial;
    final launch = local([2026, 9, 28, 9, 15, 30, 250, 125]);
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('categories_canary');
      await AtomicFinancialStore.instance.resetForTesting(directory: dir);
      seedUuids(5);
      await buildCascadeStore(AppHarness());
      initial = jsonEncode((await AtomicFinancialStore.instance.read()).sections);
    });

    Future<AppHarness> fresh() async {
      final app = AppHarness();
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final dir = await Directory.systemTemp.createTemp('categories_canary');
        await AtomicFinancialStore.instance.resetForTesting(directory: dir);
        await AtomicFinancialStore.instance
            .updateSections(jsonDecode(initial) as Map<String, dynamic>);
        pinClock(launch);
        await app.initialize(generate: false);
      });
      return app;
    }

    // The real page: row menu, Edit, type the name, Save.
    final app = await fresh();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
          ChangeNotifierProvider<TransactionModel>.value(
              value: app.transactionModel),
          ChangeNotifierProvider<RecurringTransactionModel>.value(
              value: app.recurringModel),
          ChangeNotifierProvider<CategoryProvider>.value(
              value: app.categoryProvider),
          ChangeNotifierProvider<CategorizationProvider>.value(
              value: app.categorizationProvider),
        ],
        child: const MaterialApp(home: CategorySettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.ancestor(
        of: find.text('Gift'), matching: find.byType(ListTile));
    expect(row, findsOneWidget);
    await tester.tap(find.descendant(
        of: row, matching: find.byTooltip('Category actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '  Presents ');
    await tester.pumpAndSettle();
    late int before;
    await tester.runAsync(() async =>
        before = (await AtomicFinancialStore.instance.read()).revision);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester, from: before);
    late Map<String, String?> viaPage;
    await tester.runAsync(() async => viaPage = await sectionStrings());
    await tester.pumpWidget(const SizedBox());

    // The verbatim copy on the same state and clock.
    final copy = await fresh();
    late Map<String, String?> viaCopy;
    await tester.runAsync(() async {
      final gift = copy.categoryProvider.categories
          .firstWhere((c) => c.id == 'expense-gift');
      await pageSave(copy, BudgetCategoryType.expense, gift, '  Presents ',
          gift.iconIdentifier, gift.colorToken);
      viaCopy = await sectionStrings();
      await AtomicFinancialStore.instance.resetForTesting();
    });
    pinClock(null);
    seedParityUuids(null);

    expect(viaPage['categories'], contains('"Presents"'));
    for (final section in cascadeSections) {
      expect(viaPage[section], viaCopy[section], reason: section);
    }
  });
}
