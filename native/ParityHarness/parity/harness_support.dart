// Shared plumbing for the parity harness. Copied into the exported copy of
// budget_app at test/parity/ by native/ParityHarness/run.sh.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_app/app_settings_provider.dart';
import 'package:budget_app/backup.dart';
import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/category_definition.dart';
import 'package:budget_app/category_provider.dart';
import 'package:budget_app/parity_clock.dart';
import 'package:budget_app/recurring_transaction_model.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/theme_provider.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_generator.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

final String fixturesRoot = Platform.environment['PARITY_FIXTURES'] ??
    (throw StateError('PARITY_FIXTURES not set; use run.sh'));
final String parityTz = Platform.environment['PARITY_TZ'] ?? 'unknown';
final String parityCommit = Platform.environment['PARITY_COMMIT'] ?? 'unknown';

const JsonEncoder pretty = JsonEncoder.withIndent('  ');

Directory fixtureDir(String relative) {
  final dir = Directory('$fixturesRoot/$relative');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  return dir;
}

void writeJson(String path, Object? value) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${pretty.convert(value)}\n');
}

/// FNV-1a 64 exactly as the store formats it, for fixture manifests.
String fnv(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// IEEE-754 bits as 16 lowercase hex digits.
String bitsHex(double d) {
  final data = ByteData(8)..setFloat64(0, d);
  return data.getUint32(0).toRadixString(16).padLeft(8, '0') +
      data.getUint32(4).toRadixString(16).padLeft(8, '0');
}

/// A local date from components [y, m, d, h, min, s, ms, us].
DateTime local(List c) => DateTime(
      c[0] as int,
      c.length > 1 ? c[1] as int : 1,
      c.length > 2 ? c[2] as int : 1,
      c.length > 3 ? c[3] as int : 0,
      c.length > 4 ? c[4] as int : 0,
      c.length > 5 ? c[5] as int : 0,
      c.length > 6 ? c[6] as int : 0,
      c.length > 7 ? c[7] as int : 0,
    );

/// These fixtures are large; one line keeps them small.
void writeCompactJson(String path, Object? value) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${jsonEncode(value)}\n');
}

/// Pins every `DateTime.now()` in the app (see parity_clock.dart).
void pinClock(DateTime? now) => parityClockOverride = now;

/// Makes generated UUIDs deterministic for reproducible fixtures.
void seedUuids(int seed) => seedParityUuids(seed);

/// Typed description of a SharedPreferences state, keyed by the on-device
/// NSUserDefaults key (with the `flutter.` prefix). This is what the Swift
/// side feeds into its preferences source.
Map<String, Object> typedPrefs(Map<String, Object> dartValues) {
  final out = <String, Object>{};
  for (final entry in dartValues.entries) {
    final key = entry.key.startsWith('flutter.')
        ? entry.key
        : 'flutter.${entry.key}';
    final value = entry.value;
    final String type;
    if (value is bool) {
      type = 'bool';
    } else if (value is int) {
      type = 'int';
    } else if (value is double) {
      type = 'double';
    } else if (value is String) {
      type = 'string';
    } else if (value is List<String>) {
      type = 'stringList';
    } else {
      throw ArgumentError('unsupported pref type ${value.runtimeType}');
    }
    out[key] = {'type': type, 'value': value};
  }
  return out;
}

/// Current SharedPreferences contents in the typed form above.
Future<Map<String, Object>> dumpPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final values = <String, Object>{};
  for (final key in prefs.getKeys()) {
    values[key] = prefs.get(key)!;
  }
  return typedPrefs(values);
}

/// Reads a typed preferences file (the `typedPrefs` form) back into values
/// for `SharedPreferences.setMockInitialValues`. Missing file: none.
Map<String, Object> prefsFrom(File file) {
  if (!file.existsSync()) return {};
  final typed = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, Object>{};
  typed.forEach((key, value) {
    final entry = value as Map<String, dynamic>;
    final raw = entry['value'];
    out[key] = switch (entry['type']) {
      'bool' => raw as bool,
      'int' => raw as int,
      'double' => (raw as num).toDouble(),
      'string' => raw as String,
      'stringList' => List<String>.from(raw as List),
      _ => throw ArgumentError('bad pref type ${entry['type']}'),
    };
  });
  return out;
}

/// Mirrors `_initializeApp` in lib/main.dart: the same providers, loaded in
/// the same order, then recurring generation.
class AppHarness {
  final transactionModel = TransactionModel();
  final recurringModel = RecurringTransactionModel();
  final categoryProvider = CategoryProvider();
  final appSettings = AppSettingsProvider();
  final categorizationProvider = CategorizationProvider();

  Future<void> initialize({bool generate = true}) async {
    await AtomicFinancialStore.instance.read();
    await Future.wait([
      categoryProvider.load(),
      appSettings.load(),
      categorizationProvider.load(),
    ]);
    await transactionModel.getTransactions();
    await recurringModel.loadRecurringTransactions();
    await categoryProvider.ensureLegacyCategories(
      transactionModel.transactions,
    );
    await categoryProvider.ensureLegacyCategoryNames([
      ...recurringModel.recurringTransactions.map(
        (template) => (
          template.type == TransactionTyp.income
              ? BudgetCategoryType.income
              : BudgetCategoryType.expense,
          template.category,
        ),
      ),
      ...transactionModel.categoryBudgetLimits.keys.map(
        (name) => (BudgetCategoryType.expense, name),
      ),
    ]);
    if (generate) {
      await TransactionGenerator(
        transactionModel: transactionModel,
        recurringModel: recurringModel,
      ).generateDueTransactions();
    }
  }
}

/// Every file in [dir] with size and checksum; `.corrupt-<stamp>` suffixes
/// are normalised to `.corrupt-*` so expectations do not depend on the clock.
Map<String, Object> listing(Directory dir) {
  final out = <String, Object>{};
  if (!dir.existsSync()) return out;
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final name = file.uri.pathSegments.last
        .replaceAll(RegExp(r'\.corrupt-\d+$'), '.corrupt-*');
    final bytes = file.readAsBytesSync();
    out[name] = {'size': bytes.length, 'fnv': fnv(bytes)};
  }
  return out;
}

String iso(DateTime value) => value.toIso8601String();

// MARK: - Backup

/// What `_exportBackup` (settings_page.dart:295-326) reads from the models.
BackupData exportData(AppHarness app, ThemeMode? themeMode) => BackupData(
      transactions: app.transactionModel.transactions,
      netWorthEntries: app.transactionModel.netWorthEntries,
      categoryBudgetLimits: app.transactionModel.categoryBudgetLimits,
      savingsGoals: app.transactionModel.savingsGoals,
      recurringTransactions: app.recurringModel.recurringTransactions,
      themeMode: themeMode,
      categories: app.categoryProvider.categories,
      transactionTags: app.categorizationProvider.tags,
      categorizationRules: app.categorizationProvider.rules,
      baseCurrencyCode: app.appSettings.baseCurrencyCode,
      localeOverride: app.appSettings.localeOverride,
      appLockEnabled: app.appSettings.appLockEnabled,
      autoLockTimeoutSeconds: app.appSettings.autoLockTimeoutSeconds,
      hideBalances: app.appSettings.hideBalances,
    );

ThemeMode? themeFrom(String? name) => switch (name) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };

/// `_importBackup` after its dialog (settings_page.dart:421-475), call for
/// call, on [app]'s models.
Future<void> restoreChain(
    AppHarness app, ThemeProvider themeProvider, BackupData data) async {
  final transactionModel = app.transactionModel;
  final recurringModel = app.recurringModel;
  await AtomicFinancialStore.instance.updateSections({
    FinancialSections.transactions:
        data.transactions.map((item) => item.toJson()).toList(),
    FinancialSections.netWorthEntries:
        data.netWorthEntries.map((item) => item.toJson()).toList(),
    FinancialSections.selectedNetWorthMonth:
        transactionModel.selectedNetWorthMonth.toIso8601String(),
    FinancialSections.categoryBudgetLimits: data.categoryBudgetLimits,
    FinancialSections.savingsGoals:
        data.savingsGoals.map((item) => item.toJson()).toList(),
    FinancialSections.recurringTransactions:
        data.recurringTransactions.map((item) => item.toJson()).toList(),
    FinancialSections.categories:
        data.categories.map((item) => item.toJson()).toList(),
    FinancialSections.transactionTags:
        data.transactionTags.map((item) => item.toJson()).toList(),
    FinancialSections.categorizationRules:
        data.categorizationRules.map((item) => item.toJson()).toList(),
    FinancialSections.appSettings: {
      'baseCurrencyCode': data.baseCurrencyCode,
      'localeOverride': data.localeOverride,
      'appLockEnabled': data.appLockEnabled,
      'autoLockTimeoutSeconds': data.autoLockTimeoutSeconds,
      'hideBalances': data.hideBalances,
    },
  });
  await transactionModel.restoreFromBackup(
    transactions: data.transactions,
    netWorthEntries: data.netWorthEntries,
    categoryBudgetLimits: data.categoryBudgetLimits,
    savingsGoals: data.savingsGoals,
  );
  await recurringModel.restoreFromBackup(data.recurringTransactions);
  await app.categoryProvider.restoreFromBackup(data.categories);
  await app.categorizationProvider.restoreFromBackup(
    tags: data.transactionTags,
    rules: data.categorizationRules,
  );
  await app.appSettings.restoreFromBackup(
    baseCurrencyCode: data.baseCurrencyCode,
    localeOverride: data.localeOverride,
    appLockEnabled: data.appLockEnabled,
    autoLockTimeoutSeconds: data.autoLockTimeoutSeconds,
    hideBalances: data.hideBalances,
  );
  if (data.themeMode != null) {
    await themeProvider.setThemeMode(data.themeMode!);
  }
  await TransactionGenerator(
    transactionModel: transactionModel,
    recurringModel: recurringModel,
  ).generateDueTransactions();
}

void collectStrings(Object? value, Set<String> into) {
  if (value is String) {
    into.add(value);
  } else if (value is List) {
    for (final item in value) {
      collectStrings(item, into);
    }
  } else if (value is Map) {
    value.forEach((key, item) {
      into.add(key as String);
      collectStrings(item, into);
    });
  }
}

/// Row ids in [exported] (JSON text) that are not strings of [sections]
/// (generated while loading or restoring), in document order. The Swift
/// side generates its own, so it substitutes these for them in order
/// before comparing bytes.
List<String> generatedIds(String exported, Map<String, dynamic> sections) {
  final known = <String>{};
  collectStrings(sections, known);
  final found = <String>[];
  void walk(Object? value) {
    if (value is List) {
      for (final item in value) {
        if (item is Map && item['id'] is String && !known.contains(item['id'])) {
          found.add(item['id'] as String);
        }
        walk(item);
      }
    } else if (value is Map) {
      value.values.forEach(walk);
    }
  }

  walk(jsonDecode(exported));
  return found;
}

/// [swift] (JSON text) with the ids it generated replaced, in order, by
/// the ones [dart] generated; null when their counts differ.
String? alignGeneratedIds(
    String swift, String dart, Map<String, dynamic> sections) {
  final mine = generatedIds(swift, sections);
  final theirs = generatedIds(dart, sections);
  if (mine.length != theirs.length) return null;
  var text = swift;
  for (var i = 0; i < mine.length; i++) {
    text = text.replaceAll(jsonEncode(mine[i]), jsonEncode(theirs[i]));
  }
  return text;
}
