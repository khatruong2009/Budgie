// Emits native/Fixtures/worth/ : the Worth tab's model behaviour and display
// strings, from the real Dart code.
//
// tz/<zone>/mutations.json (every zone run.sh uses): scenarios of real
// TransactionModel net worth mutations through a real AtomicFinancialStore
// (files in a temp directory) with a pinned clock, recording after every
// call whether the store was written, the stored `netWorthEntries` and
// `selectedNetWorthMonth` sections, and the model's memory; then the queries
// the page reads. Dates are built from local components on both sides, so
// DST gaps and repeated hours resolve the same way.
//
// formatting.json (America/New_York run only): compact currency, the delta
// pill, row labels, the editor's amount field, chart scales, the hover card
// alignment, the split bar, the row icon, both charts' grid lines (fl_chart
// 1.2.0's `AxisChartHelper.iterateThroughAxis`, as its grid painter calls it)
// and which points get an axis label.
//
// Formulas private to widget State classes in net_worth_page.dart are copied
// verbatim below, each citing its source lines; they call the real model.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/net_worth_entry.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction_model.dart';
// fl_chart's own axis iteration (not exported), as its grid painter and
// side titles call it.
// ignore: implementation_imports
import 'package:fl_chart/src/chart/base/axis_chart/axis_chart_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

String get zoneDir => 'worth/tz/${parityTz.replaceAll('/', '_')}';

Object? bitsOrNull(double? d) => d == null ? null : bitsHex(d);

// --- Copied verbatim from net_worth_page.dart (private members) ------------

/// NW:406-422 `_rangeData` (months: 6, 12, or null for ALL).
List<NetWorthHistoryPoint> rangeData(
    List<NetWorthHistoryPoint> data, int? months) {
  if (data.isEmpty || months == null) {
    return data;
  }
  final anchor = data.last.date;
  final cutoff = DateTime(anchor.year, anchor.month - (months - 1));
  final filtered = data
      .where((p) => !DateTime(p.date.year, p.date.month).isBefore(cutoff))
      .toList();
  // Keep at least two points so the line is meaningful.
  if (filtered.length < 2 && data.length >= 2) {
    return data.sublist(data.length - 2);
  }
  return filtered.isEmpty ? data : filtered;
}

/// NW:826-836 `_netWorthChartScale` over the values.
List<double> growthScale(List<double> values) {
  final minValue = values.reduce(min);
  final maxValue = values.reduce(max);
  final rawRange = maxValue - minValue;
  final range = max(rawRange, max(1.0, maxValue.abs() * 0.10));
  return [minValue - (range * 0.18), maxValue + (range * 0.18)];
}

/// NW:1936-1943 (`_AccountHistoryChart.build`).
List<double> accountScale(List<double> values) {
  final minValue = values.reduce(min);
  final maxValue = values.reduce(max);
  final rawRange = maxValue - minValue;
  final baselineRange = max(1.0, max(maxValue.abs(), minValue.abs()) * 0.08);
  final range = max(rawRange, baselineRange);
  return [minValue - (range * 0.20), maxValue + (range * 0.20)];
}

/// Horizontal grid lines of a chart with this padded [min, max] scale:
/// fl_chart's `drawGrid` (axis_chart_painter.dart:108-120) with
/// `horizontalInterval: (max - min) / 4` (NW:698, 2048) and the default
/// `baselineY` 0, both ends excluded.
List<double> gridLines(List<double> scale) => AxisChartHelper()
    .iterateThroughAxis(
      min: scale[0],
      minIncluded: false,
      max: scale[1],
      maxIncluded: false,
      baseLine: 0,
      interval: (scale[1] - scale[0]) / 4,
    )
    .toList();

/// `_AxisLabels` (NW:571-583): the first, the middle (`n ~/ 2`, only when
/// there are more than two points) and the last point.
List<int> growthAxisLabelIndices(int n) =>
    [0, if (n > 2) n ~/ 2, n - 1];

/// The account chart's bottom titles (NW:2059-2080): fl_chart asks for the
/// values `iterateThroughAxis` yields over 0...maxX (both ends included,
/// `SideTitles` defaults) at `interval`; the widget hides the rest.
List<int> accountAxisLabelIndices(int n) {
  final out = <int>[];
  for (final value in AxisChartHelper().iterateThroughAxis(
    min: 0,
    max: max(1, n - 1).toDouble(),
    baseLine: 0,
    interval: max(1, (n / 3).floor()).toDouble(),
  )) {
    final i = value.round();
    if (i < 0 || i >= n) continue;
    if (n > 3 && i != 0 && i != n - 1 && i != (n / 2).round()) continue;
    out.add(i);
  }
  return out;
}

/// NW:535-553 `_overlayAlignment` over the values: [x, y, useBottom].
List<Object> overlayAlignment(int selectedIndex, List<double> values) {
  final minValue = values.reduce(min);
  final maxValue = values.reduce(max);
  final midpoint = (minValue + maxValue) / 2;
  final useBottom = values[selectedIndex] >= midpoint;

  final x = values.length <= 1
      ? 0.0
      : (selectedIndex / (values.length - 1) * 2 - 1)
          .clamp(-0.84, 0.84)
          .toDouble();
  return [x, useBottom ? 0.5 : -0.6, useBottom];
}

/// NW:1348-1366 `_previousSnapshotBefore`.
NetWorthSnapshot? previousSnapshotBefore(
  List<NetWorthSnapshot> snapshots,
  DateTime? recordedAt,
) {
  if (recordedAt == null) {
    return null;
  }

  NetWorthSnapshot? previous;
  for (final snapshot in snapshots) {
    if (!snapshot.recordedAt.isBefore(recordedAt)) {
      continue;
    }
    if (previous == null || snapshot.recordedAt.isAfter(previous.recordedAt)) {
      previous = snapshot;
    }
  }
  return previous;
}

/// NW:1116-1145 (`_AccountRow.build`), colours as a favourable flag.
Map<String, Object?> accountRow(NetWorthEntry entry, DateTime month,
    double totalForCategory, bool isAssetsTab) {
  final effectiveSnapshot = entry.latestSnapshotThrough(
    endOfNetWorthMonth(month),
  );
  final amount = effectiveSnapshot?.amount ?? 0.0;
  final percentage = totalForCategory > 0
      ? (amount / totalForCategory).clamp(0.0, 1.0)
      : 0.0;
  final previousSnapshot = previousSnapshotBefore(
    entry.snapshots,
    effectiveSnapshot?.recordedAt,
  );
  final percentChange = previousSnapshot == null ||
          previousSnapshot.amount.abs() < 0.001
      ? null
      : ((amount - previousSnapshot.amount) / previousSnapshot.amount.abs()) *
          100;

  final isAsset = entry.type == NetWorthEntryType.asset;
  final changeFavorable = percentChange == null
      ? null
      : (isAsset ? percentChange >= 0 : percentChange <= 0);

  final shareLabel = '${(percentage * 100).toStringAsFixed(1)}% of '
      '${isAssetsTab ? 'assets' : 'liabilities'}';
  return {
    'id': entry.id,
    'effective': effectiveSnapshot == null ? null : iso(effectiveSnapshot.recordedAt),
    'previous': previousSnapshot == null ? null : iso(previousSnapshot.recordedAt),
    'amount': bitsHex(amount),
    'share': bitsHex(percentage.toDouble()),
    'percentChange': bitsOrNull(percentChange),
    'favorable': changeFavorable,
    'shareLabel': shareLabel,
    // NW:1204-1207
    'changeText': percentChange == null
        ? '—'
        : '${percentChange >= 0 ? '+' : ''}'
            '${percentChange.toStringAsFixed(1)}%',
  };
}

/// NW:1383-1409 and 1547-1562 (`_AccountHistoryPage.build`).
Map<String, Object?> accountHistory(TransactionModel model, NetWorthEntry entry) {
  final chartHistory = model.getNetWorthEntryHistory(entry.id);
  final timelineHistory = chartHistory.reversed.toList();
  final isAsset = entry.type == NetWorthEntryType.asset;
  final latestSnapshot = chartHistory.isNotEmpty ? chartHistory.last : null;
  final previousSnapshot =
      chartHistory.length > 1 ? chartHistory[chartHistory.length - 2] : null;
  final latestAmount = latestSnapshot?.amount ?? 0.0;
  final changeFromPrevious =
      latestSnapshot != null && previousSnapshot != null
          ? latestSnapshot.amount - previousSnapshot.amount
          : null;
  final totalChange = chartHistory.length > 1
      ? chartHistory.last.amount - chartHistory.first.amount
      : null;
  final totalChangeIsPositive = totalChange == null
      ? null
      : isAsset
          ? totalChange >= 0
          : totalChange <= 0;
  final peakAmount = chartHistory.isEmpty
      ? null
      : chartHistory.map((point) => point.amount).reduce(max);
  final lowAmount = chartHistory.isEmpty
      ? null
      : chartHistory.map((point) => point.amount).reduce(min);
  return {
    'id': entry.id,
    'chart': [
      for (final s in chartHistory) [iso(s.recordedAt), bitsHex(s.amount)]
    ],
    'timelineDeltas': [
      for (var index = 0; index < timelineHistory.length; index++)
        bitsOrNull(index < timelineHistory.length - 1
            ? timelineHistory[index].amount - timelineHistory[index + 1].amount
            : null)
    ],
    'latestAmount': bitsHex(latestAmount),
    'changeFromPrevious': bitsOrNull(changeFromPrevious),
    'totalChange': bitsOrNull(totalChange),
    'totalChangeIsPositive': totalChangeIsPositive,
    'peak': bitsOrNull(peakAmount),
    'low': bitsOrNull(lowAmount),
    'scale': chartHistory.isEmpty
        ? null
        : accountScale(chartHistory.map((s) => s.amount).toList())
            .map(bitsHex)
            .toList(),
  };
}

/// NW:1305-1345 `_iconForEntry`, returning the symbol's name.
String iconForEntry(NetWorthEntry e) {
  final n = e.name.toLowerCase();
  if (e.type == NetWorthEntryType.asset) {
    if (n.contains('bank') || n.contains('checking')) {
      return 'accountBalance';
    }
    if (n.contains('saving')) {
      return 'savings';
    }
    if (n.contains('invest') ||
        n.contains('stock') ||
        n.contains('portfolio') ||
        n.contains('broker') ||
        n.contains('etf') ||
        n.contains('401') ||
        n.contains('ira')) {
      return 'trendingUp';
    }
    if (n.contains('real estate') ||
        n.contains('house') ||
        n.contains('home') ||
        n.contains('property')) {
      return 'home';
    }
    if (n.contains('wallet') || n.contains('cash')) {
      return 'accountBalanceWallet';
    }
    return 'northEast';
  } else {
    if (n.contains('loan') ||
        n.contains('student') ||
        n.contains('auto') ||
        n.contains('personal')) {
      return 'attachMoney';
    }
    if (n.contains('credit') || n.contains('card')) {
      return 'accountBalanceWallet';
    }
    return 'southWest';
  }
}

/// NW:2161-2200 `_CurrencyInputFormatter.formatEditUpdate` (text only).
String currencyInput(String oldText, String newText) {
  final text = newText;
  if (text.isEmpty) return newText;

  final stripped = text.replaceAll(',', '');
  if (!RegExp(r'^\d*\.?\d{0,2}$').hasMatch(stripped)) {
    return oldText;
  }

  final dotIndex = stripped.indexOf('.');
  final intPart = dotIndex == -1 ? stripped : stripped.substring(0, dotIndex);
  final decPart = dotIndex == -1 ? null : stripped.substring(dotIndex + 1);

  String formatted = '';
  if (intPart.isNotEmpty) {
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(intPart[i]);
    }
    formatted = buffer.toString();
  }

  if (dotIndex != -1) {
    formatted += '.${decPart ?? ''}';
  }
  return formatted;
}

/// NW:2450-2466 (`_save`): the parsed amount when valid, else null.
double? saveAmount(String amountText) {
  final cleanText = amountText.replaceAll(',', '').trim();
  final parsedAmount = double.tryParse(cleanText);
  if (parsedAmount == null || parsedAmount < 0) return null;
  return parsedAmount;
}

/// NW:2950-2959 `_formatCompactCurrencyNoDecimals`.
String formatCompactCurrencyNoDecimals(double value) {
  if (value < 0) {
    return '-${MoneyFormatter.format(
      value.abs(),
      decimalDigits: 1,
      compact: true,
    )}';
  }
  return MoneyFormatter.format(value, decimalDigits: 1, compact: true);
}

/// NW:1704-1706, 1721-1723, 1875-1877: history chips and timeline deltas.
String compactDelta(double value) =>
    '${value >= 0 ? '+' : ''}${formatCompactCurrencyNoDecimals(value)}';

/// NW:338-349 (`_DeltaPill.build`).
String deltaPillText(double change, double previousNetWorth) {
  final isPositive = change >= 0;
  final dollarStr =
      '${isPositive ? '+' : '-'}${MoneyFormatter.formatSigned(change.abs(), decimalDigits: 0)}';
  final percentStr = previousNetWorth.abs() > 0.001
      ? '${isPositive ? '+' : '-'}'
          '${(change.abs() / previousNetWorth.abs() * 100).toStringAsFixed(1)}%'
      : '${isPositive ? '+' : '-'}—';
  return '$dollarStr · $percentStr this month';
}

// ---------------------------------------------------------------------------

NetWorthEntryType typeOf(String name) => name == 'liability'
    ? NetWorthEntryType.liability
    : NetWorthEntryType.asset;

Map<String, Object?> memory(TransactionModel model) => {
      'selected': iso(model.selectedNetWorthMonth),
      'entries': [
        for (final e in model.netWorthEntries)
          {
            'id': e.id,
            'name': e.name,
            'type': e.type.name,
            'createdAt': iso(e.createdAt),
            'snapshots': [
              for (final s in e.snapshots)
                [iso(s.recordedAt), bitsHex(s.amount)]
            ],
          }
      ],
    };

Map<String, Object?> queries(TransactionModel model) {
  final months = <DateTime>{
    ...model.getNetWorthAvailableMonths(),
  };
  for (final e in model.netWorthEntries) {
    for (final s in e.snapshots) {
      final m = DateTime(s.recordedAt.year, s.recordedAt.month);
      months.add(DateTime(m.year, m.month + 1));
      months.add(DateTime(m.year, m.month - 1));
    }
  }
  final sortedMonths = months.toList()..sort();
  final perMonth = <Map<String, Object?>>[];
  for (final month in sortedMonths) {
    final assets = model.getTotalAssetsForMonth(month);
    final liabilities = model.getTotalLiabilitiesForMonth(month);
    final change = model.getNetWorthChangeForMonth(month);
    final assetRows = model.getNetWorthEntriesForMonth(month,
        type: NetWorthEntryType.asset);
    final liabilityRows = model.getNetWorthEntriesForMonth(month,
        type: NetWorthEntryType.liability);
    final netWorth = model.getNetWorthForMonth(month);
    perMonth.add({
      'month': iso(month),
      'assets': bitsHex(assets),
      'liabilities': bitsHex(liabilities),
      'netWorth': bitsHex(netWorth),
      'change': bitsOrNull(change),
      'deltaPill': change == null ? null : deltaPillText(change, netWorth - change),
      'hasData': model.hasNetWorthDataForMonth(month),
      'tracked': model.getTrackedNetWorthEntryCountForMonth(month),
      'updated': model.getUpdatedNetWorthEntryCountForMonth(month),
      'stale': model.getStaleNetWorthEntryCountForMonth(month),
      'all': model.getNetWorthEntriesForMonth(month).map((e) => e.id).toList(),
      'assetRows': [
        for (final e in assetRows) accountRow(e, month, assets, true)
      ],
      'liabilityRows': [
        for (final e in liabilityRows) accountRow(e, month, liabilities, false)
      ],
      'split': bitsHex(
          assets + liabilities > 0 ? assets / (assets + liabilities) : 1.0),
    });
  }

  List<Map<String, Object?>> historyJson(List<NetWorthHistoryPoint> points) => [
        for (final p in points)
          {
            'date': iso(p.date),
            'assets': bitsHex(p.assets),
            'liabilities': bitsHex(p.liabilities),
            'assetCount': p.assetCount,
            'liabilityCount': p.liabilityCount,
            'granularity': p.granularity.name,
          }
      ];

  // NW:47-49: the page reverses the 24-point history (oldest first).
  final chartData = model.getNetWorthHistory(limit: 24).reversed.toList();
  final ranges = <String, Object?>{};
  for (final (name, months) in [('sixMonths', 6), ('oneYear', 12), ('all', null)]) {
    final data = rangeData(chartData, months);
    final values = data.map((p) => p.netWorth).toList();
    ranges[name] = {
      'dates': data.map((p) => iso(p.date)).toList(),
      'scale': values.isEmpty ? null : growthScale(values).map(bitsHex).toList(),
      'hover': [
        for (var i = 0; i < values.length; i++)
          () {
            final a = overlayAlignment(i, values);
            return [bitsHex(a[0] as double), bitsHex(a[1] as double), a[2]];
          }()
      ],
    };
  }

  return {
    'availableMonths': model.getNetWorthAvailableMonths().map(iso).toList(),
    'months': perMonth,
    'history24': historyJson(model.getNetWorthHistory(limit: 24)),
    'history4': historyJson(model.getNetWorthHistory(limit: 4)),
    'ranges': ranges,
    'accounts': [
      for (final e in model.netWorthEntries) accountHistory(model, e)
    ],
    'missingHistory': model.getNetWorthEntryHistory('no-such-id').length,
  };
}

/// Resolves an id reference: an int indexes the current entries, a string
/// is used as is.
String resolveId(TransactionModel model, Object? ref) =>
    ref is int ? model.netWorthEntries[ref].id : ref as String;

/// A snapshot reference: [entryIndex, snapshotIndex] or a date component
/// list prefixed with 'at'.
DateTime resolveSnapshot(TransactionModel model, List ref) => ref[0] == 'at'
    ? local(ref.sublist(1))
    : model.netWorthEntries[ref[0] as int].snapshots[ref[1] as int].recordedAt;

Future<Map<String, Object?>> runScenario(Map<String, Object?> scenario) async {
  SharedPreferences.setMockInitialValues({});
  final dir = await Directory.systemTemp.createTemp('worth_fixture');
  await AtomicFinancialStore.instance.resetForTesting(directory: dir);
  final store = AtomicFinancialStore.instance;
  var clock = local(scenario['launch'] as List);
  pinClock(clock);
  seedUuids(scenario['seed'] as int);
  final initial = scenario['initial'] as Map<String, Object?>;
  if (initial.isNotEmpty) {
    await store.updateSections(initial);
  }
  final model = TransactionModel();
  await model.getTransactions();
  final loaded = memory(model);
  final loadedSection = (await store.read())
      .sections[FinancialSections.netWorthEntries];

  final steps = <Map<String, Object?>>[];
  for (final op in (scenario['ops'] as List).cast<List>()) {
    if (op[0] == 'clock') {
      clock = local(op[1] as List);
      pinClock(clock);
      steps.add({'op': 'clock', 'now': iso(clock)});
      continue;
    }
    final before = (await store.read()).revision;
    final step = <String, Object?>{'op': op[0], 'now': iso(clock)};
    switch (op[0]) {
      case 'select':
        final date = local(op[1] as List);
        step['date'] = iso(date);
        await model.selectNetWorthMonth(date);
      case 'add':
        final count = model.netWorthEntries.length;
        final amount = (op[3] as num).toDouble();
        final month = op[4] == null ? null : local(op[4] as List);
        final recordedAt = op[5] == null ? null : local(op[5] as List);
        step.addAll({
          'name': op[1],
          'type': op[2],
          'amount': bitsHex(amount),
          'month': month == null ? null : iso(month),
          'recordedAt': recordedAt == null ? null : iso(recordedAt),
        });
        await model.addNetWorthEntry(
            name: op[1] as String,
            type: typeOf(op[2] as String),
            amount: amount,
            month: month,
            recordedAt: recordedAt);
        step['newId'] = model.netWorthEntries.length > count
            ? model.netWorthEntries.last.id
            : null;
      case 'update':
        final id = resolveId(model, op[1]);
        final amount = (op[4] as num).toDouble();
        final month = op[5] == null ? null : local(op[5] as List);
        final recordedAt = op[6] == null ? null : local(op[6] as List);
        step.addAll({
          'id': id,
          'name': op[2],
          'type': op[3],
          'amount': bitsHex(amount),
          'month': month == null ? null : iso(month),
          'recordedAt': recordedAt == null ? null : iso(recordedAt),
        });
        await model.updateNetWorthEntry(
            id: id,
            name: op[2] as String,
            type: typeOf(op[3] as String),
            amount: amount,
            month: month,
            recordedAt: recordedAt);
      case 'deleteEntry':
        final id = resolveId(model, op[1]);
        step['id'] = id;
        await model.deleteNetWorthEntry(id);
      case 'deleteSnapshot':
        final id = resolveId(model, op[1]);
        final at = resolveSnapshot(model, op[2] as List);
        step.addAll({'id': id, 'recordedAt': iso(at)});
        await model.deleteNetWorthSnapshot(entryId: id, recordedAt: at);
      case 'carry':
        final month = local(op[1] as List);
        step['month'] = iso(month);
        step['result'] = await model.carryNetWorthMonthForward(month);
      default:
        throw ArgumentError('unknown op ${op[0]}');
    }
    final snapshot = await store.read();
    final section = snapshot.sections[FinancialSections.netWorthEntries];
    step.addAll({
      'wrote': snapshot.revision != before,
      'section': section == null ? null : jsonEncode(section),
      'selectedSection': snapshot.sections[FinancialSections.selectedNetWorthMonth],
      'memory': memory(model),
      'hasUnsavedChanges': model.hasUnsavedChanges,
    });
    steps.add(step);
  }
  final result = {
    'name': scenario['name'],
    'launch': iso(local(scenario['launch'] as List)),
    'byteComparable': scenario['byteComparable'],
    'initial': initial.isEmpty ? null : jsonEncode(initial),
    'loaded': loaded,
    'loadedSection': loadedSection == null ? null : jsonEncode(loadedSection),
    'steps': steps,
    'queries': queries(model),
  };
  await AtomicFinancialStore.instance.resetForTesting();
  await dir.delete(recursive: true);
  return result;
}

final scenarios = <Map<String, Object?>>[
  {
    // Every mutation on data the Dart model wrote itself: Swift's in-place
    // patch must produce the same bytes after every step.
    'name': 'canonical',
    'byteComparable': true,
    'seed': 11,
    'launch': [2026, 4, 10, 11, 5, 7, 42, 9],
    'initial': <String, Object?>{},
    'ops': [
      ['select', [2026, 1, 17, 8, 30]],
      ['add', 'Checking', 'asset', 2500.0, [2026, 1], null],
      ['add', ' Mortgage ', 'liability', 250000.0, [2026, 1], null],
      ['add', '   ', 'asset', 5.0, null, null],
      ['add', '\u{FEFF}', 'asset', 5.0, null, null],
      ['add', 'Brokerage 401k', 'asset', 10000.5, null, [2026, 2, 14, 16, 30, 0, 0, 7]],
      ['add', 'Café Savings', 'asset', 0.1 + 0.2, null, null],
      ['update', 0, 'Checking', 'asset', 2750.25, [2026, 2], null],
      ['update', 0, 'Checking', 'asset', 2800.0, [2026, 2, 20], null],
      ['carry', [2026, 3]],
      ['carry', [2026, 3, 31, 23, 59]],
      ['clock', [2026, 4, 10, 11, 5, 8, 42, 9]],
      ['update', 0, 'Checking', 'asset', 3100.0, [2026, 4], null],
      ['clock', [2026, 4, 10, 11, 5, 9, 0, 1]],
      ['update', 0, '  Checking  ', 'asset', 3150.0, [2026, 4], null],
      ['update', 1, 'Home Loan', 'liability', 249000.0, [2026, 4], null],
      ['update', 3, 'Café Savings', 'liability', 12.5, [2026, 3], null],
      ['update', 'missing-id', 'Ghost', 'asset', 1.0, [2026, 4], null],
      ['update', 0, ' ', 'asset', 1.0, [2026, 4], null],
      ['deleteSnapshot', 1, [1, 0]],
      ['deleteSnapshot', 1, ['at', 2025, 1, 1]],
      ['deleteSnapshot', 'missing-id', ['at', 2026, 1, 31, 23, 59, 59, 999]],
      ['deleteEntry', 'missing-id'],
      ['add', 'Old Car Loan', 'liability', 5000.0, null, [2025, 11, 15, 10]],
      ['add', 'Big', 'asset', 1e21, [2025, 12], null],
      ['add', 'Tiny', 'asset', 1e-7, [2025, 12], null],
      ['add', 'Overpaid card', 'liability', -250.5, [2026, 4], null],
      ['add', 'Zero', 'asset', 0.0, [2026, 4], null],
      ['deleteEntry', 4],
      ['deleteSnapshot', 4, [4, 0]],
      ['select', [2026, 2, 28, 23, 59]],
      ['add', 'Emergency Fund', 'asset', 123456789.125, null, null],
      ['update', 2, 'Brokerage 401k', 'asset', 10000.5, null, [2026, 2, 14, 16, 30, 0, 0, 7]],
      ['update', 2, 'Brokerage 401k', 'asset', 9000.0, null, [2026, 2, 14, 16, 30, 0, 0, 8]],
      ['clock', [2026, 5, 1, 0, 0]],
      ['carry', [2026, 5]],
      ['select', [2026, 5, 1]],
      ['select', [2026, 5, 1]],
    ],
  },
  {
    // Data another writer produced: unknown keys, int lexemes, legacy
    // snapshot shapes, a UTC date, missing/null snapshot lists and a
    // non-canonical type. Dart rewrites it; Swift patches it. Memory must
    // agree after every step (bytes differ by design).
    'name': 'foreign',
    'byteComparable': false,
    'seed': 12,
    'launch': [2026, 6, 15, 12],
    'initial': <String, Object?>{
      'netWorthEntries': [
        {
          'id': 'legacy-1',
          'name': 'Legacy Savings',
          'type': 'Asset',
          'createdAt': '2025-01-05T10:00:00.000',
          'color': 'green',
          'snapshots': [
            {'monthKey': '2026-01', 'amount': 1000},
            {'monthKey': '2026-02', 'updatedAt': '2026-02-11T08:00:00.000', 'amount': 1100.5},
            {'monthKey': '2026-03', 'updatedAt': '2026-05-01T08:00:00.000', 'amount': 1200},
            {'updatedAt': '2026-04-20T09:30:00.000', 'amount': 1300.0},
            {'recordedAt': '2026-05-02T10:00:00.000Z', 'amount': 1400.0, 'note': 'utc'},
            {'amount': 7},
          ],
        },
        {
          'id': 'no-snapshots',
          'name': 'Pending',
          'type': 'liability',
          'createdAt': '2026-01-01T00:00:00.000',
        },
        {
          'id': 'null-snapshots',
          'name': 'Null list',
          'type': 'liability',
          'createdAt': '2026-01-01T00:00:00.000',
          'snapshots': null,
          'extra': {'nested': [1, 2.50, 'x']},
        },
        {
          'extra': true,
          'createdAt': '2026-02-01T09:00:00.000',
          'type': 'asset',
          'name': 'Reordered keys',
          'id': 'reordered',
          'snapshots': [
            {'amount': 50, 'recordedAt': '2026-02-01T09:00:00.000', 'source': 'import'},
          ],
        },
      ],
      'selectedNetWorthMonth': '2026-03-15T10:20:30.000',
    },
    'ops': [
      ['update', 'legacy-1', 'Legacy Savings', 'asset', 1500.0, [2026, 6], null],
      ['update', 'reordered', 'Reordered keys', 'asset', 60.0, [2026, 3], null],
      ['update', 'reordered', 'Renamed', 'liability', 60.0, [2026, 3], null],
      ['update', 'no-snapshots', 'Pending', 'liability', 75.0, null, null],
      ['deleteSnapshot', 'legacy-1', [0, 4]],
      ['carry', [2026, 7]],
      ['deleteSnapshot', 'null-snapshots', ['at', 2026, 1]],
      ['update', 'null-snapshots', 'Null list', 'liability', 20.0, [2026, 5], null],
      ['deleteEntry', 'no-snapshots'],
      ['select', [2026, 7, 4]],
    ],
  },
  {
    // DST: America/New_York skips 02:00-03:00 on 2026-03-08 and repeats
    // 01:00-02:00 on 2026-11-01; America/Santiago skips 00:00-01:00 on
    // 2026-09-06 and repeats 23:00-24:00 on 2026-04-04; Australia/Lord_Howe
    // skips 02:00-02:30 on 2026-10-04 and repeats 01:30-02:00 on 2026-04-05.
    // Elsewhere (Asia/Kolkata, UTC) these are ordinary times.
    'name': 'dst',
    'byteComparable': true,
    'seed': 13,
    'launch': [2026, 9, 6, 0, 30],
    'initial': <String, Object?>{},
    'ops': [
      ['select', [2026, 9, 6, 0, 30]],
      ['add', 'Gap now', 'asset', 100.0, null, null],
      ['add', 'Edge', 'asset', 200.0, null, [2026, 9, 5, 23, 30]],
      ['update', 1, 'Edge', 'asset', 210.0, null, [2026, 9, 6, 0, 15]],
      ['update', 1, 'Edge', 'asset', 220.0, null, [2026, 9, 6, 1, 15]],
      ['update', 1, 'Edge', 'asset', 190.0, [2026, 8], null],
      ['add', 'Fall', 'liability', 50.0, null, [2026, 4, 4, 23, 30]],
      ['update', 2, 'Fall', 'liability', 55.0, null, [2026, 4, 5]],
      ['update', 2, 'Fall', 'liability', 60.0, null, [2026, 4, 4, 23, 59, 59, 999]],
      ['add', 'Spring NY', 'asset', 10.0, null, [2026, 3, 8, 2, 30]],
      ['update', 3, 'Spring NY', 'asset', 11.0, null, [2026, 3, 8, 3, 30]],
      ['add', 'Fall NY', 'liability', 5.0, null, [2026, 11, 1, 1, 30]],
      ['update', 4, 'Fall NY', 'liability', 6.0, [2026, 10], null],
      ['carry', [2026, 10]],
      ['deleteSnapshot', 1, ['at', 2026, 9, 6, 0, 15]],
      ['clock', [2026, 11, 1, 1, 30]],
      ['carry', [2026, 11]],
      ['update', 0, 'Gap now', 'asset', 101.0, [2026, 11], null],
      ['add', 'Spring LH', 'asset', 30.0, null, [2026, 10, 4, 2, 15]],
      ['update', 5, 'Spring LH', 'asset', 31.0, null, [2026, 10, 4, 2, 45]],
      ['add', 'Fall LH', 'liability', 8.0, null, [2026, 4, 5, 1, 45]],
      ['update', 6, 'Fall LH', 'liability', 9.0, null, [2026, 4, 5, 1, 15]],
      ['select', [2026, 11, 1, 1, 30]],
    ],
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('net worth mutations', () async {
    final out = <Map<String, Object?>>[];
    for (final scenario in scenarios) {
      out.add(await runScenario(scenario));
    }
    pinClock(null);
    writeJson('$fixturesRoot/$zoneDir/mutations.json', {
      'tz': parityTz,
      'scenarios': out,
    });
  });

  test('formatting', () {
    if (parityTz != 'America/New_York') return;

    final configs = <(String, String?, bool)>[
      ('USD', null, false),
      ('EUR', 'de_DE', false),
      ('JPY', 'ja_JP', false),
      ('GBP', 'en_GB', false),
      ('INR', 'en_US', false),
      ('USD', null, true),
    ];
    final compactValues = <double>[
      0, -0.0, 0.04, 0.05, 0.5, -0.5, 5, 9.94, 9.95, 9.96, 99.5, 99.94, 99.95,
      100, 999.49, 999.5, 999.99, 1000, 1234, 1499.99, 1500, 9994, 9995,
      12345, 99950, 123456, 999499, 999500, 999999, 1234567, 1.5e9, 2.5e12,
      9.9999e14, 1e15, 1.234e18, -1234, -999999, 0.1 + 0.2,
    ];
    final deltaPairs = <(double, double)>[
      (0, 0), (0, 5000), (-0.0, 5000), (4120, 179130), (-4120, 179130),
      (100, 0.001), (100, 0.0011), (100, -0.002), (50, -1000), (-50, -1000),
      (1234.5, 1000), (0.5, 1000), (1e9, 3), (-0.4, 100),
    ];
    final compact = <Map<String, Object?>>[];
    final pills = <Map<String, Object?>>[];
    for (final (currency, locale, hidden) in configs) {
      MoneyFormatter.configure(
          currencyCode: currency, locale: locale, hideBalances: hidden);
      for (final v in compactValues) {
        compact.add({
          'currency': currency,
          'locale': locale,
          'hidden': hidden,
          'value': bitsHex(v),
          'compact': formatCompactCurrencyNoDecimals(v),
          'delta': compactDelta(v),
        });
      }
      for (final (change, previous) in deltaPairs) {
        pills.add({
          'currency': currency,
          'locale': locale,
          'hidden': hidden,
          'change': bitsHex(change),
          'previous': bitsHex(previous),
          'text': deltaPillText(change, previous),
          'semantics': 'Net worth ${MoneyFormatter.formatSigned(previous)}',
        });
      }
    }
    MoneyFormatter.configure(currencyCode: 'USD');

    final prefillValues = <double>[
      0, -0.0, 1, 12, 999, 1000, 2750.25, 10000.5, 1234567.891, 0.005,
      0.004, 0.125, 1.005, 2.675, 0.1 + 0.2, 99.995, 999999.999, 1e15, 1e21,
      123456789012.34, -1234.5, 5e-324,
    ];
    final inputPairs = <(String, String)>[
      ('', ''), ('', '1'), ('1', '12'), ('12', '123'), ('123', '1234'),
      ('1,234', '12,345'), ('12,345', '123,456'), ('123,456', '1,234,567'),
      ('1,234', '1,2345'), ('1', '1.'), ('1.', '1.5'), ('1.5', '1.55'),
      ('1.55', '1.555'), ('1.55', '1.5.5'), ('', '.'), ('.', '.5'),
      ('', '-1'), ('', 'a'), ('1', '1a'), ('', '1e3'), ('', '١٢'), ('', '１'),
      ('', ' 1'), ('1', '1 '), ('', '00012'), ('', ','), ('1,000', '1,00'),
      ('', '1234567.89'), ('9', '9\n'), ('', '12,34.5'), ('', '.55'),
    ];
    final parseInputs = <String>[
      '', ' ', '0', '0.00', '12.', '.5', '.', '00012', '1,234.56',
      ' 1,000 ', '-1', '-0', '1e3', 'NaN', 'Infinity', 'abc', '1.2.3',
      '9' * 330, '\u{FEFF}5\u{FEFF}', '1,,2', ',',
    ];
    final percents = <double>[
      0, -0.0, 0.04, -0.04, 0.05, 0.05000001, 0.15, 0.25, 0.35, 12.345,
      -12.345, 50, 78.94736842105263, 99.95, 100, 1e21, -1e-7,
    ];
    final scaleLists = <List<double>>[
      [0], [5000], [-5000], [0, 0], [1000, 1400], [1400, 1000, 1200],
      [-100, 100], [0.3, 0.30000000000000004], [1e9, 1e9 + 1],
      [-250000, -249000, -248500], [1, 2, 3, 4, 5, 6, 7, 8],
      [-0.0, 0.0], [0.0, -0.0],
    ];
    final splitPairs = <(double, double)>[
      (0, 0), (1000, 400), (0, 400), (400, 0), (1, 1999), (1, 2001),
      (0.4995, 999.5005), (0.0005, 0.9995), (1e-300, 1), (-100, 50),
    ];
    final iconNames = <String>[
      'Checking', 'BANK of X', 'High-yield savings', 'Roth IRA',
      'Brokerage', 'Stocks', 'My 401k', 'ETF', 'Portfolio', 'Investments',
      'House', 'Home', 'Real estate', 'Property', 'Wallet', 'Cash', 'Car',
      'Student loan', 'Auto', 'Personal', 'Credit card', 'Visa Card',
      'Mortgage', 'Mirage', 'İRA', 'CHECKİNG', 'Savings & Checking', '',
    ];
    final gridValueLists = <List<double>>[
      [5000.0], [1000.0, 1500.0], [-2500.0, 400.0, 1200.0], [0.0],
      [100.0, 100.0], [12000.5, 13500.25, 11800.0, 15020.75],
      [-900.0, -400.0], [0.0, 1.0], [-250000, -249000, -248500],
      [1e9, 1e9 + 1],
    ];
    final textDates = <List<int>>[
      [2026, 3, 5, 9, 0], [2026, 3, 5, 15, 7], [2026, 12, 31, 0, 0],
      [2026, 1, 1, 12, 0], [2000, 2, 29, 23, 59], [1999, 11, 30, 12, 30],
    ];

    writeJson('$fixturesRoot/worth/formatting.json', {
      'compact': compact,
      'deltaPills': pills,
      'prefill': [
        for (final v in prefillValues)
          {'value': bitsHex(v), 'text': NumberFormat('#,##0.##').format(v)}
      ],
      'input': [
        for (final (o, n) in inputPairs)
          {'old': o, 'new': n, 'result': currencyInput(o, n)}
      ],
      'parse': [
        for (final t in parseInputs) {'text': t, 'result': bitsOrNull(saveAmount(t))}
      ],
      'percents': [
        for (final p in percents)
          {
            'value': bitsHex(p),
            'change': '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%',
            'shareAssets': '${(p / 100 * 100).toStringAsFixed(1)}% of assets',
            'share': bitsHex(p / 100),
          }
      ],
      'scales': [
        for (final values in scaleLists)
          {
            'values': values.map(bitsHex).toList(),
            'growth': growthScale(values).map(bitsHex).toList(),
            'account': accountScale(values).map(bitsHex).toList(),
            'hover': [
              for (var i = 0; i < values.length; i++)
                () {
                  final a = overlayAlignment(i, values);
                  return [bitsHex(a[0] as double), bitsHex(a[1] as double), a[2]];
                }()
            ],
          }
      ],
      'gridLines': [
        for (final values in gridValueLists)
          {
            'values': values.map(bitsHex).toList(),
            'growth': gridLines(growthScale(values)).map(bitsHex).toList(),
            'account': gridLines(accountScale(values)).map(bitsHex).toList(),
          }
      ],
      'axisLabels': [
        for (var n = 1; n <= 30; n++)
          {
            'count': n,
            'growth': growthAxisLabelIndices(n),
            'account': accountAxisLabelIndices(n),
          }
      ],
      'splits': [
        for (final (assets, liabilities) in splitPairs)
          () {
            // NW:861-862 and glow_progress_bar.dart SplitGlowBar flex.
            final total = assets + liabilities;
            final f = total > 0 ? assets / total : 1.0;
            return {
              'assets': bitsHex(assets),
              'liabilities': bitsHex(liabilities),
              'fraction': bitsHex(f),
              'flex': [(f * 1000).round(), ((1 - f) * 1000).round()],
            };
          }()
      ],
      'icons': [
        for (final name in iconNames)
          for (final type in NetWorthEntryType.values)
            {
              'name': name,
              'type': type.name,
              'icon': iconForEntry(NetWorthEntry(
                  id: 'x', name: name, type: type, createdAt: DateTime(2026))),
            }
      ],
      'texts': [
        for (final c in textDates)
          () {
            final d = local(c);
            return {
              'date': c,
              // NW:285
              'eyebrow': 'TOTAL · ${DateFormat('MMMM y').format(d).toUpperCase()}',
              // NW:1064
              'emptyAssets': 'No assets tracked for ${formatNetWorthMonth(d)}.',
              // NW:569
              'axis': DateFormat("MMM ''yy").format(d).toUpperCase(),
              // NW:820-824
              'hoverMonth': DateFormat('MMMM y').format(d),
              'hoverDay': DateFormat('MMM d, y').format(d),
              // NW:1646
              'lastUpdate': 'Last update ${DateFormat.yMMMd().format(d)}',
              // NW:2074-2076
              'trendAxis': DateFormat.MMMd().format(d).toUpperCase(),
              // NW:2020-2023 (to the same date)
              'trendRange': '${DateFormat.MMMd().format(d)} to ${DateFormat.MMMd().format(d)}',
              // NW:2913-2917
              'deleteSnapshot':
                  'Remove the ${DateFormat.yMMMd().add_jm().format(d)} '
                      'balance for Brokerage? This only removes this one data point.',
            };
          }()
      ],
    });
  });
}
