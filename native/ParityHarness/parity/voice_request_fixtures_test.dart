// Emits native/Fixtures/voicerequest/tz/<zone>/request.json : the requests
// the real `VoiceExpenseService` (voice_expense_service.dart, dart_openai)
// sends to OpenAI, in America/New_York and America/Santiago.
//
// Nothing ever reaches api.openai.com. `OpenAI.baseUrl` points at a server
// bound to 127.0.0.1 inside this test, and `HttpOverrides.global` is
// replaced by a client whose `connectionFactory` refuses every host but
// 127.0.0.1 (the test binding's own override would answer 400 to all of
// them), so a request that strays fails the test instead of leaving the
// machine. The service reads its key from `.env` through `rootBundle`; the
// harness stub has a different variable name, so the asset channel answers
// `.env` with a dummy key of the right name for this test only.
//
// Per case: `parse(transcript, today)` records the chat request (path,
// Authorization, Content-Type, the raw body: model, messages with the system
// prompt, response_format) and `transcribe(file)` the multipart request
// (fields and the file part, boundary normalised).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_app/common.dart';
import 'package:budget_app/voice_expense_service.dart';
import 'package:dart_openai/dart_openai.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness_support.dart';

String get zoneDir => 'voicerequest/tz/${parityTz.replaceAll('/', '_')}';

/// Only 127.0.0.1 may be connected to.
class LoopbackOnly extends HttpOverrides {
  final blocked = <String>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != '127.0.0.1') {
        blocked.add(uri.host);
        throw StateError('blocked a request to ${uri.host}');
      }
      return Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }
}

class Recorded {
  final String method;
  final String path;
  final Map<String, String> headers;
  final Uint8List body;
  Recorded(this.method, this.path, this.headers, this.body);
}

/// A part of a multipart body: name, file name, content type and the body
/// bytes as latin1 (each byte one code unit).
List<Map<String, Object?>> parseMultipart(Uint8List body, String boundary) {
  final text = latin1.decode(body);
  final delimiter = '--$boundary';
  final parts = <Map<String, Object?>>[];
  var index = text.indexOf(delimiter);
  while (index >= 0) {
    final start = index + delimiter.length;
    if (text.startsWith('--', start)) break;
    final next = text.indexOf('\r\n$delimiter', start);
    final chunk = text.substring(start + 2, next);
    final split = chunk.indexOf('\r\n\r\n');
    final headerLines = chunk.substring(0, split).split('\r\n');
    final content = chunk.substring(split + 4);
    final headers = <String, String>{
      for (final line in headerLines)
        line.substring(0, line.indexOf(':')).toLowerCase(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
    };
    final disposition = headers['content-disposition'] ?? '';
    String? attr(String name) {
      final match = RegExp('$name="([^"]*)"').firstMatch(disposition);
      return match?.group(1);
    }

    parts.add({
      'name': attr('name'),
      'filename': attr('filename'),
      'contentType': headers['content-type'],
      'headers': headers.keys.toList(),
      'bytes': content.codeUnits,
    });
    index = next;
    if (next < 0) break;
    index = next + 2;
  }
  return parts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('voice requests', () async {
    // The key the service looks for, for this test only.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = utf8.decode(message!.buffer.asUint8List());
          if (key == '.env') {
            return ByteData.sublistView(
              Uint8List.fromList(
                utf8.encode('OPEN_AI_API_KEY=parity-harness-dummy-key\n'),
              ),
            );
          }
          return null;
        });

    final overrides = LoopbackOnly();
    HttpOverrides.global = overrides;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final recorded = <Recorded>[];
    server.listen((request) async {
      final bytes = await request.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final headers = <String, String>{};
      request.headers.forEach(
        (name, values) => headers[name] = values.join(', '),
      );
      recorded.add(
        Recorded(request.method, request.uri.path, headers, bytes.takeBytes()),
      );
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/audio/transcriptions')) {
        request.response.write(jsonEncode({'text': ' coffee twelve fifty '}));
      } else {
        request.response.write(
          jsonEncode({
            'id': 'chatcmpl-parity',
            'object': 'chat.completion',
            'created': 1,
            'model': 'gpt-5.4-nano',
            'choices': [
              {
                'index': 0,
                'message': {
                  'role': 'assistant',
                  'content':
                      '{"type":"expense","description":"Coffee","amount":12.5,"category":"General","date":"2026-09-28"}',
                },
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          }),
        );
      }
      await request.response.close();
    });
    OpenAI.baseUrl = 'http://127.0.0.1:${server.port}';
    expect(OpenAI.baseUrl.startsWith('http://127.0.0.1:'), isTrue);

    final service = VoiceExpenseService();
    final defaultExpense = Map.of(expenseCategories);
    final defaultIncome = Map.of(incomeCategories);
    void setCategories(List<String> expense, List<String> income) {
      expenseCategories
        ..clear()
        ..addAll({for (final n in expense) n: defaultExpense.values.first});
      incomeCategories
        ..clear()
        ..addAll({for (final n in income) n: defaultIncome.values.first});
    }

    final chat = <Map<String, Object?>>[];
    Future<void> parse(String label, String transcript, DateTime today) async {
      recorded.clear();
      Object? error;
      try {
        await service.parse(transcript, today);
      } catch (e) {
        error = e.toString();
      }
      expect(recorded.length, 1, reason: '$label: one request ($error)');
      final r = recorded.single;
      chat.add({
        'label': label,
        'today': {
          'iso': today.toIso8601String(),
          'us': today.microsecondsSinceEpoch,
        },
        'transcript': transcript,
        'expenseCategories': expenseCategories.keys.toList(),
        'incomeCategories': incomeCategories.keys.toList(),
        'method': r.method,
        'path': r.path,
        'authorization': r.headers['authorization'],
        'contentType': r.headers['content-type'],
        'body': utf8.decode(r.body),
        'error': error,
      });
    }

    final days = <(String, DateTime)>[
      ('launch', local([2026, 9, 28, 9, 15])),
      ('Santiago gap day', local([2026, 9, 6, 0, 30])),
      ('Santiago gap midnight', local([2026, 9, 6])),
      ('Santiago fold day', local([2026, 4, 4, 23, 30])),
      ('New York gap day', local([2026, 3, 8, 2, 30])),
      ('New York fold day', local([2026, 11, 1, 1, 30])),
      ('year end', local([2026, 12, 31, 23, 59])),
      ('year start', local([2027, 1, 1])),
      ('leap day', local([2028, 2, 29, 12])),
      ('sunday', local([2026, 9, 27, 8])),
      ('monday', local([2026, 9, 28])),
      ('single digit', local([2026, 1, 5, 7, 7])),
    ];
    for (final (name, day) in days) {
      await parse('default categories, $name', 'coffee twelve fifty', day);
    }
    await parse(
      'quotes and unicode in the transcript',
      'Café "Noir" ☕ \u{1F355}\nline two \\ back',
      days[0].$2,
    );
    await parse('empty transcript', '', days[0].$2);
    setCategories(
      ['Café', 'Eating, Out', '\u{1F355} Pizza', 'x' * 60],
      ['Pay', 'Other'],
    );
    await parse('custom categories', 'pizza', days[0].$2);
    setCategories([], []);
    await parse('no categories', 'pizza', days[0].$2);
    expenseCategories
      ..clear()
      ..addAll(defaultExpense);
    incomeCategories
      ..clear()
      ..addAll(defaultIncome);

    final dir = await Directory.systemTemp.createTemp('voice_request');
    final multipart = <Map<String, Object?>>[];
    for (final name in [
      'clip.m4a',
      'Café note.m4a',
      'clip.wav',
      'clip.mp3',
      'clip.aac',
      'clip',
    ]) {
      recorded.clear();
      final file = File('${dir.path}/$name');
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0xFE,
        0xFF,
        0x0D,
        0x0A,
        0x2D,
        0x2D,
        0x80,
      ]);
      await file.writeAsBytes(bytes);
      Object? error;
      String? transcript;
      try {
        transcript = await service.transcribe(file);
      } catch (e) {
        error = e.toString();
      }
      expect(recorded.length, 1, reason: '$name: one request ($error)');
      final r = recorded.single;
      final contentType = r.headers['content-type']!;
      final boundary = RegExp(
        'boundary=(.*)\$',
      ).firstMatch(contentType)!.group(1)!;
      multipart.add({
        'fileName': name,
        'fileBytes': bytes,
        'method': r.method,
        'path': r.path,
        'authorization': r.headers['authorization'],
        'contentTypePrefix': contentType.substring(
          0,
          contentType.indexOf('boundary='),
        ),
        'parts': parseMultipart(r.body, boundary),
        'transcript': transcript,
        'error': error,
      });
    }
    await dir.delete(recursive: true);

    expect(overrides.blocked, isEmpty, reason: 'nothing left the machine');
    await server.close(force: true);
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);

    writeJson('$fixturesRoot/$zoneDir/request.json', {
      'tz': parityTz,
      'chat': chat,
      'transcription': multipart,
    });
  });
}
