// Emits native/Fixtures/voice/ : outputs of the real
// VoiceExpenseService.parseVoiceJson (lib/voice_expense_service.dart) over a
// corpus of raw model replies.
//
// Per zone (voice/tz/<zone>/parse.json), one case per line:
//   header: commit, tz, expense / income (the built-in category names, in
//   order: the lists passed in unless a case carries its own)
//   case: name, raw (the model output), transcript, todayUs (the pinned
//   `today`, as microseconds since epoch, local), todayIso, and result:
//     {type, description, amountBits (IEEE hex), amount (text), category,
//      dateUs, dateUtc, dateIso}
//   or {error: unreadable | notATransaction, transcript}
//   or {threw: <type>} for anything else (the Swift side expects none).
//
// Dates whose meaning depends on the zone (DST gaps and overlaps at
// midnight, the 90-day boundary, "Z" and offset strings) are generated
// relative to each pinned `today`, so every zone sees its own boundaries.

import 'dart:convert';
import 'dart:io';

import 'package:budget_app/common.dart';
import 'package:budget_app/transaction.dart';
import 'package:budget_app/voice_expense_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness_support.dart';

String two(int v) => v.toString().padLeft(2, '0');
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';

final List<String> builtinExpense = expenseCategories.keys.toList();
final List<String> builtinIncome = incomeCategories.keys.toList();

final cases = <Map<String, Object?>>[];

/// Runs the real parser on [raw] and records the outcome.
void record(
  String name,
  String raw, {
  String transcript = 'coffee for four dollars',
  required DateTime today,
  List<String>? expense,
  List<String>? income,
}) {
  Map<String, Object?> result;
  try {
    final txn = VoiceExpenseService.parseVoiceJson(raw, transcript, today);
    result = {
      'type': txn.type == TransactionTyp.income ? 'income' : 'expense',
      'description': txn.description,
      'amountBits': bitsHex(txn.amount),
      'amount': txn.amount.toString(),
      'category': txn.category,
      'dateUs': txn.date.microsecondsSinceEpoch,
      'dateUtc': txn.date.isUtc,
      'dateIso': txn.date.toIso8601String(),
    };
  } on VoiceExpenseException catch (e) {
    result = {
      'error': e.message.startsWith("Couldn't read")
          ? 'unreadable'
          : e.message.startsWith("That didn't sound")
              ? 'notATransaction'
              : 'other:${e.message}',
      'transcript': e.transcript,
    };
  } catch (e) {
    result = {'threw': e.runtimeType.toString()};
  }
  cases.add({
    'name': name,
    'raw': raw,
    'transcript': transcript,
    'todayUs': today.microsecondsSinceEpoch,
    'todayIso': today.toIso8601String(),
    if (expense != null) 'expense': expense,
    if (income != null) 'income': income,
    'result': result,
  });
}

String obj(Map<String, Object?> fields) => jsonEncode(fields);

/// A model reply with every field present and valid, then one changed.
Map<String, Object?> base([Map<String, Object?> override = const {}]) => {
      'type': 'expense',
      'description': 'Chipotle',
      'amount': 12.5,
      'category': 'Eating Out',
      'date': '2026-07-06',
      ...override,
    };

/// Everything that does not depend on the zone or on which `today` is used.
void staticCorpus(DateTime today) {
  void rec(String name, String raw, {String? transcript}) => record(
        name,
        raw,
        today: today,
        transcript: transcript ?? 'coffee for four dollars',
      );

  // --- Roots that are not objects, and malformed text.
  for (final (name, raw) in [
    ('empty string', ''),
    ('spaces only', '   \n\t '),
    ('empty array', '[]'),
    ('array of numbers', '[1, 2, 3]'),
    ('array holding the object', '[${obj(base())}]'),
    ('null', 'null'),
    ('true', 'true'),
    ('number', '42'),
    ('string', '"just a string"'),
    ('string holding json', jsonEncode(obj(base()))),
    ('unterminated object', '{ this is not valid json'),
    ('unterminated valid start', '{"type": "expense"'),
    ('trailing comma', '{"type": "expense",}'),
    ('single quotes', "{'type': 'expense'}"),
    ('unquoted key', '{type: "expense"}'),
    ('NaN literal', '{"amount": NaN}'),
    ('Infinity literal', '{"amount": Infinity}'),
    ('leading zero number', '{"amount": 012}'),
    ('plus sign number', '{"amount": +5}'),
    ('bare dot number', '{"amount": .5}'),
    ('trailing dot number', '{"amount": 5.}'),
    ('comment', '{"amount": 5 /* x */}'),
    ('two objects', '{}{}'),
    ('object then text', '${obj(base())} thanks'),
    ('text then object', 'Sure! ${obj(base())}'),
    ('control char in string', '{"description": "a\tb"}'),
    ('bad escape', '{"description": "a\\qb"}'),
    ('bad unicode escape', '{"description": "\\u12"}'),
    ('empty object', '{}'),
    ('empty object spaced', '  {  }  '),
    ('BOM before object', '﻿${obj(base())}'),
    ('NBSP around object', ' ${obj(base())} '),
    ('LS around object', ' ${obj(base())} '),
    ('zero width space before object', '​${obj(base())}'),
    ('NEL before object', '\u0085${obj(base())}'),
    ('CRLF around object', '\r\n${obj(base())}\r\n'),
    ('vertical tab before object', '\u000B${obj(base())}'),
    ('form feed before object', '\u000C${obj(base())}'),
    ('deeply nested ignored key',
        '{"x": ${'[' * 100}${']' * 100}, "amount": 3}'),
    ('duplicate type keys last wins',
        '{"type": "income", "type": "expense", "amount": 1}'),
    ('duplicate type keys last income',
        '{"type": "expense", "type": "income", "amount": 1}'),
    ('duplicate amount keys', '{"amount": 5, "amount": "9"}'),
    ('escaped key names', '{"\\u0074ype": "income", "amount": 2}'),
  ]) {
    rec(name, raw);
  }

  // --- The error key.
  for (final (name, raw) in [
    ('error string', obj({'error': 'not_a_transaction'})),
    ('error null', '{"error": null}'),
    ('error false', '{"error": false}'),
    ('error empty string', '{"error": ""}'),
    ('error alongside a full transaction', obj(base({'error': 'x'}))),
    ('error alongside income', obj(base({'type': 'income', 'error': 1}))),
    ('Error capitalised is not the error key', obj(base({'Error': 'x'}))),
    ('error with space is not the error key', obj(base({'error ': 'x'}))),
    ('nested error is not the error key',
        obj(base({'meta': {'error': 'x'}}))),
    ('error key escaped', '{"\\u0065rror": "x"}'),
  ]) {
    rec(name, raw);
  }

  // --- Fences.
  final body = obj(base());
  for (final (name, raw) in [
    ('plain fence', '```\n$body\n```'),
    ('json fence', '```json\n$body\n```'),
    ('JSON upper fence', '```JSON\n$body\n```'),
    ('language with digit', '```json5\n$body\n```'),
    ('language with dash', '```json-x\n$body\n```'),
    ('fence without newline', '```json $body ```'),
    ('fence body on the same line', '```$body```'),
    ('fence language glued to body', '```json$body```'),
    ('fence CRLF', '```json\r\n$body\r\n```'),
    ('fence blank lines', '```json\n\n\n$body\n\n\n```'),
    ('fence with outer whitespace', '  \n```json\n$body\n```  \n'),
    ('fence no closing', '```json\n$body'),
    ('closing fence only', '$body\n```'),
    ('text after closing fence', '```json\n$body\n``` thanks'),
    ('text before opening fence', 'Here:\n```json\n$body\n```'),
    ('two backticks', '``json\n$body\n``'),
    ('four backticks', '````json\n$body\n````'),
    ('six backticks', '``````'),
    ('three backticks only', '```'),
    ('fence and language only', '```json'),
    ('fence, language, newline only', '```json\n'),
    ('empty fenced block', '```\n```'),
    ('fence with two closings', '```json\n$body\n``````'),
    ('closing fence with trailing spaces', '```json\n$body\n```   '),
    ('fence with a space before the newline', '```json \n$body\n```'),
    ('fence of an array', '```json\n[1]\n```'),
    ('fence of an error', '```json\n{"error": "x"}\n```'),
    ('fenced scalar', '```\n42\n```'),
    ('fence with non-ASCII language', '```jsön\n$body\n```'),
    ('fence, BOM inside', '```json\n﻿$body\n```'),
    ('fence then NBSP body', '```json\n $body \n```'),
  ]) {
    rec(name, raw);
  }

  // --- Type.
  for (final (name, type) in <(String, Object?)>[
    ('income', 'income'),
    ('expense', 'expense'),
    ('Income capital', 'Income'),
    ('INCOME', 'INCOME'),
    ('income leading space', ' income'),
    ('income trailing space', 'income '),
    ('income newline', 'income\n'),
    ('income with NUL', 'income\u0000'),
    ('empty type', ''),
    ('garbage type', 'refund-or-something'),
    ('type number', 42),
    ('type true', true),
    ('type array of income', ['income']),
    ('type object', {'income': true}),
    ('type null', null),
  ]) {
    final fields = base({'category': 'Salary', 'type': type});
    rec('type $name', obj(fields));
  }
  rec('type missing', obj(base()..remove('type')));
  rec('type missing, income category',
      obj(base({'category': 'Investment'})..remove('type')));

  // --- Category: every built-in name under each type, then near-misses.
  for (final type in ['expense', 'income']) {
    for (final name in {...builtinExpense, ...builtinIncome}) {
      rec('category $type $name',
          obj(base({'type': type, 'category': name})));
    }
  }
  for (final (name, category) in <(String, Object?)>[
    ('lowercase', 'eating out'),
    ('uppercase', 'EATING OUT'),
    ('trailing space', 'Eating Out '),
    ('leading space', ' Eating Out'),
    ('double space', 'Eating  Out'),
    ('NBSP', 'Eating Out'),
    ('newline', 'Eating Out\n'),
    ('no space', 'EatingOut'),
    ('hyphen', 'Eating-Out'),
    ('zero width joiner', 'Eating‍Out'),
    ('BOM suffix', 'General﻿'),
    ('plural', 'Groceriess'),
    ('prefix', 'Grocer'),
    ('empty', ''),
    ('null', null),
    ('number', 5),
    ('list', ['Groceries']),
    ('map', {'Groceries': 1}),
    ('true', true),
    ('cyrillic lookalike', 'Gеneral'),
    ('full width', 'Ｇeneral'),
    ('literal backslash-u', 'Eating\\u0020Out'),
    ('emoji', '🍕'),
    ('other income name under expense', 'Salary'),
    ('Other under expense', 'Other'),
  ]) {
    for (final type in ['expense', 'income']) {
      rec('category near-miss $name ($type)',
          obj(base({'type': type, 'category': category})));
    }
  }
  // A JSON-escaped spelling of an exact name is the same string.
  rec('category via unicode escape',
      '{"type":"expense","category":"Eating \\u004fut","amount":1}');
  rec('category missing expense', obj(base()..remove('category')));
  rec('category missing income',
      obj(base({'type': 'income'})..remove('category')));

  // --- Amount.
  for (final (name, amount) in <(String, String)>[
    ('int', '3000'),
    ('zero', '0'),
    ('negative zero int', '-0'),
    ('negative zero double', '-0.0'),
    ('zero double', '0.0'),
    ('double', '12.5'),
    ('long fraction', '0.1'),
    ('another long fraction', '0.30000000000000004'),
    ('cents', '4.99'),
    ('negative int', '-5'),
    ('negative double', '-0.01'),
    ('exponent', '1e3'),
    ('exponent upper', '1E3'),
    ('exponent plus', '1e+3'),
    ('exponent minus', '1.5e-3'),
    ('exponent fraction', '2.5E2'),
    ('negative exponent value', '-1e3'),
    ('huge exponent', '1e400'),
    ('negative huge exponent', '-1e400'),
    ('tiny exponent', '1e-400'),
    ('negative tiny exponent', '-1e-400'),
    ('near max double', '1.7976931348623157e308'),
    ('just over max double', '1.7976931348623159e308'),
    ('min subnormal', '5e-324'),
    ('below min subnormal', '2e-324'),
    ('int max', '9223372036854775807'),
    ('int max plus one', '9223372036854775808'),
    ('int min', '-9223372036854775808'),
    ('int min minus one', '-9223372036854775809'),
    ('2^53 plus 1', '9007199254740993'),
    ('2^53 plus 3', '9007199254740995'),
    ('huge int', '123456789012345678901234567890'),
    ('very huge int', '1${'0' * 400}'),
    ('negative huge int', '-123456789012345678901234567890'),
    ('many digit fraction', '3.141592653589793238462643383279'),
    ('fraction rounding tie', '0.5000000000000001'),
    ('9.995', '9.995'),
    ('1.005', '1.005'),
  ]) {
    rec('amount number $name', '{"amount": $amount}');
  }
  for (final (name, amount) in <(String, Object?)>[
    ('string plain', '12.50'),
    ('string int', '12'),
    ('string with spaces', ' 12.5 '),
    ('string with tab newline', '\t12.5\n'),
    ('string NBSP', ' 12.5 '),
    ('string BOM', '﻿12.5'),
    ('string leading plus', '+12.5'),
    ('string negative', '-12.5'),
    ('string negative zero', '-0'),
    ('string negative zero double', '-0.0'),
    ('string zero', '0'),
    ('string dollar', '\$12.50'),
    ('string thousands comma', '1,200'),
    ('string decimal comma', '12,50'),
    ('string thousands and decimal', '1,200.50'),
    ('string underscore', '1_000'),
    ('string exponent', '1e3'),
    ('string exponent upper', '1E3'),
    ('string exponent bare', '1e'),
    ('string exponent sign only', '1e+'),
    ('string leading dot', '.5'),
    ('string trailing dot', '5.'),
    ('string dot only', '.'),
    ('string double dot', '1.2.3'),
    ('string NaN', 'NaN'),
    ('string nan lowercase', 'nan'),
    ('string Infinity', 'Infinity'),
    ('string negative Infinity', '-Infinity'),
    ('string inf', 'inf'),
    ('string hex', '0x10'),
    ('string hex float', '0x1p3'),
    ('string octal look', '010'),
    ('string leading zeros', '007.50'),
    ('string huge', '1e400'),
    ('string tiny negative', '-1e-400'),
    ('string huge int', '123456789012345678901234567890'),
    ('string empty', ''),
    ('string blank', '   '),
    ('string words', 'a lot'),
    ('string number word', 'twelve'),
    ('string with unit', '12.5 dollars'),
    ('string arabic indic digits', '١٢'),
    ('string full width digits', '１２'),
    ('string inner space', '12 5'),
    ('string sign space', '- 5'),
    ('string double sign', '--5'),
    ('string plus minus', '+-5'),
    ('bool true', true),
    ('bool false', false),
    ('null', null),
    ('list', [12]),
    ('map', {'v': 12}),
  ]) {
    rec('amount $name', obj({'amount': amount, 'category': 'Groceries'}));
  }
  rec('amount missing', obj(base()..remove('amount')));

  // --- Description (trim set: White_Space plus U+FEFF).
  for (final (name, description) in <(String, Object?)>[
    ('padded', '  Chipotle  '),
    ('tabs newlines', '\t\nChipotle\r\n'),
    ('inner spaces kept', '  Blue   Bottle  '),
    ('empty', ''),
    ('spaces', '   '),
    ('tab newline', '\t\n'),
    ('only BOM', '﻿'),
    ('BOM padded', '﻿Chipotle﻿'),
    ('only NBSP', ' '),
    ('NBSP padded', ' Chipotle '),
    ('NEL', '\u0085Chipotle\u0085'),
    ('only NEL', '\u0085'),
    ('LS PS', ' Chipotle '),
    ('em space', ' Chipotle '),
    ('thin and hair space', '  Chipotle'),
    ('narrow no-break space', ' Chipotle '),
    ('medium math space', ' Chipotle'),
    ('ideographic space', '　Chipotle　'),
    ('ogham space', ' Chipotle '),
    ('mongolian vowel separator', '᠎Chipotle᠎'),
    ('only mongolian vowel separator', '᠎'),
    ('zero width space kept', '​Chipotle​'),
    ('only zero width space', '​'),
    ('zero width no-break kept', '⁠x⁠'),
    ('line tab', '\u000BChipotle\u000C'),
    ('file separator', '\u001CChipotle\u001F'),
    ('only file separator', '\u001C'),
    ('NUL', '\u0000'),
    ('NUL padded', '\u0000Chipotle\u0000'),
    ('emoji', '😀 lunch 😀'),
    ('emoji padded', '  😀  '),
    ('nfd', '  Café  '),
    ('nfc', '  Café  '),
    ('combining mark alone', '́'),
    ('rtl', '‏مطعم‏'),
    ('long', 'x' * 5000),
    ('number', 123),
    ('true', true),
    ('null', null),
    ('list', ['Chipotle']),
    ('map', {'a': 1}),
    ('escaped newline text', 'a\\nb'),
  ]) {
    rec('description $name', obj(base({'description': description})));
  }
  rec('description missing', obj(base()..remove('description')));
  rec('description with empty transcript fallback',
      obj(base({'description': '  '})),
      transcript: '');
  rec('description fallback keeps transcript untrimmed',
      obj(base({'description': ''})),
      transcript: '  padded transcript  ');
  rec('description fallback nfd transcript',
      obj(base({'description': null})),
      transcript: 'Café and 😀');
  rec('error keeps transcript untrimmed', '{"error": "x"}',
      transcript: '  spaced  ');
  rec('unreadable keeps transcript untrimmed', 'nope',
      transcript: '  spaced  ');
  rec('unreadable with empty transcript', 'nope', transcript: '');

}

/// Fixed date strings, with `today` as the pinned clock.
void fixedDates(DateTime today, {required bool all}) {
  void rec(String name, String raw) => record(
        all ? name : '$name @${today.toIso8601String()}',
        raw,
        today: today,
      );
  for (final (name, date) in <(String, Object?)>[
    ('date-only past', '2026-06-20'),
    ('datetime local', '2026-06-20T14:30:00'),
    ('datetime local ms', '2026-06-20T14:30:00.123'),
    ('datetime local micros', '2026-06-20T14:30:00.123456'),
    ('datetime local 7 fraction digits', '2026-06-20T14:30:00.1234567'),
    ('datetime local 9 fraction digits', '2026-06-20T14:30:00.123456789'),
    ('datetime local 12 fraction digits', '2026-06-20T14:30:00.999999999999'),
    ('datetime with space', '2026-06-20 14:30:00'),
    ('datetime lowercase t', '2026-06-20t14:30:00'),
    ('datetime hour minute only', '2026-06-20T14:30'),
    ('datetime hour only', '2026-06-20T14'),
    ('datetime Z', '2026-06-20T14:30:00Z'),
    ('datetime lowercase z', '2026-06-20T14:30:00z'),
    ('date-only Z', '2026-06-20Z'),
    ('datetime +00:00', '2026-06-20T14:30:00+00:00'),
    ('datetime +02:00', '2026-06-20T14:30:00+02:00'),
    ('datetime -05:00', '2026-06-20T14:30:00-05:00'),
    ('datetime +0530', '2026-06-20T14:30:00+0530'),
    ('datetime +05', '2026-06-20T14:30:00+05'),
    ('datetime +14:00', '2026-06-20T14:30:00+14:00'),
    ('datetime -12:00', '2026-06-20T14:30:00-12:00'),
    ('datetime +99:00', '2026-06-20T14:30:00+99:00'),
    ('datetime Z with fraction', '2026-06-20T14:30:00.500Z'),
    ('basic format date', '20260620'),
    ('basic format datetime', '20260620T143000'),
    ('basic format Z', '20260620T143000Z'),
    ('basic format offset', '20260620T143000+0100'),
    ('mixed basic and extended', '2026-0620'),
    ('year month only', '2026-06'),
    ('year only', '2026'),
    ('one-digit month', '2026-6-20'),
    ('one-digit day', '2026-06-2'),
    ('day 31 in 30-day month', '2026-06-31'),
    ('feb 30', '2026-02-30'),
    ('feb 29 non leap', '2026-02-29'),
    ('feb 29 leap', '2024-02-29'),
    ('month 13', '2026-13-01'),
    ('month 00', '2026-00-10'),
    ('day 00', '2026-06-00'),
    ('day 32', '2026-06-32'),
    ('hour 24', '2026-06-20T24:00:00'),
    ('hour 25', '2026-06-20T25:00:00'),
    ('minute 60', '2026-06-20T14:60:00'),
    ('second 60', '2026-06-20T14:30:60'),
    ('leap second', '2026-06-20T23:59:60'),
    ('signed year plus', '+2026-06-20'),
    ('signed year padded', '+002026-06-20'),
    ('signed year negative', '-000001-06-20'),
    ('five digit year', '12026-06-20'),
    ('two digit year', '26-06-20'),
    ('year 0000', '0000-01-01'),
    ('year 9999', '9999-12-31'),
    ('leading space', ' 2026-06-20'),
    ('trailing space', '2026-06-20 '),
    ('padded newline', '\n2026-06-20\n'),
    ('NBSP padded', ' 2026-06-20'),
    ('BOM padded', '﻿2026-06-20'),
    ('slashes', '2026/06/20'),
    ('dots', '20.06.2026'),
    ('us format', '06/20/2026'),
    ('words', 'June 20 2026'),
    ('yesterday', 'yesterday'),
    ('today word', 'today'),
    ('empty', ''),
    ('spaces', '   '),
    ('garbage', 'not-a-date'),
    ('number as string', '20260620.5'),
    ('epoch seconds', '1781000000'),
    ('non-ascii digits', '２０２６-０６-２０'),
    ('date then junk', '2026-06-20 junk'),
    ('T without time', '2026-06-20T'),
    ('offset without time', '2026-06-20+02:00'),
    ('double Z', '2026-06-20T14:30:00ZZ'),
    ('int', 20260620),
    ('double', 20260620.5),
    ('bool', true),
    ('null', null),
    ('list', ['2026-06-20']),
    ('map', {'date': '2026-06-20'}),
    ('future far', '2030-01-01'),
    ('past far', '1985-06-01'),
    ('a year ago', '2025-07-07'),
    ('last year same month', '2025-09-12'),
    ('epoch', '1970-01-01T00:00:00Z'),
    ('year 275760 max', '+275760-09-13T00:00:00.000Z'),
    ('year past max', '+275761-01-01'),
    ('year min', '-271821-04-20T00:00:00.000Z'),
    ('DST spring forward NY', '2026-03-08T02:30:00'),
    ('DST fall back NY first', '2026-11-01T01:30:00'),
    ('DST spring forward Beirut midnight', '2026-03-29T00:30:00'),
    ('DST spring forward Beirut date', '2026-03-29'),
    ('DST fall back Beirut', '2026-10-24T23:30:00'),
    ('DST spring forward Santiago midnight', '2026-09-06T00:30:00'),
    ('DST spring forward Santiago date', '2026-09-06'),
    ('DST fall back Santiago', '2026-04-04T23:30:00'),
    ('DST Lord Howe start', '2026-10-04T02:15:00'),
    ('DST Lord Howe end', '2026-04-05T01:45:00'),
  ]) {
    if (!all && !name.startsWith('DST')) continue;
    rec('date $name', obj(base({'date': date})));
  }
  if (all) rec('date missing', obj(base()..remove('date')));

}

/// Boundaries generated relative to this `today`.
void relativeDates(DateTime today, int index) {
  void rec(String name, String raw) => record(
        '$name @$index',
        raw,
        today: today,
      );
  final earliest = DateTime(today.year, today.month, today.day - 90);
  final tomorrow = DateTime(today.year, today.month, today.day + 1);
  final dayBeforeEarliest =
      DateTime(today.year, today.month, today.day - 91);
  final dayAfterEarliest = DateTime(today.year, today.month, today.day - 89);
  final micro = const Duration(microseconds: 1);
  final relative = <String, String>{
    'today date-only': ymd(today),
    'today exact': today.toIso8601String(),
    'today plus 1us': today.add(micro).toIso8601String(),
    'today minus 1us': today.subtract(micro).toIso8601String(),
    'today plus 1h': today.add(const Duration(hours: 1)).toIso8601String(),
    'today minus 1h': today.subtract(const Duration(hours: 1)).toIso8601String(),
    'tomorrow date-only': ymd(tomorrow),
    'tomorrow exact midnight': tomorrow.toIso8601String(),
    'today end of day': '${ymd(today)}T23:59:59.999999',
    'today start of day': '${ymd(today)}T00:00:00.000000',
    'earliest date-only': ymd(earliest),
    'earliest exact': earliest.toIso8601String(),
    'earliest minus 1us': earliest.subtract(micro).toIso8601String(),
    'earliest plus 1us': earliest.add(micro).toIso8601String(),
    'earliest minus 1h': earliest.subtract(const Duration(hours: 1)).toIso8601String(),
    'earliest plus 1h': earliest.add(const Duration(hours: 1)).toIso8601String(),
    'day before earliest date-only': ymd(dayBeforeEarliest),
    'day before earliest end of day': '${ymd(dayBeforeEarliest)}T23:59:59.999999',
    'day after earliest date-only': ymd(dayAfterEarliest),
    'earliest date 00:00:00 string': '${ymd(earliest)}T00:00:00',
    'earliest date 12:00 string': '${ymd(earliest)}T12:00:00',
    'today Z': today.toUtc().toIso8601String(),
    'today Z plus 1us': today.toUtc().add(micro).toIso8601String(),
    'today Z minus 1us': today.toUtc().subtract(micro).toIso8601String(),
    'today Z plus 12h': today.toUtc().add(const Duration(hours: 12)).toIso8601String(),
    'today Z minus 12h': today.toUtc().subtract(const Duration(hours: 12)).toIso8601String(),
    'today date T12 Z': '${ymd(today)}T12:00:00Z',
    'today date T00 Z': '${ymd(today)}T00:00:00Z',
    'today date T23:59:59 Z': '${ymd(today)}T23:59:59Z',
    'earliest Z': earliest.toUtc().toIso8601String(),
    'earliest Z minus 1us': earliest.toUtc().subtract(micro).toIso8601String(),
    'earliest date T00 Z': '${ymd(earliest)}T00:00:00Z',
    'earliest date T00 Z minus 1s': '${ymd(dayBeforeEarliest)}T23:59:59Z',
    'today +14:00 offset': '${ymd(today)}T12:00:00+14:00',
    'today -12:00 offset': '${ymd(today)}T12:00:00-12:00',
    'earliest date +14:00 offset': '${ymd(earliest)}T00:00:00+14:00',
    'earliest date -12:00 offset': '${ymd(earliest)}T00:00:00-12:00',
    'earliest date +00:00 offset': '${ymd(earliest)}T00:00:00+00:00',
    'earliest date +05:30 offset': '${ymd(earliest)}T00:00:00+05:30',
    'tomorrow date T00 Z': '${ymd(tomorrow)}T00:00:00Z',
    'tomorrow -12:00 offset': '${ymd(tomorrow)}T00:00:00-12:00',
    'tomorrow +14:00 offset': '${ymd(tomorrow)}T00:00:00+14:00',
  };
  relative.forEach((name, date) {
    rec('date rel $name', obj(base({'date': date})));
  });
  // The same boundaries as earliest 91/89 days for the exact-date family.
  for (var back = 89; back <= 91; back++) {
    final d = DateTime(today.year, today.month, today.day - back);
    rec('date back $back days', obj(base({'date': ymd(d)})));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('voice parse.json', () {
    final todays = <DateTime>[
      DateTime(2026, 7, 7, 12, 0, 0), // the Dart unit tests' `today`
      DateTime(2026, 3, 2, 9, 30), // 90 days back underflows into last year
      DateTime(2026, 1, 15), // year boundary, midnight
      DateTime(2024, 3, 1, 8), // leap-year February in range
      DateTime(2026, 12, 31, 23, 59, 59, 999, 999), // last microsecond
      DateTime(2026, 3, 8, 12), // New York spring forward day
      DateTime(2026, 11, 1, 12), // New York fall back day
      DateTime(2026, 3, 29, 0, 30), // Beirut midnight gap (01:30 there)
      DateTime(2026, 10, 25, 0, 30), // Beirut fall back after the repeat
      DateTime(2026, 4, 5, 12), // Lord Howe fall back day
      DateTime(2026, 10, 4, 12), // Lord Howe spring forward day
      DateTime(2026, 6, 6, 12), // earliest = New York spring forward date
      DateTime(2026, 6, 27, 12), // earliest = Beirut nonexistent midnight
      DateTime(2026, 7, 4, 12), // earliest = Santiago fall back date
      DateTime(2026, 12, 5, 12), // earliest = Santiago nonexistent midnight
      DateTime(2026, 9, 6, 0, 30), // Santiago midnight gap for `today`
    ];
    staticCorpus(todays.first);
    fixedDates(todays.first, all: true);
    for (var i = 0; i < todays.length; i++) {
      if (i > 0) fixedDates(todays[i], all: false);
      relativeDates(todays[i], i);
    }

    final today = DateTime(2026, 7, 7, 12);
    // Categories the built-in maps do not have: a custom name in NFC, its NFD
    // spelling, an astral name. `Iterable.contains` is code-unit equality. The
    // parser reads the real maps, so they hold the names while these run.
    final icon = expenseCategories['General']!;
    final savedExpense = Map.of(expenseCategories);
    final savedIncome = Map.of(incomeCategories);
    try {
      for (final name in ['Café', '🍕 Pizza', 'Ünï']) {
        expenseCategories[name] = icon;
      }
      incomeCategories['Côte'] = icon;
      for (final (name, type, category) in <(String, String, String)>[
        ('nfc custom', 'expense', 'Café'),
        ('nfd of custom', 'expense', 'Café'),
        ('astral custom', 'expense', '🍕 Pizza'),
        ('astral custom lowercase', 'expense', '🍕 pizza'),
        ('custom with diaeresis', 'expense', 'Ünï'),
        ('custom decomposed', 'expense', 'Ünï'),
        ('custom income nfc', 'income', 'Côte'),
        ('custom income nfd', 'income', 'Côte'),
        ('custom expense name under income', 'income', 'Café'),
        ('custom income name under expense', 'expense', 'Côte'),
      ]) {
        record(
          'category custom list $name',
          obj(base({'type': type, 'category': category})),
          today: today,
          expense: expenseCategories.keys.toList(),
          income: incomeCategories.keys.toList(),
        );
      }
      // A list without the fallback names: Flutter still falls back to them.
      expenseCategories
        ..clear()
        ..['Groceries'] = icon;
      incomeCategories
        ..clear()
        ..['Salary'] = icon;
      record(
        'category fallback not in list',
        obj(base({'category': 'nope'})),
        today: today,
        expense: ['Groceries'],
        income: ['Salary'],
      );
      record(
        'category fallback not in list (income)',
        obj(base({'type': 'income', 'category': 'nope'})),
        today: today,
        expense: ['Groceries'],
        income: ['Salary'],
      );
      expenseCategories.clear();
      incomeCategories.clear();
      record(
        'category empty lists',
        obj(base({'category': 'Groceries'})),
        today: today,
        expense: [],
        income: [],
      );
    } finally {
      expenseCategories
        ..clear()
        ..addAll(savedExpense);
      incomeCategories
        ..clear()
        ..addAll(savedIncome);
    }

    expect(cases.length, greaterThanOrEqualTo(60));
    expect(cases.where((c) => (c['result'] as Map).containsKey('threw')),
        isEmpty);

    final dir = fixtureDir('voice/tz/${parityTz.replaceAll('/', '_')}');
    final out = StringBuffer()
      ..writeln('{')
      ..writeln('  "commit": ${jsonEncode(parityCommit)},')
      ..writeln('  "tz": ${jsonEncode(parityTz)},')
      ..writeln('  "expense": ${jsonEncode(builtinExpense)},')
      ..writeln('  "income": ${jsonEncode(builtinIncome)},')
      ..writeln('  "cases": [');
    for (var i = 0; i < cases.length; i++) {
      out.writeln('    ${jsonEncode(cases[i])}${i + 1 < cases.length ? ',' : ''}');
    }
    out
      ..writeln('  ]')
      ..writeln('}');
    File('${dir.path}/parse.json').writeAsStringSync(out.toString());
  });
}
