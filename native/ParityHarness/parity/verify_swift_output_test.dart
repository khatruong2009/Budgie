// Loads every store the Swift side wrote through the real Dart store and
// models, and fails loudly on anything the Flutter app would reject, drop,
// or silently reset. This is the proof that the Flutter build can be
// reinstalled over the Swift app.
//
// Layout of $SWIFT_OUT/<case>/:
//   financial_store/   files written by BudgieCore
//   prefs.json         typed preferences (optional)
//   swift.json         {"revision": int, "sectionsFnv": "<fnv of Dart-canonical sections>",
//                       every date is a cell [ISO text, epoch microseconds]:
//                       both are compared (the text of an instant in a
//                       repeated DST hour is the same for both occurrences);
//                       optional "categoryBudgetLimits", "netWorthEntries",
//                       "selectedNetWorthMonth", "savingsGoals", "appSettings",
//                       "themeMode", "categories", "categoriesAddedAtLaunch",
//                       "transactionCategories", "templateCategories",
//                       "ruleCategories", "transactionTags",
//                       "categorizationRules", "recurringTemplates",
//                       "transactions": what the Dart models must hold;
//                       "ruleSuggestions": [type, description, amount
//                       lexeme, rule id or null] probes Dart's `suggest`
//                       must answer as Swift did;
//                       "newTagIds", "newRuleIds": rows Swift made;
//                       "dartGenerateAddsNothing": run Dart's generator last
//                       and fail if it adds rows or moves cursors;
//                       "onboardingCompleted": what the onboarding gate reads;
//                       optional "backup": {"appVersion", "exportedAt", "themeMode"};
//                       optional "insights": what the insight preferences
//                       load as, and the cards shown at a clock}
//   now.txt            optional: the clock (Dart local ISO text) to load and
//                       summarize at instead of launchNow: the "now" of the
//                       app run that wrote the files (upgrade_rehearsal.py)
//   backup.json        optional: Swift's backup export of this store after a
//                       launch (see verifyBackup)
//   export.csv         optional: Swift's CSV export of the ledger; swift.json
//                       "csvImport" is what the importer must make of it (see
//                       csvProblems)
//
// The whole run is under one zone (VERIFY_TZ in run.sh = the zone Swift wrote
// the stores in, BUDGIE_SWIFT_ZONE). The summary of every loaded store
// (`summarize`, at the launch clock or now.txt) goes to dart-verification.json, where
// the Swift side compares it with its own numbers (DartSummaryOfSwiftStores).
//
// Writes $SWIFT_OUT/dart-verification.json and fails if any case failed.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:budget_app/backup.dart';
import 'package:budget_app/categorization_rule.dart';
import 'package:budget_app/insights/insight_engine.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/storage/storage_keys.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_generator.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/transaction_tag.dart';
import 'package:budget_app/widgets/glow_card.dart';
import 'package:budget_app/widgets/local_insights_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixture_runner.dart';
import 'harness_support.dart';
import 'model_summary.dart';

/// A Swift-exported backup of the store in [dir]:
///  1. equals Flutter's export of the same store after a launch (load and
///     recurring generation), ids generated during that launch aside;
///  2. `decodeBackup` accepts it;
///  3. restored into an empty store by the page's restore chain, then
///     exported again, it is the same file.
Future<List<String>> verifyBackup(Directory dir, File backupFile,
    Map<String, dynamic> spec, Map<String, Object> prefs) async {
  final problems = <String>[];
  final bytes = backupFile.readAsBytesSync();
  final swiftText = utf8.decode(bytes);
  final appVersion = spec['appVersion'] as String;
  final exportedAt = DateTime.parse(spec['exportedAt'] as String);
  final theme = themeFrom(spec['themeMode'] as String?);
  String firstDifference(String a, String b) {
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    final from = max(0, i - 80);
    return 'at $i: swift «${a.substring(from, min(a.length, i + 80))}» '
        'dart «${b.substring(from, min(b.length, i + 80))}»';
  }

  // 1. Flutter's export after its own launch of the same files.
  final work = await Directory.systemTemp.createTemp('verify_backup');
  final storeDir = Directory('${work.path}/financial_store');
  copyDir(Directory('${dir.path}/financial_store'), storeDir);
  SharedPreferences.setMockInitialValues(Map.of(prefs));
  pinClock(launchNow);
  await AtomicFinancialStore.instance.resetForTesting(directory: storeDir);
  final sections = (await AtomicFinancialStore.instance.read()).sections;
  final launched = AppHarness();
  await launched.initialize(generate: true);
  final dartText = encodeBackup(exportData(launched, theme),
      appVersion: appVersion, exportedAt: exportedAt);
  final aligned = alignGeneratedIds(swiftText, dartText, sections);
  if (aligned == null) {
    problems.add('backup: generated ids differ in number');
  } else if (aligned != dartText) {
    problems.add('backup: Flutter export differs ${firstDifference(aligned, dartText)}');
  }

  // 2. Flutter reads it.
  BackupData? decoded;
  try {
    decoded = decodeBackup(utf8.decode(bytes, allowMalformed: true));
  } catch (error) {
    problems.add('backup: decodeBackup threw $error');
  }

  // 3. Restore into an empty store, export again.
  if (decoded != null) {
    final restoreWork = await Directory.systemTemp.createTemp('verify_restore');
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting(
        directory: Directory('${restoreWork.path}/financial_store'));
    final restored = AppHarness();
    await restored.initialize(generate: false);
    final themeProvider = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    try {
      await restoreChain(restored, themeProvider, decoded);
      final again = encodeBackup(exportData(restored, themeProvider.themeMode),
          appVersion: appVersion, exportedAt: exportedAt);
      if (again != swiftText) {
        problems.add('backup: restore then export differs ${firstDifference(swiftText, again)}');
      }
      if (restored.transactionModel.hasUnsavedChanges ||
          restored.recurringModel.hasUnsavedChanges) {
        problems.add('backup: unsaved changes after the restore');
      }
    } catch (error) {
      problems.add('backup: restore threw $error');
    }
  }
  return problems;
}

/// Copied verbatim from `_LocalInsightsSectionState._loadPreferences`
/// (local_insights_section.dart:36-64; its fields are private), returning
/// what it would put in `_dismissedIds` and `_snoozedUntil`.
Future<(Set<String>, Map<String, DateTime>)> loadInsightPreferences() async {
  const dismissedKey = 'local_insights_dismissed_v1';
  const snoozedKey = 'local_insights_snoozed_v1';
  final prefs = await SharedPreferences.getInstance();
  final dismissed = prefs.getStringList(dismissedKey) ?? const [];
  final rawSnoozed = prefs.getString(snoozedKey);
  final snoozed = <String, DateTime>{};
  if (rawSnoozed != null) {
    try {
      final decoded = jsonDecode(rawSnoozed) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final date = DateTime.tryParse(entry.value as String);
        if (date != null) snoozed[entry.key] = date;
      }
    } on FormatException {
      // Ignore only this optional UI preference if it becomes malformed.
    } on TypeError {
      // Older or invalid values should not prevent the dashboard loading.
    }
  }
  return (<String>{...dismissed}, snoozed);
}

/// The insight checks for one case: Flutter's preference load holds what
/// Swift wrote, and the real engine shows the cards Swift computed.
Future<List<String>> insightProblems(
    Map<String, dynamic> insights, AppHarness app) async {
  final problems = <String>[];
  final (dismissed, snoozed) = await loadInsightPreferences();
  final dartDismissed = jsonEncode(dismissed.toList());
  if (dartDismissed != jsonEncode(insights['dismissed'])) {
    problems.add('insight dismissals: dart $dartDismissed swift ${jsonEncode(insights['dismissed'])}');
  }
  final dartSnoozed = jsonEncode([
    for (final e in snoozed.entries) [e.key, cell(e.value)]
  ]);
  if (dartSnoozed != jsonEncode(insights['snoozed'])) {
    problems.add('insight snoozes: dart $dartSnoozed swift ${jsonEncode(insights['snoozed'])}');
  }
  final now = DateTime.parse(insights['now'] as String);
  final excluded = <String>{
    ...dismissed,
    for (final e in snoozed.entries)
      if (e.value.isAfter(now)) e.key,
  };
  final visible = const InsightEngine().generate(
    transactions: app.transactionModel.transactions,
    categoryBudgetLimits: app.transactionModel.categoryBudgetLimits,
    savingsGoals: app.transactionModel.savingsGoals,
    selectedMonth: DateTime.parse(insights['selectedMonth'] as String),
    now: now,
    excludedIds: excluded,
  );
  final dartVisible = jsonEncode([
    for (final i in visible)
      [i.id, i.headline, i.explanation, i.suggestedAction]
  ]);
  if (dartVisible != jsonEncode(insights['visible'])) {
    problems.add('insight cards: dart $dartVisible swift ${jsonEncode(insights['visible'])}');
  }
  return problems;
}

/// A date as the Swift side writes it: its ISO text and its instant. The
/// text alone cannot tell the two occurrences of a repeated DST hour apart.
List<Object> cell(DateTime date) =>
    [iso(date), date.microsecondsSinceEpoch];

/// Swift's CSV export of a ledger read by Flutter's importer
/// (`TransactionModel.parseTransactionsCsv`): over this store's
/// transactions and over none, the rows it imports, the duplicates it skips
/// and the errors it reports must be what Swift's importer made of the same
/// file.
List<String> csvProblems(
    String text, Map<String, dynamic> expected, TransactionModel existing) {
  final problems = <String>[];
  void check(String label, TransactionModel model, Object? want) {
    final CsvImportSummary summary;
    try {
      summary = model.parseTransactionsCsv(text);
    } catch (error) {
      problems.add('csv ($label): parseTransactionsCsv threw $error');
      return;
    }
    final dart = jsonEncode({
      'drafts': [
        for (final t in summary.transactions)
          [
            cell(t.date),
            t.type.name,
            t.category.codeUnits,
            t.description.codeUnits,
            t.amount.toString(),
          ]
      ],
      'duplicates': summary.duplicateCount,
      'rowErrors': summary.rowErrors,
    });
    final swift = jsonEncode(want);
    if (dart != swift) {
      problems.add('csv ($label): dart $dart swift $swift');
    }
  }

  check('with the store\'s rows', existing, expected['existing']);
  check('into an empty ledger', TransactionModel(), expected['empty']);
  return problems;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory(Platform.environment['SWIFT_OUT'] ??
      (throw StateError('SWIFT_OUT not set')));
  final cases = root.existsSync()
      ? (root.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <Directory>[];
  final report = <String, Object?>{};

  tearDownAll(() {
    writeJson('${root.path}/dart-verification.json', {
      'commit': parityCommit,
      'tz': parityTz,
      'cases': report,
    });
  });

  test('there is something to verify', () {
    expect(cases, isNotEmpty, reason: 'no Swift output under ${root.path}');
  });

  for (final dir in cases) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    test(name, () async {
      final problems = <String>[];
      // swift.json is optional: files pulled from a simulator have no
      // Swift-side expectation, only the load checks below.
      final swiftFile = File('${dir.path}/swift.json');
      final swift = swiftFile.existsSync()
          ? jsonDecode(swiftFile.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      final prefs = prefsFrom(File('${dir.path}/prefs.json'));
      final nowFile = File('${dir.path}/now.txt');
      final now = nowFile.existsSync()
          ? DateTime.parse(nowFile.readAsStringSync().trim())
          : launchNow;

      // Work on a copy: loading may legitimately write (restore, migration).
      final work = await Directory.systemTemp.createTemp('verify_$name');
      final storeDir = Directory('${work.path}/financial_store');
      copyDir(Directory('${dir.path}/financial_store'), storeDir);

      SharedPreferences.setMockInitialValues(Map.of(prefs));
      pinClock(now);
      await AtomicFinancialStore.instance.resetForTesting(directory: storeDir);
      final snapshot = await AtomicFinancialStore.instance.read();
      if (swift.isNotEmpty && snapshot.revision != swift['revision']) {
        problems.add('revision: dart ${snapshot.revision} swift ${swift['revision']}');
      }
      final canonical = sectionsJson(snapshot);
      if (swift.isNotEmpty && canonical['fnv'] != swift['sectionsFnv']) {
        problems.add('sections differ: dart ${canonical['fnv']} swift ${swift['sectionsFnv']}');
      }
      final filesBefore = listing(storeDir);

      // Full app load, as a reinstalled Flutter build would do it.
      final app = AppHarness();
      Map<String, Object?>? summary;
      try {
        await app.initialize(generate: false);
        summary = summarize(app, asOf: now);
      } catch (error) {
        problems.add('app load threw ${error.runtimeType}: $error');
      }

      int rawCount(String section) {
        final value = snapshot.sections[section];
        return value is List ? value.length : 0;
      }

      if (summary != null) {
        // Rows the models skip or reset silently count as data loss.
        final txRaw = rawCount('transactions');
        if (app.transactionModel.transactions.length != txRaw) {
          problems.add('transactions: raw $txRaw loaded ${app.transactionModel.transactions.length}');
        }
        final rtRaw = rawCount('recurringTransactions');
        if (app.recurringModel.recurringTransactions.length != rtRaw) {
          problems.add('recurring: raw $rtRaw loaded ${app.recurringModel.recurringTransactions.length}');
        }
        final nwRaw = rawCount('netWorthEntries');
        if (nwRaw > 0 && app.transactionModel.netWorthEntries.length != nwRaw) {
          problems.add('net worth: raw $nwRaw loaded ${app.transactionModel.netWorthEntries.length}');
        }
        final goalsRaw = rawCount('savingsGoals');
        if (app.transactionModel.savingsGoals.length != goalsRaw) {
          problems.add('goals: raw $goalsRaw loaded ${app.transactionModel.savingsGoals.length}');
        }
        final tagsRaw = rawCount('transactionTags');
        if (app.categorizationProvider.tags.length != tagsRaw) {
          problems.add('tags: raw $tagsRaw loaded ${app.categorizationProvider.tags.length}');
        }
        final rulesRaw = rawCount('categorizationRules');
        if (app.categorizationProvider.rules.length != rulesRaw) {
          problems.add('rules: raw $rulesRaw loaded ${app.categorizationProvider.rules.length}');
        }
        final catRaw = rawCount('categories');
        if (catRaw > 0 && app.categoryProvider.categories.length < catRaw) {
          problems.add('categories: raw $catRaw loaded ${app.categoryProvider.categories.length}');
        }
        // Budget limits the Swift side wrote: Dart must hold exactly these,
        // in this order (values compared as Dart's toString).
        final budgetLimits = swift['categoryBudgetLimits'];
        if (budgetLimits is List) {
          final dart = jsonEncode([
            for (final e in app.transactionModel.categoryBudgetLimits.entries)
              [e.key, e.value.toString()]
          ]);
          final expected = jsonEncode(budgetLimits);
          if (dart != expected) {
            problems.add('budget limits: dart $dart swift $expected');
          }
        }
        // Net worth the Swift side wrote: Dart must hold exactly these
        // accounts, in this order, and this selected month.
        final netWorthEntries = swift['netWorthEntries'];
        if (netWorthEntries is List) {
          final dart = jsonEncode([
            for (final e in app.transactionModel.netWorthEntries)
              [
                e.id,
                e.name,
                e.type.name,
                cell(e.createdAt),
                [
                  for (final s in e.snapshots)
                    [cell(s.recordedAt), s.amount.toString()]
                ],
              ]
          ]);
          final expected = jsonEncode(netWorthEntries);
          if (dart != expected) {
            problems.add('net worth entries: dart $dart swift $expected');
          }
        }
        // Savings goals the Swift side wrote: Dart must hold exactly these,
        // in this order (amounts as Dart's toString).
        final savingsGoals = swift['savingsGoals'];
        if (savingsGoals is List) {
          final dart = jsonEncode([
            for (final g in app.transactionModel.savingsGoals)
              [
                g.id,
                g.name,
                g.targetAmount.toString(),
                g.currentAmount.toString(),
                cell(g.targetDate),
                cell(g.createdAt),
                g.completedAt == null ? null : cell(g.completedAt!),
              ]
          ]);
          final expected = jsonEncode(savingsGoals);
          if (dart != expected) {
            problems.add('savings goals: dart $dart swift $expected');
          }
        }
        // Transactions the Swift side wrote (edits, the recurring
        // generator, a CSV import): Dart must load exactly these, in this
        // order (description and category as UTF-16 code units, amounts as
        // Dart's toString).
        final transactions = swift['transactions'];
        if (transactions is List) {
          final dart = jsonEncode([
            for (final t in app.transactionModel.transactions)
              [
                t.id,
                t.type.name,
                t.description.codeUnits,
                t.amount.toString(),
                t.category.codeUnits,
                cell(t.date),
                t.recurringTemplateId,
                t.tagIds,
                cell(t.createdAt),
                cell(t.updatedAt),
              ]
          ]);
          final expected = jsonEncode(transactions);
          if (dart != expected) {
            problems.add('transactions: dart $dart swift $expected');
          }
        }
        final selectedNetWorthMonth = swift['selectedNetWorthMonth'];
        if (selectedNetWorthMonth is List &&
            jsonEncode(cell(app.transactionModel.selectedNetWorthMonth)) !=
                jsonEncode(selectedNetWorthMonth)) {
          problems.add('selected net worth month: dart '
              '${jsonEncode(cell(app.transactionModel.selectedNetWorthMonth))} '
              'swift ${jsonEncode(selectedNetWorthMonth)}');
        }
        // Settings the Swift side set: Dart must load exactly these.
        final appSettings = swift['appSettings'];
        if (appSettings is Map) {
          final s = app.appSettings;
          final dart = jsonEncode({
            'appLockEnabled': s.appLockEnabled,
            'autoLockTimeoutSeconds': s.autoLockTimeoutSeconds,
            'baseCurrencyCode': s.baseCurrencyCode,
            'hideBalances': s.hideBalances,
            'localeOverride': s.localeOverride,
          });
          final expected = jsonEncode({
            for (final key in (appSettings.keys.toList()..sort()))
              key: appSettings[key]
          });
          if (dart != expected) {
            problems.add('app settings: dart $dart swift $expected');
          }
        }
        // Categories the Swift side edited: Dart's launch pass must end with
        // exactly these definitions (every field, stored order), plus only
        // what Swift's own launch pass adds on the same bytes (ids aside:
        // a re-added padded name gets a fresh uuid). This also proves a
        // rename left no orphan name behind.
        final categories = swift['categories'];
        if (categories is List) {
          final dart = [
            for (final c in app.categoryProvider.categories)
              [
                c.id,
                c.type.name,
                c.name,
                c.iconIdentifier,
                c.colorToken,
                c.sortOrder,
                c.isArchived,
                c.isBuiltIn,
              ]
          ];
          final kept = jsonEncode(dart.take(categories.length).toList());
          if (kept != jsonEncode(categories)) {
            problems.add('categories: dart $kept swift ${jsonEncode(categories)}');
          }
          final added = jsonEncode(
              [for (final row in dart.skip(categories.length)) row.sublist(1)]);
          final expectedAdded = jsonEncode(swift['categoriesAddedAtLaunch']);
          if (added != expectedAdded) {
            problems.add('categories added at launch: dart $added swift $expectedAdded');
          }
        }
        // The category names the rename cascade wrote into every section.
        void compareRows(String key, List<List<Object?>> dart) {
          final expected = swift[key];
          if (expected is! List) return;
          if (jsonEncode(dart) != jsonEncode(expected)) {
            problems.add('$key: dart ${jsonEncode(dart)} swift ${jsonEncode(expected)}');
          }
        }

        compareRows('transactionCategories', [
          for (final t in app.transactionModel.transactions)
            [t.id, t.type.name, t.category]
        ]);
        compareRows('templateCategories', [
          for (final t in app.recurringModel.recurringTransactions)
            [t.id, t.type.name, t.category]
        ]);
        compareRows('ruleCategories', [
          for (final r in (app.categorizationProvider.rules.toList()
            ..sort((a, b) => a.id.compareTo(b.id))))
            [r.id, r.category]
        ]);
        // Tags and rules the Swift side edited: Dart must load exactly
        // these (`rules` in its getter's order, bounds as toString); the
        // rows Swift made must be Dart's `toJson` byte for byte; and the
        // state must be one Flutter's backup import accepts (unique tag and
        // rule ids, every rule tag id a tag; backup.dart:124-133).
        final transactionTags = swift['transactionTags'];
        if (transactionTags is List) {
          final provider = app.categorizationProvider;
          compareRows('transactionTags', [
            for (final t in provider.tags) [t.id, t.name, t.colorToken]
          ]);
          compareRows('categorizationRules', [
            for (final r in provider.rules)
              [
                r.id,
                r.merchantPattern,
                r.matchType.name,
                r.transactionType?.name,
                r.minimumAmount?.toString(),
                r.maximumAmount?.toString(),
                r.category,
                r.tagIds,
                r.priority,
                r.isEnabled,
              ]
          ]);
          // Swift's rule edits (bounds, any type, disabled) must mean the
          // same to Flutter's matcher: `suggest` picks the rule Swift's
          // suggest picked for every probe.
          final probes = swift['ruleSuggestions'];
          if (probes is List) {
            for (final probe in probes.cast<List>()) {
              final type = TransactionTyp.values.byName(probe[0] as String);
              final got = provider
                  .suggest(
                    type: type,
                    description: probe[1] as String,
                    amount: double.parse(probe[2] as String),
                  )
                  ?.rule
                  .id;
              if (got != probe[3]) {
                problems.add('suggest(${probe[0]}, ${jsonEncode(probe[1])}, '
                    '${probe[2]}): Dart $got, Swift ${probe[3]}');
              }
            }
          }
          void canonical(String section, List<Object?> ids,
              String Function(Map<String, dynamic>) toJson) {
            final rows = snapshot.sections[section] as List? ?? const [];
            for (final id in ids) {
              final row = rows.whereType<Map<String, dynamic>>()
                  .where((r) => r['id'] == id)
                  .toList();
              if (row.length != 1) {
                problems.add('$section: ${row.length} rows with Swift id $id');
              } else if (jsonEncode(row.single) != toJson(row.single)) {
                problems.add('$section: row $id is not toJson: '
                    '${jsonEncode(row.single)} vs ${toJson(row.single)}');
              }
            }
          }

          canonical('transactionTags', swift['newTagIds'] as List,
              (row) => jsonEncode(TransactionTag.fromJson(row).toJson()));
          canonical('categorizationRules', swift['newRuleIds'] as List,
              (row) => jsonEncode(CategorizationRule.fromJson(row).toJson()));
          final tagIds = {for (final t in provider.tags) t.id};
          final ruleIds = {for (final r in provider.rules) r.id};
          if (tagIds.length != provider.tags.length ||
              ruleIds.length != provider.rules.length) {
            problems.add('duplicate tag or rule ids (backup import refuses)');
          }
          for (final r in provider.rules) {
            for (final id in r.tagIds) {
              if (!tagIds.contains(id)) {
                problems.add('rule ${r.id} names unknown tag $id (backup import refuses)');
              }
            }
          }
        }
        // Recurring templates the Swift side wrote (the form's add and edit
        // paths, pause, generation): Dart must load exactly these.
        compareRows('recurringTemplates', [
          for (final r in app.recurringModel.recurringTransactions)
            [
              r.id,
              r.type.name,
              r.description,
              r.amount.toString(),
              r.category,
              r.pattern.name,
              cell(r.startDate),
              cell(r.nextOccurrence),
              r.dayOfMonth,
              r.dayOfWeek,
              r.isActive,
            ]
        ]);
        // Swift's CSV export, read by Flutter's importer.
        final csvExpected = swift['csvImport'];
        final csvFile = File('${dir.path}/export.csv');
        if (csvExpected is Map<String, dynamic> && csvFile.existsSync()) {
          problems.addAll(csvProblems(utf8.decode(csvFile.readAsBytesSync()),
              csvExpected, app.transactionModel));
        }
        final themeMode = swift['themeMode'];
        if (themeMode is String) {
          final theme = ThemeProvider();
          // ThemeProvider loads its preference asynchronously.
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (theme.themeMode.name != themeMode) {
            problems.add('theme mode: dart ${theme.themeMode.name} swift $themeMode');
          }
        }
        // The onboarding flag Swift wrote: the gate's own read
        // (onboarding_tutorial.dart `_loadCompletionState`).
        final onboardingCompleted = swift['onboardingCompleted'];
        if (onboardingCompleted is bool) {
          final preferences = await SharedPreferences.getInstance();
          final completed =
              preferences.getBool(StorageKeys.onboardingCompleted) ?? false;
          if (completed != onboardingCompleted) {
            problems.add('onboarding completed: dart $completed '
                'swift $onboardingCompleted');
          }
        }
        final insights = swift['insights'];
        if (insights is Map<String, dynamic>) {
          problems.addAll(await insightProblems(insights, app));
        }
        if (app.transactionModel.hasUnsavedChanges ||
            app.recurringModel.hasUnsavedChanges) {
          problems.add('a model reports unsaved changes after load');
        }
        // Swift generated everything due at the launch clock (the form's
        // add path and "Generate Due Transactions"): Dart's own launch
        // generator, run last (it writes to this case's copy only), must
        // add no row and move no cursor.
        if (swift['dartGenerateAddsNothing'] == true) {
          String cursors() => jsonEncode([
                for (final r in app.recurringModel.recurringTransactions)
                  [r.id, iso(r.nextOccurrence), r.isActive]
              ]);
          final rowsBefore = app.transactionModel.transactions.length;
          final cursorsBefore = cursors();
          await TransactionGenerator(
            transactionModel: app.transactionModel,
            recurringModel: app.recurringModel,
          ).generateDueTransactions();
          final added = app.transactionModel.transactions.length - rowsBefore;
          if (added != 0) {
            problems.add('dart generator added $added rows after Swift generated');
          }
          if (cursors() != cursorsBefore) {
            problems.add('dart generator moved cursors: '
                'before $cursorsBefore after ${cursors()}');
          }
        }
      }

      // A backup Swift exported from this store (after a launch).
      final backupFile = File('${dir.path}/backup.json');
      if (summary != null && backupFile.existsSync()) {
        problems.addAll(await verifyBackup(
            dir, backupFile, swift['backup'] as Map<String, dynamic>, prefs));
      }

      report[name] = {
        'problems': problems,
        'revision': snapshot.revision,
        'sections': canonical..remove('json'),
        'filesBeforeApp': filesBefore,
        if (summary != null) 'summary': summary,
      };
      expect(problems, isEmpty, reason: problems.join('\n'));
      // The 10k-row stores take well over the default 30 seconds on a busy
      // machine.
    }, timeout: const Timeout(Duration(minutes: 5)));

    // The real LocalInsightsSection, loading the Swift-written preferences
    // itself, must show the cards Swift computed.
    final swiftFile = File('${dir.path}/swift.json');
    final insights = swiftFile.existsSync()
        ? (jsonDecode(swiftFile.readAsStringSync()) as Map<String, dynamic>)['insights']
        : null;
    if (insights is! Map<String, dynamic>) continue;
    testWidgets('$name: LocalInsightsSection', (tester) async {
      final app = AppHarness();
      await tester.runAsync(() async {
        final work = await Directory.systemTemp.createTemp('verify_widget_$name');
        final storeDir = Directory('${work.path}/financial_store');
        copyDir(Directory('${dir.path}/financial_store'), storeDir);
        SharedPreferences.setMockInitialValues(
            Map.of(prefsFrom(File('${dir.path}/prefs.json'))));
        pinClock(launchNow);
        await AtomicFinancialStore.instance.resetForTesting(directory: storeDir);
        await app.initialize(generate: false);
      });
      final now = DateTime.parse(insights['now'] as String);
      app.transactionModel.selectedMonth =
          DateTime.parse(insights['selectedMonth'] as String);
      pinClock(now);
      tester.view.physicalSize = const Size(402 * 3, 2400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LocalInsightsSection(model: app.transactionModel),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final cards = find.descendant(
          of: find.byType(LocalInsightsSection),
          matching: find.byType(GlowCard));
      final shown = [
        for (var i = 0; i < cards.evaluate().length; i++)
          [
            for (final element in find
                .descendant(of: cards.at(i), matching: find.byType(Text))
                .evaluate())
              (element.widget as Text).data!
          ]
      ];
      final expected = [
        for (final card in insights['visible'] as List)
          (card as List).sublist(1)
      ];
      await tester.pumpWidget(const SizedBox());
      report['$name: LocalInsightsSection'] = {'cards': shown};
      expect(jsonEncode(shown), jsonEncode(expected));
    });
  }
}
