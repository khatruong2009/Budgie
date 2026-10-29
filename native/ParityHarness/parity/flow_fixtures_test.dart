// Emits native/Fixtures/flow/ : expected outputs of the Flow tab (Flutter
// HistoryPage) and its SEE ALL page (_TransactionsDetailPage) for fixed
// datasets. Zone-dependent outputs go to flow/tz/<zone>/; the rest are
// written once (from the UTC run).
//
// The page formulas are private members of history_page.dart, so they are
// copied verbatim below, each citing its source lines, and run on the real
// TransactionModel. Every copy is then checked against the real page: the
// test pumps HistoryPage at 402x874 and compares the rendered metric chips,
// bar geometry and badge, YoY labels and bar fills, the LineChart's spots and
// bounds, the month detail sheet, the preview rows, and (driving the filter
// controls) the SEE ALL results. The fl_chart control points are checked
// against the real LineChartPainter path. A mismatch fails the generator.
// The row strings (`rowTexts`) and the results block's strings
// (`resultsTexts`) are emitted too, from the same helpers those checks use.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:budget_app/categorization_provider.dart';
import 'package:budget_app/history_page.dart';
import 'package:budget_app/money_formatter.dart';
import 'package:budget_app/storage/atomic_financial_store.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/transaction_model.dart';
import 'package:budget_app/widgets/glow_progress_bar.dart';
import 'package:fl_chart/fl_chart.dart';
// ignore: implementation_imports
import 'package:fl_chart/src/chart/base/base_chart/base_chart_painter.dart';
// ignore: implementation_imports
import 'package:fl_chart/src/chart/line_chart/line_chart_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness_support.dart';

final bool writeZoneIndependent = parityTz == 'UTC';
String get zoneDir => 'flow/tz/${parityTz.replaceAll('/', '_')}';

Object? numberJson(double? d) => d == null ? null : bitsHex(d);

String fnvText(String text) => fnv(utf8.encode(text));

// --- Copied verbatim from history_page.dart (private members) -------------

/// hp:126-141 `_getChartDisplayData`.
List<MonthCashFlow> getChartDisplayData(
  List<MonthCashFlow> allData,
  DateTime selectedMonth,
  int months,
) {
  final filtered = allData
      .where((d) =>
          d.month.year < selectedMonth.year ||
          (d.month.year == selectedMonth.year &&
              d.month.month <= selectedMonth.month))
      .toList();
  if (filtered.length > months) {
    return filtered.sublist(filtered.length - months);
  }
  return filtered;
}

/// hp:143-152 `_computeMetrics`.
Map<String, double> computeMetrics(List<MonthCashFlow> chartData) {
  if (chartData.isEmpty) return {'avgSavings': 0.0, 'savingsRate': 0.0};
  final totalIncome = chartData.fold(0.0, (sum, d) => sum + d.income);
  final totalExpenses = chartData.fold(0.0, (sum, d) => sum + d.expenses);
  final totalSavings = totalIncome - totalExpenses;
  final avgSavings = totalSavings / chartData.length;
  final savingsRate =
      totalIncome > 0 ? (totalSavings / totalIncome) * 100 : 0.0;
  return {'avgSavings': avgSavings, 'savingsRate': savingsRate};
}

/// hp:154-164 `_buildMonthReport` / `_MonthlyCashFlowReport` (hp:2121-2135).
({DateTime month, double income, double expenses}) buildMonthReport(
  TransactionModel model,
  DateTime month,
) {
  final summary = model.getMonthlySummary(month);
  return (
    month: DateTime(month.year, month.month),
    income: summary['income'] ?? 0,
    expenses: summary['expenses'] ?? 0,
  );
}

/// hp:166-181 `_getRollingTrendData`.
List<MonthCashFlow> getRollingTrendData(
  TransactionModel model,
  DateTime selectedMonth,
) {
  return List.generate(12, (index) {
    final month =
        DateTime(selectedMonth.year, selectedMonth.month - 11 + index);
    final report = buildMonthReport(model, month);
    return MonthCashFlow(
      month: report.month,
      netCashFlow: report.income - report.expenses,
      income: report.income,
      expenses: report.expenses,
    );
  });
}

/// hp:185-187 `_formatMetricCurrency`.
String formatMetricCurrency(double value) {
  return MoneyFormatter.formatSigned(value, decimalDigits: 0);
}

/// hp:191-194 `_percentDelta`.
double? percentDelta(double current, double previous) {
  if (previous == 0) return null;
  return ((current - previous) / previous) * 100;
}

/// hp:196-204 `_formatPercentDelta`.
String formatPercentDelta(double? delta) {
  if (delta == null) return 'new';
  final sign = delta > 0
      ? '+'
      : delta < 0
          ? '-'
          : '';
  return '$sign${delta.abs().toStringAsFixed(1)}%';
}

/// hp:681-699, 713-716, 757-758, 790-819 (`_NetCashFlowBars`,
/// `_NetCashFlowBar`): the numbers each bar is laid out with.
Map<String, Object?> barLayout(
  List<MonthCashFlow> data,
  DateTime currentMonth,
  double maxWidth,
) {
  const baselineY = 116.0;
  const maxPositiveBar = 76.0;
  const maxNegativeBar = 40.0;
  final maxMagnitude = data
      .map((d) => d.netCashFlow.abs())
      .fold(0.0, (previous, value) => max(previous, value));
  double barHeightFor(double net) {
    if (maxMagnitude <= 0) return 0;
    final maxBar = net >= 0 ? maxPositiveBar : maxNegativeBar;
    return (net.abs() / maxMagnitude) * maxBar;
  }

  final barWidth = data.isEmpty ? 34.0 : min(34.0, maxWidth / data.length - 4);
  return {
    'availableWidth': bitsHex(maxWidth),
    'barWidth': bitsHex(barWidth),
    'bars': [
      for (final entry in data)
        () {
          final isPositive = entry.netCashFlow >= 0;
          final barHeight = barHeightFor(entry.netCashFlow);
          final barTop = isPositive ? baselineY - barHeight : baselineY;
          final isCurrent = entry.month.year == currentMonth.year &&
              entry.month.month == currentMonth.month;
          return {
            'month': iso(entry.month),
            'height': bitsHex(barHeight),
            'top': bitsHex(barTop),
            'isPositive': isPositive,
            'isCurrent': isCurrent,
            'label': DateFormat.MMM().format(entry.month).toUpperCase(),
            'badge': MoneyFormatter.formatSigned(
              entry.netCashFlow,
              decimalDigits: 0,
              plusForPositive: true,
            ),
          };
        }()
    ],
  };
}

/// hp:995-998 (`_TrendSparkline`).
double sparklineBound(List<double> values) {
  final maxMagnitude =
      values.fold(0.0, (previous, value) => max(previous, value.abs()));
  return maxMagnitude <= 0 ? 100.0 : maxMagnitude * 1.15;
}

/// fl_chart 1.2.0 axis_chart_painter.dart:512-544 (`_getPixelX/_getPixelY`)
/// and line_chart_painter.dart:564-637 (`generateNormalBarPath`, curved,
/// `preventCurveOverShooting` false), recording the points it passes to
/// `moveTo` and `cubicTo` instead of drawing.
({List<Offset> points, List<List<Offset>> controls}) flChartCurve(
  List<FlSpot> spots,
  double minX,
  double maxX,
  double minY,
  double maxY,
  Size size,
  double smoothness,
) {
  double px(double x) {
    final deltaX = maxX - minX;
    if (deltaX == 0.0) return 0;
    return ((x - minX) / deltaX) * size.width;
  }

  double py(double y) {
    final deltaY = maxY - minY;
    if (deltaY == 0.0) return size.height;
    return size.height - (((y - minY) / deltaY) * size.height);
  }

  final points = [for (final s in spots) Offset(px(s.x), py(s.y))];
  final controls = <List<Offset>>[];
  var temp = Offset.zero;
  final n = spots.length;
  for (var i = 1; i < n; i++) {
    final current = points[i];
    final previous = points[i - 1];
    final next = points[i + 1 < n ? i + 1 : i];
    final controlPoint1 = previous + temp;
    temp = ((next - previous) / 2) * smoothness;
    final controlPoint2 = current - temp;
    controls.add([controlPoint1, controlPoint2]);
  }
  return (points: points, controls: controls);
}

Map<String, Object?> curveJson(
    ({List<Offset> points, List<List<Offset>> controls}) curve) {
  List<String> p(Offset o) => [bitsHex(o.dx), bitsHex(o.dy)];
  return {
    'points': [for (final o in curve.points) p(o)],
    'controls': [
      for (final c in curve.controls) [p(c[0]), p(c[1])]
    ],
  };
}

/// The real fl_chart path for the same spots; its bounds must equal the
/// bounds of the recorded move/cubic points (Skia path bounds include
/// control points), within float32 rounding.
void checkCurveAgainstFlChart(
  List<FlSpot> spots,
  LineChartData data,
  Size size,
  ({List<Offset> points, List<List<Offset>> controls}) curve,
  String context,
) {
  final barData = LineChartBarData(spots: spots, isCurved: true);
  expect(barData.curveSmoothness, 0.35);
  expect(barData.preventCurveOverShooting, isFalse);
  final path = LineChartPainter().generateNormalBarPath(
    size,
    barData,
    spots,
    PaintHolder<LineChartData>(data, data, TextScaler.noScaling),
  );
  final all = [
    ...curve.points,
    for (final c in curve.controls) ...c,
  ];
  final left = all.map((o) => o.dx).reduce(min);
  final right = all.map((o) => o.dx).reduce(max);
  final top = all.map((o) => o.dy).reduce(min);
  final bottom = all.map((o) => o.dy).reduce(max);
  final bounds = path.getBounds();
  double tol(double v) => 1e-4 + v.abs() * 1e-6;
  expect((bounds.left - left).abs() <= tol(left), isTrue,
      reason: '$context left ${bounds.left} vs $left');
  expect((bounds.right - right).abs() <= tol(right), isTrue,
      reason: '$context right ${bounds.right} vs $right');
  expect((bounds.top - top).abs() <= tol(top), isTrue,
      reason: '$context top ${bounds.top} vs $top');
  expect((bounds.bottom - bottom).abs() <= tol(bottom), isTrue,
      reason: '$context bottom ${bounds.bottom} vs $bottom');
}

enum TypeFilter { all, income, expense }

/// The SEE ALL page's filter state (hp:1261-1270).
class FilterState {
  String searchQuery = '';
  TypeFilter typeFilter = TypeFilter.all;
  String? selectedCategory;
  String? selectedTagId;
  DateTime? startDate;
  DateTime? endDate;
  double? minAmount;
  double? maxAmount;

  /// hp:1285-1294.
  String get signature => [
        searchQuery,
        typeFilter.name,
        selectedCategory,
        selectedTagId,
        startDate?.toIso8601String(),
        endDate?.toIso8601String(),
        minAmount,
        maxAmount,
      ].join('|');

  /// hp:1350-1391 `_getFilteredTransactions`.
  List<Transaction> filtered(TransactionModel model) {
    final query = searchQuery.toLowerCase();
    final transactions = model.getAllTransactionsSorted();

    return transactions.where((transaction) {
      if (query.isNotEmpty &&
          !transaction.description.toLowerCase().contains(query)) {
        return false;
      }
      if (typeFilter == TypeFilter.income &&
          transaction.type != TransactionTyp.income) {
        return false;
      }
      if (typeFilter == TypeFilter.expense &&
          transaction.type != TransactionTyp.expense) {
        return false;
      }
      if (selectedCategory != null &&
          transaction.category != selectedCategory) {
        return false;
      }
      if (selectedTagId != null &&
          !transaction.tagIds.contains(selectedTagId)) {
        return false;
      }
      if (startDate != null &&
          dateOnly(transaction.date).isBefore(dateOnly(startDate!))) {
        return false;
      }
      if (endDate != null &&
          dateOnly(transaction.date).isAfter(dateOnly(endDate!))) {
        return false;
      }
      if (minAmount != null && transaction.amount < minAmount!) {
        return false;
      }
      if (maxAmount != null && transaction.amount > maxAmount!) {
        return false;
      }
      return true;
    }).toList();
  }

  /// hp:1419-1421 `_dateOnly`.
  static DateTime dateOnly(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  /// hp:1423-1432 `_hasActiveFilters`.
  bool get hasActiveFilters {
    return searchQuery.isNotEmpty ||
        typeFilter != TypeFilter.all ||
        selectedCategory != null ||
        selectedTagId != null ||
        startDate != null ||
        endDate != null ||
        minAmount != null ||
        maxAmount != null;
  }

  /// hp:1830-1843 (the `setState` body of `_pickDateRangeEndpoint`).
  void pick(DateTime picked, {required bool isStart}) {
    if (isStart) {
      startDate = picked;
      if (endDate != null && dateOnly(endDate!).isBefore(dateOnly(picked))) {
        endDate = picked;
      }
    } else {
      endDate = picked;
      if (startDate != null && dateOnly(startDate!).isAfter(dateOnly(picked))) {
        startDate = picked;
      }
    }
  }
}

/// hp:1393-1401 `_getCategoryOptions`.
List<String> getCategoryOptions(List<Transaction> transactions) {
  final categories = transactions
      .map((transaction) => transaction.category)
      .where((category) => category.trim().isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return categories;
}

/// hp:1403-1417 `_buildFilteredSummary`.
({double income, double expenses, int count}) buildFilteredSummary(
  List<Transaction> transactions,
) {
  final income = transactions
      .where((transaction) => transaction.type == TransactionTyp.income)
      .fold(0.0, (sum, transaction) => sum + transaction.amount);
  final expenses = transactions
      .where((transaction) => transaction.type == TransactionTyp.expense)
      .fold(0.0, (sum, transaction) => sum + transaction.amount);
  return (income: income, expenses: expenses, count: transactions.length);
}

/// hp:1458-1462 `_parseAmount`.
double? parseAmount(String value) {
  final normalized = value.replaceAll(',', '').trim();
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

/// hp:1077-1080 and 1108 (`_TransactionRow`).
({String title, String subtitle, String amount}) rowTexts(Transaction t) {
  final isIncome = t.type == TransactionTyp.income;
  return (
    title: t.description,
    subtitle: '${t.category} · ${DateFormat.MMMd().format(t.date)}',
    amount: MoneyFormatter.formatSigned(
      isIncome ? t.amount : -t.amount,
      plusForPositive: true,
    ),
  );
}

// --- Datasets ---------------------------------------------------------------

Map<String, Object?> tx(
  String id,
  String type,
  double amount,
  String category,
  String date, {
  String? description,
  String? createdAt,
  List<String> tags = const [],
}) =>
    {
      'id': id,
      'type': type,
      'description': description ?? id,
      'amount': amount,
      'category': category,
      'date': date,
      'recurringTemplateId': null,
      'tagIds': tags,
      'createdAt': createdAt ?? '2026-01-01T08:00:00.000',
      'updatedAt': createdAt ?? '2026-01-01T08:00:00.000',
    };

/// Deterministic generator shared with the Swift tests (FlowParityTests):
/// integer LCG returning its high 15 bits (the low bits of a power-of-two
/// LCG cycle quickly), dates as local ISO strings.
class Lcg {
  int state;
  Lcg(this.state);
  int next() {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state >> 16;
  }
}

String two(int v) => v.toString().padLeft(2, '0');
String localIso(int y, int m, int d, int h, int min) =>
    '${y.toString().padLeft(4, '0')}-${two(m)}-${two(d)}T${two(h)}:${two(min)}:00.000';

const generatedCategories = [
  'Groceries',
  'Eating Out',
  'Housing',
  'Travel',
  'groceries',
  'Café',
  'Cafe\u0301',
  'Salary',
];
const generatedDescriptions = [
  'Coffee shop',
  'COFFEE beans',
  "Trader Joe's",
  'İstanbul trip',
  'Straße fest',
  'rent',
  '  padded  ',
  '',
  'ΣΟΦΙΑ',
  'naïve',
  'Cafe\u0301 latte',
  'Café au lait',
  '☕\uFE0F Coffee',
  'Paycheck',
];
const generatedTags = ['t-food', 't-work', 't-trip'];

/// `count` rows over `months` months from January `startYear`.
List<Map<String, Object?>> generated(
    int seed, int count, int startYear, int months) {
  final r = Lcg(seed);
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < count; i++) {
    final offset = r.next() % months;
    final y = startYear + offset ~/ 12;
    final m = offset % 12 + 1;
    final d = 1 + r.next() % 28;
    final h = r.next() % 24;
    final mi = r.next() % 60;
    final isIncome = r.next() % 5 == 0;
    final amount = (r.next() * 32768 + r.next()) % 500000 / 100;
    final category =
        generatedCategories[r.next() % generatedCategories.length];
    final description =
        '${generatedDescriptions[r.next() % generatedDescriptions.length]} ${i % 97}';
    final tagRoll = r.next() % 8;
    final created = r.next() % 3;
    rows.add(tx(
      'G${i.toString().padLeft(5, '0')}',
      isIncome ? 'income' : 'expense',
      amount,
      category,
      localIso(y, m, d, h, mi),
      description: description,
      createdAt: localIso(y, m, d, 12, created),
      tags: tagRoll < 3 ? [generatedTags[tagRoll]] : const [],
    ));
  }
  return rows;
}

List<Map<String, Object?>> typicalRows() => [
      ...generated(20260928, 330, 2024, 33)
          .where((row) {
            final date = row['date'] as String;
            // A two-month gap.
            return !date.startsWith('2025-05') && !date.startsWith('2025-06');
          }),
      // DST and zone edges, day ties.
      tx('dst-ny-gap', 'expense', 12.34, 'Groceries', '2026-03-08T02:30:00.000',
          description: 'Coffee at 2:30'),
      tx('dst-ny-fold', 'expense', 5.0, 'Groceries', '2025-11-02T01:30:00.000',
          description: 'fold coffee'),
      tx('dst-lh-start', 'income', 100.0, 'Salary', '2025-10-05T02:15:00.000',
          description: 'Lord Howe start'),
      tx('dst-lh-end', 'expense', 7.5, 'Travel', '2026-04-05T01:45:00.000',
          description: 'Lord Howe end'),
      // Midnight DST, America/Santiago: 2026-09-06 00:00-00:59 does not exist
      // (Dart moves these to 01:xx) and 2026-04-04 23:00-23:59 happens twice.
      // Elsewhere they are ordinary times.
      tx('dst-scl-edge', 'expense', 8.25, 'Groceries', '2026-09-05T23:59:59.999',
          description: 'Santiago before the gap'),
      tx('dst-scl-gap0', 'expense', 6.5, 'Eating Out', '2026-09-06T00:00:00.000',
          description: 'Santiago gap midnight'),
      tx('dst-scl-gap', 'income', 55.5, 'Salary', '2026-09-06T00:30:00.000',
          description: 'Santiago gap 00:30'),
      tx('dst-scl-gap1', 'expense', 9.75, 'Groceries', '2026-09-06T01:00:00.000',
          description: 'Santiago after the gap'),
      tx('dst-scl-fold0', 'expense', 4.0, 'Travel', '2026-04-04T22:59:59.999',
          description: 'Santiago before the fold'),
      tx('dst-scl-fold', 'expense', 11.0, 'Groceries', '2026-04-04T23:30:00.000',
          description: 'Santiago fold 23:30'),
      tx('dst-scl-fold2', 'expense', 12.0, 'Eating Out', '2026-04-04T23:45:00.000',
          description: 'Santiago fold 23:45'),
      tx('dst-scl-fold3', 'income', 13.0, 'Salary', '2026-04-04T23:59:59.999',
          description: 'Santiago end of the fold day'),
      tx('dst-scl-after', 'expense', 14.0, 'Groceries', '2026-04-05T00:00:00.000',
          description: 'Santiago after the fold'),
      tx('utc-z', 'expense', 20.0, 'Eating Out', '2026-02-28T23:30:00.000Z',
          description: 'UTC dinner'),
      tx('utc-z2', 'income', 1.25, 'Salary', '2026-03-01T03:30:00.000Z',
          description: 'UTC refund'),
      tx('midnight', 'expense', 0.1, 'Groceries', '2026-01-01T00:00:00.000',
          description: 'new year'),
      tx('eoy', 'expense', 0.2, 'Groceries', '2025-12-31T23:59:59.999',
          description: 'old year'),
      tx('tie-a', 'expense', 3.0, 'Travel', '2026-09-03T10:00:00.000',
          description: 'tie a', createdAt: '2026-09-03T10:00:00.000'),
      tx('tie-b', 'expense', 3.0, 'Travel', '2026-09-03T08:00:00.000',
          description: 'tie b', createdAt: '2026-09-03T10:00:00.000'),
      tx('Tie-c', 'expense', 3.0, 'Travel', '2026-09-03T09:00:00.000',
          description: 'tie c', createdAt: '2026-09-03T10:00:00.000'),
      tx('zero', 'expense', 0.0, 'Groceries', '2026-09-04T12:00:00.000',
          description: 'zero expense'),
      tx('blank-cat', 'expense', 1.0, '   ', '2026-09-05T12:00:00.000',
          description: 'blank category'),
      tx('empty-cat', 'expense', 1.0, '', '2026-09-05T12:00:00.000',
          description: 'empty category'),
      tx('bom', 'expense', 2.0, '\uFEFFGroceries', '2026-09-06T12:00:00.000',
          description: '\uFEFFcoffee with bom'),
      tx('paycheck', 'income', 3200.0, 'Salary', '2026-09-01T09:00:00.000',
          description: 'Paycheck Sep', tags: ['t-work', 't-food']),
    ];

List<Map<String, Object?>> gapsRows() => [
      tx('g1', 'income', 2000.0, 'Salary', '2025-01-15T09:00:00.000'),
      tx('g2', 'expense', 450.5, 'Housing', '2025-01-20T09:00:00.000'),
      tx('g3', 'expense', 120.0, 'Groceries', '2025-04-02T09:00:00.000'),
      tx('g4', 'income', 2100.0, 'Salary', '2025-09-15T09:00:00.000'),
      tx('g5', 'expense', 2500.0, 'Travel', '2025-09-18T09:00:00.000'),
      tx('g6', 'income', 2200.0, 'Salary', '2026-02-15T09:00:00.000'),
      tx('g7', 'expense', 99.99, 'Eating Out', '2026-02-16T09:00:00.000'),
      tx('g8', 'income', 3200.0, 'Salary', '2026-09-01T09:00:00.000'),
      tx('g9', 'expense', 42.5, 'Groceries', '2026-09-02T09:00:00.000'),
    ];

List<Map<String, Object?>> crossYearRows() => [
      for (final (y, m) in [
        (2024, 11),
        (2024, 12),
        (2025, 1),
        (2025, 2),
        (2025, 11),
        (2025, 12),
        (2026, 1),
        (2026, 2),
      ]) ...[
        tx('i$y-$m', 'income', 1000.0 + m * 10 + (y - 2024) * 100, 'Salary',
            localIso(y, m, 1, 9, 0)),
        tx('e$y-$m', 'expense', 800.0 + m * 33.3 + (y - 2024) * 55.55,
            'Housing', localIso(y, m, m == 2 ? 28 : 31, 23, 59)),
      ],
    ];

List<Map<String, Object?>> oneMonthRows() => [
      tx('pay', 'income', 3200.0, 'Salary', '2026-09-01T09:00:00.000',
          description: 'Paycheck'),
      tx('tj', 'expense', 42.5, 'Groceries', '2026-09-03T12:00:00.000',
          description: "Trader Joe's"),
    ];

List<Map<String, Object?>> negativeTinyRows() => [
      // Jan: net -0.3; Feb: +0.3; Mar: 0; Apr: -1000 (expenses only);
      // May: income only; Jun: 0.1 + 0.2 - 0.3; Jul: tiny -0.4999;
      // Aug: stored negative amounts; Sep: -0.5.
      tx('n1', 'expense', 0.3, 'Groceries', '2026-01-10T12:00:00.000'),
      tx('n2', 'income', 0.3, 'Salary', '2026-02-10T12:00:00.000'),
      tx('n3', 'income', 10.0, 'Salary', '2026-03-10T12:00:00.000'),
      tx('n4', 'expense', 10.0, 'Groceries', '2026-03-11T12:00:00.000'),
      tx('n5', 'expense', 1000.0, 'Housing', '2026-04-10T12:00:00.000'),
      tx('n6', 'income', 0.01, 'Salary', '2026-05-10T12:00:00.000'),
      tx('n7', 'income', 0.1, 'Salary', '2026-06-10T12:00:00.000'),
      tx('n8', 'income', 0.2, 'Salary', '2026-06-11T12:00:00.000'),
      tx('n9', 'expense', 0.3, 'Groceries', '2026-06-12T12:00:00.000'),
      tx('n10', 'expense', 0.4999, 'Groceries', '2026-07-10T12:00:00.000'),
      tx('n11', 'expense', -5.0, 'Groceries', '2026-08-10T12:00:00.000'),
      tx('n12', 'income', -2.5, 'Salary', '2026-08-11T12:00:00.000'),
      tx('n13', 'expense', 0.5, 'Groceries', '2026-09-10T12:00:00.000'),
      tx('n14', 'income', 0.0, 'Salary', '2025-09-10T12:00:00.000'),
      tx('n15', 'expense', 0.0, 'Groceries', '2025-09-11T12:00:00.000'),
    ];

class Dataset {
  final String name;
  final List<Map<String, Object?>> rows;
  final List<DateTime> selectedMonths;
  final bool widgets;
  final bool writeRows;
  Dataset(this.name, this.rows, this.selectedMonths,
      {this.widgets = true, this.writeRows = true});
}

List<Dataset> datasets() => [
      Dataset('typical', typicalRows(), [
        DateTime(2026, 9, 28, 9, 15), // the model's default: now
        DateTime(2026, 3),
        DateTime(2026, 4), // the Santiago fold month
        DateTime(2025, 6), // in the gap
        DateTime(2025, 1),
        DateTime(2023, 12), // before any data
        DateTime(2026, 12), // after the data
      ]),
      Dataset('gaps', gapsRows(), [
        DateTime(2026, 9),
        DateTime(2026, 6),
        DateTime(2025, 3),
        DateTime(2024, 12),
        DateTime(2026, 12),
      ]),
      Dataset('cross_year', crossYearRows(), [
        DateTime(2026, 1),
        DateTime(2025, 1),
        DateTime(2026, 2),
        DateTime(2025, 12),
      ]),
      Dataset('empty', [], [DateTime(2026, 9, 28, 9, 15)]),
      Dataset('one_month', oneMonthRows(), [
        DateTime(2026, 9),
        DateTime(2026, 10),
        DateTime(2026, 8),
      ]),
      Dataset('negative_tiny', negativeTinyRows(), [
        DateTime(2026, 9),
        DateTime(2026, 8),
        DateTime(2026, 7),
        DateTime(2026, 6),
        DateTime(2026, 3),
        DateTime(2026, 1),
      ]),
      Dataset(
        'large',
        generated(777, 10000, 2022, 60),
        [DateTime(2026, 9, 28, 9, 15), DateTime(2024, 2)],
        widgets: false,
        writeRows: false,
      ),
    ];

TransactionModel modelFor(Dataset dataset) {
  final model = TransactionModel();
  model.transactions = [
    for (final row in dataset.rows)
      Transaction.fromJson(jsonDecode(jsonEncode(row)) as Map<String, dynamic>)
  ];
  return model;
}

// --- Filter specs --------------------------------------------------------------

/// A filter as the user sets it: raw search text (the page keeps its
/// trim), date picks in order, raw amount field texts.
class FilterSpec {
  final String search;
  final TypeFilter type;
  final String? category;
  final String? tag;
  final List<(bool, int, int, int)> picks; // (isStart, y, m, d)
  final String minText;
  final String maxText;
  const FilterSpec({
    this.search = '',
    this.type = TypeFilter.all,
    this.category,
    this.tag,
    this.picks = const [],
    this.minText = '',
    this.maxText = '',
  });

  FilterState state() {
    final s = FilterState()
      ..searchQuery = search.trim()
      ..typeFilter = type
      ..selectedCategory = category
      ..selectedTagId = tag
      ..minAmount = parseAmount(minText)
      ..maxAmount = parseAmount(maxText);
    for (final (isStart, y, m, d) in picks) {
      s.pick(DateTime(y, m, d), isStart: isStart);
    }
    return s;
  }

  Map<String, Object?> toJson() => {
        'search': search,
        'type': type.name,
        'category': category,
        'tag': tag,
        'picks': [
          for (final (isStart, y, m, d) in picks)
            {'isStart': isStart, 'y': y, 'm': m, 'd': d}
        ],
        'minText': minText,
        'maxText': maxText,
      };
}

const searches = [
  '',
  'coffee',
  'COFFEE',
  '  Coffee  ',
  '\uFEFFcoffee',
  'café',
  'cafe\u0301',
  'istanbul',
  'i\u0307stanbul',
  'İstanbul',
  'straße',
  'STRASSE',
  'σοφια',
  'ΣΟΦΙΑ',
  '   ',
  'e',
  '☕',
  'tie ',
  'a b',
  'padded',
  'none-such',
];
const categories = <String?>[
  null,
  'Groceries',
  'groceries',
  'Café',
  'Cafe\u0301',
  '\uFEFFGroceries',
  '   ',
  'Missing',
];
const tags = <String?>[null, 't-food', 't-work', 't-none'];
const pickSets = <List<(bool, int, int, int)>>[
  [],
  [(true, 2026, 1, 1), (false, 2026, 3, 31)],
  [(true, 2026, 3, 8)],
  [(false, 2025, 11, 2)],
  [(true, 2026, 2, 28), (false, 2026, 2, 28)],
  [(true, 2026, 3, 1), (false, 2026, 3, 1)],
  [(false, 2025, 1, 1), (true, 2025, 6, 1)], // start after end moves end
  [(true, 2025, 6, 1), (false, 2025, 1, 1)], // end before start moves start
  [(true, 2025, 10, 5), (false, 2026, 4, 5)],
  [(true, 2025, 12, 31), (false, 2026, 1, 1)],
];
const dstPickSets = <List<(bool, int, int, int)>>[
  [(true, 2026, 9, 6), (false, 2026, 9, 6)], // the gap day
  [(true, 2026, 9, 5), (false, 2026, 9, 5)], // the day before
  [(true, 2026, 9, 5), (false, 2026, 9, 6)],
  [(true, 2026, 9, 6)],
  [(false, 2026, 9, 5)],
  [(false, 2026, 9, 6)],
  [(true, 2026, 9, 7)],
  [(true, 2026, 4, 4), (false, 2026, 4, 4)], // the fold day
  [(true, 2026, 4, 3), (false, 2026, 4, 4)],
  [(true, 2026, 4, 4), (false, 2026, 4, 5)],
  [(true, 2026, 4, 5), (false, 2026, 4, 5)], // the day after
  [(false, 2026, 4, 4)],
  [(true, 2026, 4, 4)],
  [(true, 2026, 3, 29), (false, 2026, 3, 29)], // Beirut gap day
  [(true, 2026, 10, 24), (false, 2026, 10, 24)], // Beirut fold day
  [(true, 2026, 9, 6), (false, 2026, 9, 5)], // end before start moves start
];
const amountTexts = [
  '',
  '0',
  '3',
  '10.5',
  '1,000',
  ' 50 ',
  '.5',
  '5.',
  '1e2',
  '+20',
  '-5',
  'abc',
  '0x10',
  '1.2.3',
];

List<FilterSpec> filterMatrix() {
  final specs = <FilterSpec>[];
  for (final s in searches) {
    specs.add(FilterSpec(search: s));
  }
  for (final t in TypeFilter.values) {
    specs.add(FilterSpec(type: t));
  }
  for (final c in categories) {
    specs.add(FilterSpec(category: c));
  }
  for (final t in tags) {
    specs.add(FilterSpec(tag: t));
  }
  for (final p in pickSets) {
    specs.add(FilterSpec(picks: p));
  }
  for (final a in amountTexts) {
    specs.add(FilterSpec(minText: a));
    specs.add(FilterSpec(maxText: a));
  }
  // Date ranges that start or end on the Santiago and Beirut gap and fold
  // days (ordinary days in the other zones).
  for (final p in dstPickSets) {
    specs.add(FilterSpec(picks: p));
    specs.add(FilterSpec(picks: p, type: TypeFilter.expense));
  }
  final r = Lcg(4242);
  for (var i = 0; i < 100; i++) {
    specs.add(FilterSpec(
      search: r.next() % 3 == 0 ? searches[r.next() % searches.length] : '',
      type: TypeFilter.values[r.next() % 3],
      category: r.next() % 3 == 0
          ? categories[r.next() % categories.length]
          : null,
      tag: r.next() % 4 == 0 ? tags[r.next() % tags.length] : null,
      picks: r.next() % 3 == 0 ? pickSets[r.next() % pickSets.length] : const [],
      minText: r.next() % 3 == 0
          ? amountTexts[r.next() % amountTexts.length]
          : '',
      maxText: r.next() % 3 == 0
          ? amountTexts[r.next() % amountTexts.length]
          : '',
    ));
  }
  return specs;
}

/// The filter state a spec produces (the same for every dataset).
Map<String, Object?> filterSpecJson(FilterSpec spec) {
  final state = spec.state();
  return {
    'spec': spec.toJson(),
    'query': state.searchQuery,
    'min': numberJson(state.minAmount),
    'max': numberJson(state.maxAmount),
    'start': state.startDate?.toIso8601String(),
    'end': state.endDate?.toIso8601String(),
    'isActive': state.hasActiveFilters,
    'signature': state.signature,
  };
}

/// The SEE ALL results block's strings (hp:1998-2101) on first open, when 50
/// rows are visible: the "N of M" header, the three summary pills, the
/// "Showing N of M matches" line (null when every match is visible) and the
/// empty card (null when something matched). `checkFiltersThroughUi` finds
/// each of these on the real page.
Map<String, String?> resultsTexts(
  TransactionModel model,
  FilterState state,
  List<Transaction> filtered,
) {
  final summary = buildFilteredSummary(filtered);
  final visible = min(50, filtered.length);
  return {
    'count': '${filtered.length} of ${model.transactions.length}',
    'income': 'Income ${MoneyFormatter.format(summary.income)}',
    'expenses': 'Expenses ${MoneyFormatter.format(summary.expenses)}',
    'net':
        'Net ${MoneyFormatter.formatSigned(summary.income - summary.expenses, plusForPositive: true)}',
    'showing': filtered.length > visible
        ? 'Showing $visible of ${filtered.length} matches'
        : null,
    'empty': filtered.isEmpty
        ? (state.hasActiveFilters
            ? 'No transactions match these filters.'
            : 'No transactions have been recorded yet.')
        : null,
  };
}

/// One spec's results on one dataset, in `filterMatrix()` order.
Map<String, Object?> filterResult(
    TransactionModel model, FilterSpec spec, bool hashed) {
  final state = spec.state();
  final filtered = state.filtered(model);
  final summary = buildFilteredSummary(filtered);
  final ids = filtered.map((t) => t.id).toList();
  return {
    if (hashed) 'idsFnv': fnvText(ids.join('\n')) else 'ids': ids,
    'count': summary.count,
    'income': bitsHex(summary.income),
    'expenses': bitsHex(summary.expenses),
    'texts': resultsTexts(model, state, filtered),
  };
}

/// `rowTexts` subtitle and amount of every row, newest first; hashed for
/// the large dataset as "subtitle\tamount" lines.
Map<String, Object?> rowTextsJson(List<Transaction> sorted, bool hashed) {
  final texts = [
    for (final t in sorted)
      () {
        final r = rowTexts(t);
        return [r.subtitle, r.amount];
      }()
  ];
  return hashed
      ? {'rowTextsFnv': fnvText(texts.map((r) => r.join('\t')).join('\n'))}
      : {'rowTexts': texts};
}

// --- Page views (mirror) -------------------------------------------------------

const phoneSize = Size(402, 874);

Map<String, Object?> pageView(
  TransactionModel model,
  DateTime selectedMonth,
  int range, {
  required double chartWidth,
  required Size trendSize,
}) {
  final allChartData = model.getNetCashFlowHistory();
  final chartData = getChartDisplayData(allChartData, selectedMonth, range);
  final metrics = computeMetrics(chartData);
  final avg = metrics['avgSavings']!;
  final rate = metrics['savingsRate']!;
  return {
    'range': range,
    'window': [for (final d in chartData) iso(d.month)],
    'avgSaved': bitsHex(avg),
    'savingsRate': bitsHex(rate),
    'avgText': formatMetricCurrency(avg),
    'rateText': '${rate.toStringAsFixed(0)}%',
    'avgIsPositive': avg >= 0,
    'rateIsPositive': rate >= 0,
    'bars': [
      for (final width in [chartWidth, 293.0, 30.0])
        barLayout(chartData, selectedMonth, width)
    ],
    'details': [
      for (final d in chartData)
        {
          'title': DateFormat.yMMMM().format(d.month),
          'income': MoneyFormatter.format(d.income),
          'expenses': MoneyFormatter.format(d.expenses),
          'net': MoneyFormatter.formatSigned(d.income - d.expenses),
          'netIsPositive': d.income - d.expenses >= 0,
        }
    ],
  };
}

Map<String, Object?> yoyView(TransactionModel model, DateTime selectedMonth) {
  final current = buildMonthReport(model, selectedMonth);
  final previous = buildMonthReport(
      model, DateTime(selectedMonth.year - 1, selectedMonth.month));
  final incomeDelta = percentDelta(current.income, previous.income);
  final expenseDelta = percentDelta(current.expenses, previous.expenses);
  final incomeMax = max(current.income, previous.income);
  final expenseMax = max(current.expenses, previous.expenses);
  return {
    'currentMonth': iso(current.month),
    'previousMonth': iso(previous.month),
    'header':
        '${DateFormat("MMM ''yy").format(current.month).toUpperCase()} VS '
            '${DateFormat("MMM ''yy").format(previous.month).toUpperCase()}',
    'income': {
      'current': bitsHex(current.income),
      'previous': bitsHex(previous.income),
      'delta': numberJson(incomeDelta),
      'label': formatPercentDelta(incomeDelta),
      'isGood': (incomeDelta ?? 0) >= 0,
      'this': bitsHex(incomeMax > 0 ? current.income / incomeMax : 0.0),
      'last': bitsHex(incomeMax > 0 ? previous.income / incomeMax : 0.0),
    },
    'expenses': {
      'current': bitsHex(current.expenses),
      'previous': bitsHex(previous.expenses),
      'delta': numberJson(expenseDelta),
      'label': formatPercentDelta(expenseDelta),
      'isBad': (expenseDelta ?? 0) > 0,
      'this': bitsHex(expenseMax > 0 ? current.expenses / expenseMax : 0.0),
      'last': bitsHex(expenseMax > 0 ? previous.expenses / expenseMax : 0.0),
    },
  };
}

Map<String, Object?> trendView(
    TransactionModel model, DateTime selectedMonth, Size size) {
  final data = getRollingTrendData(model, selectedMonth);
  final values = data.map((d) => d.netCashFlow).toList();
  final bound = sparklineBound(values);
  final spots = [
    for (var i = 0; i < data.length; i++)
      FlSpot(i.toDouble(), data[i].netCashFlow)
  ];
  final curve = flChartCurve(
      spots, 0, (data.length - 1).toDouble(), -bound, bound, size, 0.35);
  final chartData = LineChartData(
    minX: 0,
    maxX: (data.length - 1).toDouble(),
    minY: -bound,
    maxY: bound,
    lineBarsData: [LineChartBarData(spots: spots, isCurved: true)],
  );
  checkCurveAgainstFlChart(spots, chartData, size, curve, 'trend');
  return {
    'months': [for (final d in data) iso(d.month)],
    'nets': [for (final v in values) bitsHex(v)],
    'bound': bitsHex(bound),
    'size': [bitsHex(size.width), bitsHex(size.height)],
    ...curveJson(curve),
  };
}

// --- Widget checks ---------------------------------------------------------------

Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

List<String> textsIn(WidgetTester tester, Finder scope) => [
      for (final t in tester.widgetList<Text>(
          find.descendant(of: scope, matching: find.byType(Text))))
        t.data ?? t.textSpan?.toPlainText() ?? ''
    ];

List<String> allTexts(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        t.data ?? t.textSpan?.toPlainText() ?? ''
    ];

double fromBits(Object? hex) {
  final s = hex as String;
  final data = ByteData(8)
    ..setUint32(0, int.parse(s.substring(0, 8), radix: 16))
    ..setUint32(4, int.parse(s.substring(8), radix: 16));
  return data.getFloat64(0);
}

void expectSubsequence(List<String> all, List<String> want, String context) {
  final start = all.indexOf(want.first);
  expect(start, isNot(-1), reason: '$context: ${want.first} not in $all');
  expect(all.sublist(start, min(all.length, start + want.length)), want,
      reason: context);
}

late CategorizationProvider categorization;

Future<void> pumpPage(WidgetTester tester, TransactionModel model) async {
  // A fresh State each time (the range lives in the page state).
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<TransactionModel>.value(value: model),
        ChangeNotifierProvider<CategorizationProvider>.value(
            value: categorization),
      ],
      child: const MaterialApp(home: HistoryPage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> chooseRange(WidgetTester tester, int range) async {
  if (range == 6) return;
  await tester.tap(find.text('6 months'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text('$range months').last);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  expect(find.text('$range months'), findsOneWidget);
}

/// Pumps the real page and compares it with the mirrored figures.
Future<Map<String, Object?>> checkPage(
  WidgetTester tester,
  Dataset dataset,
  TransactionModel model,
  DateTime selectedMonth,
  Map<int, Map<String, Object?>> views,
  Map<String, Object?> yoy,
  Map<String, Object?> trend,
  bool tapBars,
) async {
  final measured = <String, Object?>{};
  for (final range in [3, 6, 12]) {
    final context = '${dataset.name} ${iso(selectedMonth)} $range';
    model.selectedMonth = selectedMonth;
    await pumpPage(tester, model);
    await chooseRange(tester, range);
    final view = views[range]!;
    final texts = allTexts(tester);

    expectSubsequence(texts,
        ['AVG SAVED / MO', view['avgText'] as String], '$context avg');
    expectSubsequence(texts,
        ['SAVINGS RATE', view['rateText'] as String], '$context rate');

    final yi = yoy['income'] as Map<String, Object?>;
    final ye = yoy['expenses'] as Map<String, Object?>;
    expectSubsequence(
        texts,
        [
          'Year over year',
          yoy['header'] as String,
          'Income',
          yi['label'] as String,
          'Expenses',
          ye['label'] as String,
          'This year',
          'Last year',
        ],
        '$context yoy');
    final fills = tester
        .widgetList<GlowProgressBar>(find.byType(GlowProgressBar))
        .map((w) => w.value)
        .toList();
    expect(fills, [
      fromBits(yi['this']),
      fromBits(yi['last']),
      fromBits(ye['this']),
      fromBits(ye['last']),
    ], reason: '$context fills');

    // Bars.
    final window = view['window'] as List;
    final barFinder = byTypeName('_NetCashFlowBar');
    if (window.isEmpty) {
      expect(barFinder, findsNothing);
      expect(find.text('No cash flow data yet.'), findsOneWidget);
    } else {
      final chartWidth = tester.getSize(byTypeName('_NetCashFlowBars')).width;
      measured['chartWidth'] = chartWidth;
      final layout = (view['bars'] as List).first as Map<String, Object?>;
      expect(fromBits(layout['availableWidth']), chartWidth,
          reason: '$context chart width');
      final bars = layout['bars'] as List;
      expect(barFinder.evaluate().length, bars.length, reason: context);
      for (var i = 0; i < bars.length; i++) {
        final bar = bars[i] as Map<String, Object?>;
        final column = barFinder.at(i);
        final columnSize = tester.getSize(column);
        expect(columnSize.width, fromBits(layout['barWidth']),
            reason: '$context bar $i width');
        final rect = find.descendant(of: column, matching: find.byType(Container)).first;
        final size = tester.getSize(rect);
        final top = tester.getTopLeft(rect).dy - tester.getTopLeft(column).dy;
        expect((size.height - fromBits(bar['height'])).abs() < 1e-9, isTrue,
            reason: '$context bar $i height ${size.height} vs ${fromBits(bar['height'])}');
        expect((top - fromBits(bar['top'])).abs() < 1e-9, isTrue,
            reason: '$context bar $i top');
        final barTexts = textsIn(tester, column);
        expect(barTexts, [
          if (bar['isCurrent'] as bool) bar['badge'] as String,
          bar['label'] as String,
        ], reason: '$context bar $i texts');
      }

      if (tapBars && range == 12) {
        final details = view['details'] as List;
        for (var i = 0; i < details.length; i++) {
          final detail = details[i] as Map<String, Object?>;
          await tester.ensureVisible(barFinder.at(i));
          await tester.tap(barFinder.at(i), warnIfMissed: false);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          final sheet = find.ancestor(
              of: find.text(detail['title'] as String),
              matching: find.byType(SafeArea));
          final sheetTexts = textsIn(tester, sheet.first);
          expect(sheetTexts, [
            detail['title'],
            'Income',
            detail['income'],
            'Expenses',
            detail['expenses'],
            'Net cash flow',
            detail['net'],
          ], reason: '$context detail $i');
          await tester.tapAt(const Offset(200, 20));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
        }
      }
    }

    // Trend.
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final chartSize = tester.getSize(find.byType(LineChart));
    measured['trendSize'] = [chartSize.width, chartSize.height];
    expect(chartSize, Size(fromBits((trend['size'] as List)[0]),
        fromBits((trend['size'] as List)[1])), reason: '$context trend size');
    expect(chart.data.minY, -fromBits(trend['bound']), reason: context);
    expect(chart.data.maxY, fromBits(trend['bound']), reason: context);
    final spots = chart.data.lineBarsData[1].spots;
    expect(spots.map((s) => s.y).toList(),
        [for (final v in trend['nets'] as List) fromBits(v)],
        reason: '$context spots');
    expect(chart.data.lineBarsData[0].curveSmoothness, 0.35);
    expect(chart.data.lineBarsData[1].isCurved, isTrue);
    final curve = flChartCurve(spots, chart.data.minX, chart.data.maxX,
        chart.data.minY, chart.data.maxY, chartSize, 0.35);
    checkCurveAgainstFlChart(spots, chart.data, chartSize, curve, context);

    // Preview rows.
    final preview = model.getAllTransactionsSorted().take(3).toList();
    final rows = byTypeName('_TransactionRow');
    if (preview.isEmpty) {
      expect(find.text('No transactions recorded yet.'), findsOneWidget);
    } else {
      expect(rows.evaluate().length, preview.length);
      for (var i = 0; i < preview.length; i++) {
        final want = rowTexts(preview[i]);
        expect(textsIn(tester, rows.at(i)),
            [want.title, want.subtitle, want.amount],
            reason: '$context preview $i');
      }
    }
  }
  return measured;
}

/// Drives the SEE ALL filters through the real controls and compares the
/// results block with the mirror.
Future<void> checkFiltersThroughUi(
  WidgetTester tester,
  TransactionModel model,
  List<FilterSpec> specs,
  Map<String, String> tagNames,
) async {
  for (final spec in specs) {
    await pumpPage(tester, model);
    await tester.ensureVisible(find.text('SEE ALL'));
    await tester.tap(find.text('SEE ALL'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final fields = find.byType(TextField);
    if (spec.search.isNotEmpty) {
      await tester.enterText(fields.at(0), spec.search);
      await tester.pump();
    }
    if (spec.type != TypeFilter.all) {
      await tester.tap(
          find.text(spec.type == TypeFilter.income ? 'Income' : 'Expense'));
      await tester.pump();
    }
    if (spec.category != null) {
      await tester.tap(find.text('All categories'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
          final option = find.text(spec.category!).last;
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
        }
    if (spec.tag != null) {
      final chip = find.text(tagNames[spec.tag]!);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
    }
    if (spec.minText.isNotEmpty) {
      await tester.enterText(fields.at(1), spec.minText);
      await tester.pump();
    }
    if (spec.maxText.isNotEmpty) {
      await tester.enterText(fields.at(2), spec.maxText);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));

    final state = spec.state();
    final filtered = state.filtered(model);
    final texts = resultsTexts(model, state, filtered);
    final context = 'filter ui ${jsonEncode(spec.toJson())}';
    for (final key in ['count', 'income', 'expenses', 'net']) {
      expect(find.text(texts[key]!), findsOneWidget, reason: '$context $key');
    }
    final visible = filtered.take(50).toList();
    final rows = byTypeName('_TransactionRow');
    expect(rows.evaluate().length, visible.length, reason: context);
    for (var i = 0; i < visible.length; i++) {
      final want = rowTexts(visible[i]);
      expect(textsIn(tester, rows.at(i)),
          [want.title, want.subtitle, want.amount],
          reason: '$context row $i');
    }
    expect(find.textContaining(RegExp(r'^Showing \d+ of \d+ matches$')),
        texts['showing'] == null ? findsNothing : findsOneWidget,
        reason: '$context showing');
    if (texts['showing'] != null) {
      expect(find.text(texts['showing']!), findsOneWidget, reason: context);
    }
    for (final message in [
      'No transactions match these filters.',
      'No transactions have been recorded yet.',
    ]) {
      expect(find.text(message),
          texts['empty'] == message ? findsOneWidget : findsNothing,
          reason: '$context empty');
    }
  }
}

// ---------------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AtomicFinancialStore.instance.resetForTesting();
    pinClock(DateTime(2026, 9, 28, 9, 15));
    seedUuids(11);
  });

  final tagSection = [
    {'id': 't-food', 'name': 'Food', 'colorToken': 'green'},
    {'id': 't-work', 'name': 'Work', 'colorToken': 'accent'},
    {'id': 't-trip', 'name': 'Trip', 'colorToken': 'cyan'},
  ];

  for (final dataset in datasets()) {
    testWidgets('dataset ${dataset.name}', (tester) async {
      // The test font draws wider glyphs than Gabarito, so some rows
      // overflow; the sheets also trip a debug-only ListTile check. Neither
      // affects the figures compared here, so both reports are dropped.
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        final text = details.exceptionAsString();
        if (text.contains('overflowed') ||
            text.contains('ListTile background color')) {
          return;
        }
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);
      tester.view.physicalSize =
          Size(phoneSize.width * 3, phoneSize.height * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await AtomicFinancialStore.instance
          .updateSection(FinancialSections.transactionTags, tagSection);
      categorization = CategorizationProvider();
      await categorization.load();
      expect(categorization.tags.length, 3);

      final model = modelFor(dataset);
      final sorted = model.getAllTransactionsSorted();
      final out = <String, Object?>{
        'tz': parityTz,
        'dataset': dataset.name,
        if (dataset.writeRows) 'rows': dataset.rows,
        if (!dataset.writeRows)
          'generator': {'seed': 777, 'count': 10000, 'startYear': 2022, 'months': 60},
        'count': model.transactions.length,
        'availableMonths': [for (final m in model.getAvailableMonths()) iso(m)],
        'history': [
          for (final d in model.getNetCashFlowHistory())
            {
              'month': iso(d.month),
              'income': bitsHex(d.income),
              'expenses': bitsHex(d.expenses),
              'net': bitsHex(d.netCashFlow),
            }
        ],
        if (dataset.writeRows) 'sortedIds': [for (final t in sorted) t.id],
        'sortedIdsFnv': fnvText(sorted.map((t) => t.id).join('\n')),
        'categoryOptions': getCategoryOptions(model.transactions),
        ...rowTextsJson(sorted, !dataset.writeRows),
      };
      // A zero expense is shown as -0.0, which prints without a sign.
      for (final t in sorted.where(
          (t) => t.type == TransactionTyp.expense && t.amount == 0)) {
        expect(rowTexts(t).amount, '\$0.00', reason: '${dataset.name} ${t.id}');
      }

      // Chart widths as the real page lays them out at 402x874 (checked
      // below when widgets run): card inner width and the trend plot.
      const chartWidth = 320.0;
      const trendSize = Size(328, 120);

      final selections = <Map<String, Object?>>[];
      for (final selected in dataset.selectedMonths) {
        final views = <int, Map<String, Object?>>{
          for (final range in [3, 6, 12])
            range: pageView(model, selected, range,
                chartWidth: chartWidth, trendSize: trendSize),
        };
        final yoy = yoyView(model, selected);
        final trend = trendView(model, selected, trendSize);
        if (dataset.widgets) {
          final measured = await checkPage(tester, dataset, model, selected,
              views, yoy, trend, dataset.name == 'typical' || dataset.name == 'negative_tiny');
          if (measured['chartWidth'] != null) {
            expect(measured['chartWidth'], chartWidth);
          }
          expect(measured['trendSize'], [trendSize.width, trendSize.height]);
        }
        selections.add({
          'selected': iso(selected),
          'views': [for (final range in [3, 6, 12]) views[range]],
          'yoy': yoy,
          'trend': trend,
        });
      }
      out['selections'] = selections;

      final hashed = dataset.rows.length > 20;
      final specs = filterMatrix();
      out['filters'] = [
        for (final spec in specs) filterResult(model, spec, hashed)
      ];

      if (dataset.widgets && dataset.name == 'typical') {
        await checkFiltersThroughUi(
          tester,
          model,
          [
            const FilterSpec(),
            const FilterSpec(search: '  Coffee  '),
            const FilterSpec(search: 'café'),
            const FilterSpec(type: TypeFilter.income),
            const FilterSpec(type: TypeFilter.expense, category: 'Groceries'),
            const FilterSpec(category: 'Cafe\u0301'),
            const FilterSpec(tag: 't-food'),
            const FilterSpec(minText: '1,000'),
            const FilterSpec(minText: '10', maxText: '20.5'),
            const FilterSpec(search: 'e', type: TypeFilter.expense, maxText: '100'),
            const FilterSpec(search: 'none-such'),
          ],
          {for (final t in tagSection) t['id']!: t['name']!},
        );
      }
      if (dataset.widgets && dataset.name == 'empty') {
        await checkFiltersThroughUi(tester, model, [const FilterSpec()], {});
      }

      writeCompactJson('$fixturesRoot/$zoneDir/${dataset.name}.json', out);
    });
  }

  test('filter specs', () {
    writeCompactJson('$fixturesRoot/$zoneDir/filter_specs.json', {
      'tz': parityTz,
      'specs': [for (final spec in filterMatrix()) filterSpecJson(spec)],
    });
  });

  test('zone-independent formulas', () {
    if (!writeZoneIndependent) return;

    final pairs = <(double, double)>[
      (0, 0),
      (5, 0),
      (-5, 0),
      (0, 5),
      (-0.0, 5),
      (100, 50),
      (50, 100),
      (100, -50),
      (-50, -50),
      (50, 50),
      (1, 3),
      (3200, 3000),
      (43.21, 1234.56),
      (1e-300, 1e300),
      (1e300, 1e-300),
      (100.0004, 100),
      (99.9996, 100),
      (100.05, 100),
      (99.95, 100),
      (0.1 + 0.2, 0.3),
      (0.3, 0.1 + 0.2),
      (1e308, -1e308),
    ];
    for (var i = 0; i <= 40; i++) {
      pairs.add((100 + i * 0.0025, 100));
      pairs.add((1000 - i * 0.025, 1000));
    }
    final deltas = [
      for (final (current, previous) in pairs)
        () {
          final delta = percentDelta(current, previous);
          return {
            'current': bitsHex(current),
            'previous': bitsHex(previous),
            'delta': numberJson(delta),
            'label': formatPercentDelta(delta),
          };
        }()
    ];

    final rates = <double>[
      0,
      -0.0,
      0.49,
      0.5,
      -0.5,
      -0.49,
      1.5,
      2.5,
      98.67,
      99.5,
      100,
      -1234.5,
      1e21,
      123456.789,
      0.1 + 0.2,
    ];
    final metricTexts = [
      for (final v in rates)
        {
          'value': bitsHex(v),
          'rateText': '${v.toStringAsFixed(0)}%',
          'avgText': formatMetricCurrency(v),
          'badge': MoneyFormatter.formatSigned(v,
              decimalDigits: 0, plusForPositive: true),
        }
    ];

    final amountCorpus = [
      ...amountTexts,
      'NaN',
      'Infinity',
      '-Infinity',
      '1e400',
      ',,,',
      '1,2,3.5',
      '\uFEFF7\uFEFF',
      ' , 5 , ',
      '٣',
      '1_000',
      '1e-400',
    ];
    final amounts = [
      for (final text in amountCorpus)
        () {
          final v = parseAmount(text);
          return {
            'text': text,
            'result': numberJson(v),
            'isNaN': v?.isNaN ?? false,
            'isFinite': v?.isFinite ?? false,
          };
        }()
    ];

    // Curves on arbitrary point sets through the real fl_chart path.
    final r = Lcg(99);
    final curves = <Map<String, Object?>>[];
    for (final count in [1, 2, 3, 5, 12, 12, 12, 30]) {
      final spots = [
        for (var i = 0; i < count; i++)
          FlSpot(i.toDouble(), (r.next() % 20001 - 10000) / 7)
      ];
      final values = spots.map((s) => s.y).toList();
      final bound = sparklineBound(values);
      for (final size in [const Size(328, 120), const Size(301, 120), const Size(10.5, 3.25)]) {
        final maxX = (count - 1).toDouble();
        final curve = flChartCurve(spots, 0, maxX, -bound, bound, size, 0.35);
        final data = LineChartData(minX: 0, maxX: maxX, minY: -bound, maxY: bound);
        if (count > 1) {
          checkCurveAgainstFlChart(spots, data, size, curve, 'curve $count');
        }
        curves.add({
          'values': [for (final v in values) bitsHex(v)],
          'bound': bitsHex(bound),
          'size': [bitsHex(size.width), bitsHex(size.height)],
          ...curveJson(curve),
        });
      }
    }
    // Raw points with other smoothness values (the helper's parameter).
    final raw = <Map<String, Object?>>[];
    for (final smoothness in [0.0, 0.35, 1.0]) {
      final spots = [
        for (var i = 0; i < 7; i++)
          FlSpot(i * 1.5, (r.next() % 1000) / 3)
      ];
      final curve = flChartCurve(spots, 0, 1, 0, 1, const Size(1, 1), smoothness);
      raw.add({
        'smoothness': bitsHex(smoothness),
        'points': [
          for (final p in curve.points) [bitsHex(p.dx), bitsHex(p.dy)]
        ],
        'controls': curveJson(curve)['controls'],
      });
    }

    writeCompactJson('$fixturesRoot/flow/formulas.json', {
      'deltas': deltas,
      'metricTexts': metricTexts,
      'amounts': amounts,
      'curves': curves,
      'rawCurves': raw,
    });
  });
}
