import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_trail/screen_trail.dart';

const search = TrailElement(
  id: 'article.search.input',
  label: 'Search articles',
  path: 'article > content > search',
);
const password = TrailElement(
  id: 'login.password.input',
  label: 'Password',
  path: 'login > form > password',
);
final eventsUri = Uri.parse('https://example.com/telemetry/events');
final errorsUri = Uri.parse('https://example.com/telemetry/errors');
HttpTrailTransport httpTransport(http.Client client) => HttpTrailTransport(
  eventsUri: eventsUri,
  errorsUri: errorsUri,
  client: client,
);

/// Ported tests use `recordTypedText: true`, which is the old behavior.
ScreenTrail tracker(
  http.Client client, {
  DateTime Function()? now,
  bool recordTypedText = true,
}) => ScreenTrail(
  appId: 'demo_app',
  buildVersion: '1.2.0',
  screens: const [
    TrailScreen(name: 'article', route: '/article/:slug', label: 'Article'),
  ],
  transport: httpTransport(client),
  recordTypedText: recordTypedText,
  autoFlush: false,
  now: now,
);

/// Records every payload and answers with the next queued result.
class FakeTransport implements TrailTransport {
  final events = <Map<String, dynamic>>[];
  final errors = <Map<String, dynamic>>[];
  final results = <TrailSendResult>[];
  TrailSendResult _next() =>
      results.isEmpty ? TrailSendResult.sent : results.removeAt(0);
  @override
  Future<TrailSendResult> sendEvents(Map<String, dynamic> batch) async {
    events.add(jsonDecode(jsonEncode(batch)) as Map<String, dynamic>);
    return _next();
  }

  @override
  Future<TrailSendResult> sendErrors(Map<String, dynamic> batch) async {
    errors.add(jsonDecode(jsonEncode(batch)) as Map<String, dynamic>);
    return _next();
  }
}

ScreenTrail fakeTracker(
  FakeTransport transport, {
  DateTime Function()? now,
  bool autoFlush = false,
  bool recordTypedText = false,
}) => ScreenTrail(
  appId: 'demo_app',
  buildVersion: '1.2.0',
  screens: const [
    TrailScreen(name: 'article', route: '/article/:slug', label: 'Article'),
  ],
  transport: transport,
  recordTypedText: recordTypedText,
  autoFlush: autoFlush,
  now: now,
);

void main() {
  test(
    'sensitive values are absent from every request, including later errors',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      t.view('/article/flutter?token=query-secret#fragment');
      t.event('input', password, value: 'private-password');
      t.event('input', search, value: 'Flutter study');
      t.error(
        'Failure private-password Bearer bearer-value',
        StackTrace.fromString('stack private-password'),
      );
      await t.flush();
      expect(requests.length, 2);
      final all = requests.map((r) => r.body).join();
      expect(all, contains('Flutter study'));
      for (final secret in [
        'private-password',
        'bearer-value',
        'query-secret',
        'fragment',
      ]) {
        expect(all, isNot(contains(secret)));
      }
      final batch = jsonDecode(requests.first.body) as Map<String, dynamic>;
      final sensitive = (batch['events'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((v) => v['element_id'] == password.id);
      expect(sensitive['value'], isNull);
      expect(batch.containsKey('user_id'), isFalse);
      expect(batch.containsKey('ip'), isFalse);
      t.dispose();
    },
  );
  test(
    'explicit sensitive fields with translated labels also drop on device',
    () async {
      final requests = <String>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r.body);
          return http.Response('{}', 202);
        }),
      );
      t.event(
        'input',
        const TrailElement(
          id: 'checkout.card.input',
          label: 'Número',
          path: 'checkout > form > card',
        ),
        value: '4111111111111111',
        sensitive: true,
      );
      await t.flush();
      expect(requests.single, isNot(contains('4111111111111111')));
      t.dispose();
    },
  );
  test('batches stay below body limit and queued events are bounded', () async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    for (var i = 0; i < 300; i++) {
      t.event('input', search, value: 'ไทย' * 1200);
    }
    for (var i = 0; i < 100; i++) {
      await t.flush();
    }
    var count = 0;
    for (final r in requests) {
      expect(utf8.encode(r.body).length, lessThanOrEqualTo(60000));
      final events = (jsonDecode(r.body) as Map)['events'] as List;
      expect(events.length, lessThanOrEqualTo(50));
      count += events.length;
    }
    expect(count, 200);
    t.dispose();
  });
  test(
    'global error capture forwards previous handlers and restores them',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      final before = FlutterError.onError;
      var forwarded = 0;
      void previous(FlutterErrorDetails details) {
        forwarded++;
      }

      FlutterError.onError = previous;
      try {
        t.installErrorCapture();
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: StateError('capture fixture'),
            stack: StackTrace.current,
          ),
        );
        await t.flush();
        expect(forwarded, 1);
        expect(requests.single.url, errorsUri);
        expect(requests.single.body, contains('capture fixture'));
        t.dispose();
        expect(FlutterError.onError, previous);
      } finally {
        t.dispose();
        FlutterError.onError = before;
      }
    },
  );
  test('sensitive capability paths never enter telemetry', () async {
    final bodies = <String>[];
    final t = ScreenTrail(
      appId: 'demo_app',
      buildVersion: '1',
      screens: const [
        TrailScreen(
          name: 'invite',
          route: '/invite/:code',
          label: 'Shared room',
          sensitivePath: true,
        ),
      ],
      transport: httpTransport(
        MockClient((r) async {
          bodies.add(r.body);
          return http.Response('{}', 202);
        }),
      ),
      autoFlush: false,
    );
    t.view('/invite/private-room-token');
    await t.flush();
    expect(bodies.single, isNot(contains('private-room-token')));
    expect(bodies.single, contains('/invite/:code'));
    t.dispose();
  });
  test(
    'manual reports complete only when the errors endpoint accepts them',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', requests.length == 1 ? 503 : 202);
        }),
      );
      await expectLater(t.sendError('manual report'), throwsStateError);
      await t.sendError('manual report');
      expect(requests.length, 2);
      expect(requests.last.url, errorsUri);
      t.dispose();
    },
  );
  test('explicit error routes are safe and do not change navigation', () async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    t.view('/article/flutter');
    t.error('failure', null, route: '/callback?token=private');
    t.event('click', search);
    await t.flush();
    final error = jsonDecode(requests.last.body) as Map;
    expect(error['route'], '/callback');
    final batch = jsonDecode(requests.first.body) as Map;
    expect((batch['events'] as List).last['path'], '/article/flutter');
    t.dispose();
  });
  testWidgets('custom UI locale metadata does not change child localization', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenTrailRoot(
          tracker: t,
          locale: 'th',
          child: Builder(
            builder: (context) =>
                Text(Localizations.localeOf(context).languageCode),
          ),
        ),
      ),
    );
    t.event('click', search);
    await t.flush();
    expect((jsonDecode(requests.single.body) as Map)['locale'], 'th');
    expect(find.text('en'), findsOneWidget);
    t.dispose();
  });
  testWidgets(
    'declared semantic aliases map an existing control without editing it',
    (tester) async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenTrailRoot(
            tracker: t,
            resolveElement: (_, result) =>
                elementFromSemantics(result, {'Existing control': search}),
            child: Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () {},
                    child: const Text('Existing control'),
                  ),
                  const Text('Existing control'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Existing control').first);
      await t.flush();
      final batch = jsonDecode(requests.single.body) as Map;
      expect((batch['events'] as List).single['element_id'], search.id);
      requests.clear();
      await tester.tap(find.text('Existing control').last);
      await t.flush();
      final surface = jsonDecode(requests.single.body) as Map;
      expect(
        (surface['events'] as List).single['element_id'],
        'article.surface',
      );
      t.dispose();
    },
  );
  testWidgets(
    'nearest mapped ancestor names a nested control without layout changes',
    (tester) async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenTrailRoot(
            tracker: t,
            child: Scaffold(
              body: TrackedElement(
                element: search,
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Search'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Search'));
      await t.flush();
      final events =
          (jsonDecode(requests.single.body) as Map)['events'] as List;
      expect(events.single['element_id'], search.id);
      expect(events.single['element_label'], 'Search articles');
      expect(events.single['element_path'], 'article > content > search');
      t.dispose();
    },
  );
  testWidgets(
    'controller wrapper records text changes while dropping password values',
    (tester) async {
      final requests = <http.Request>[];
      final controller = TextEditingController();
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenTrailRoot(
            tracker: t,
            child: Scaffold(
              body: TrackedInput(
                element: password,
                sensitive: true,
                controller: controller,
                child: TextField(controller: controller, obscureText: true),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'secret-input');
      await t.flush();
      final all = requests.map((r) => r.body).join();
      expect(all, isNot(contains('secret-input')));
      expect(all, contains('"event_type":"input"'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      t.dispose();
    },
  );
  testWidgets('navigation observer tracks screen, template and path', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/article/flutter',
        navigatorObservers: [ScreenTrailObserver(t)],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const SizedBox(),
        ),
      ),
    );
    await t.flush();
    final events = (jsonDecode(requests.single.body) as Map)['events'] as List;
    expect(events.last['screen'], 'article');
    expect(events.last['route'], '/article/:slug');
    expect(events.last['path'], '/article/flutter');
    t.dispose();
  });
  testWidgets('failed batches retry with the same session and sequence', (
    tester,
  ) async {
    var current = DateTime(2026);
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', requests.length == 1 ? 503 : 202);
      }),
      now: () => current,
    );
    t.event('click', search);
    await t.flush();
    current = current.add(const Duration(seconds: 3));
    await t.flush();
    expect(requests.length, 2);
    expect(requests[0].body, requests[1].body);
    t.dispose();
  });
  testWidgets('identity conflicts rotate UUID and retain pending events', (
    tester,
  ) async {
    var current = DateTime(2026);
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', requests.length == 1 ? 409 : 202);
      }),
      now: () => current,
    );
    t.event('click', search);
    await t.flush();
    current = current.add(const Duration(seconds: 3));
    await t.flush();
    expect(requests.length, 2);
    final first = jsonDecode(requests[0].body) as Map;
    final next = jsonDecode(requests[1].body) as Map;
    expect(first['session_id'], isNot(next['session_id']));
    expect((next['events'] as List).single['element_id'], search.id);
    t.dispose();
  });

  group('HttpTrailTransport headers', () {
    test('HttpTrailTransport adds the configured headers', () async {
      final requests = <http.Request>[];
      final transport = HttpTrailTransport(
        eventsUri: eventsUri,
        errorsUri: errorsUri,
        headers: const {'X-App-Key': 'demo'},
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await transport.sendEvents({'events': []});
      expect(requests.single.headers['X-App-Key'], 'demo');
      expect(
        requests.single.headers['content-type'],
        startsWith('application/json'),
      );
    });
  });

  group('transport', () {
    testWidgets(
      'a fake transport receives batches with today size and time limits',
      (tester) async {
        final transport = FakeTransport();
        final t = fakeTracker(transport, autoFlush: true);
        for (var i = 0; i < 120; i++) {
          t.event('click', search);
        }
        await tester.pump(const Duration(milliseconds: 1900));
        expect(transport.events, isEmpty);
        await tester.pump(const Duration(milliseconds: 100));
        expect(transport.events.length, 1);
        expect((transport.events.single['events'] as List).length, 50);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        expect(
          transport.events.map((b) => (b['events'] as List).length).toList(),
          [50, 50, 20],
        );
        t.dispose();

        final large = FakeTransport();
        final l = fakeTracker(large, recordTypedText: true);
        for (var i = 0; i < 60; i++) {
          l.event('input', search, value: 'ไทย' * 1200);
        }
        for (var i = 0; i < 20; i++) {
          await l.flush();
        }
        var count = 0;
        for (final batch in large.events) {
          expect(
            utf8.encode(jsonEncode(batch)).length,
            lessThanOrEqualTo(60000),
          );
          count += (batch['events'] as List).length;
        }
        expect(large.events.length, greaterThan(1));
        expect(count, 60);
        l.dispose();
      },
    );
    test('retry keeps the batch and waits for the backoff', () async {
      var current = DateTime(2026);
      final transport = FakeTransport()..results.add(TrailSendResult.retry);
      final t = fakeTracker(transport, now: () => current);
      t.event('click', search);
      await t.flush();
      current = current.add(const Duration(milliseconds: 1999));
      await t.flush();
      expect(transport.events.length, 1);
      current = current.add(const Duration(milliseconds: 1));
      await t.flush();
      expect(transport.events.length, 2);
      expect(transport.events[0], transport.events[1]);
      await t.flush();
      expect(transport.events.length, 2);
      t.dispose();
    });
    test('backoff doubles up to 64 seconds', () async {
      var current = DateTime(2026);
      final transport = FakeTransport()
        ..results.addAll(List.filled(8, TrailSendResult.retry));
      final t = fakeTracker(transport, now: () => current);
      t.event('click', search);
      final waits = <int>[];
      for (var i = 0; i < 7; i++) {
        final before = transport.events.length;
        var waited = 0;
        while (transport.events.length == before) {
          await t.flush();
          if (transport.events.length == before) {
            current = current.add(const Duration(seconds: 1));
            waited++;
          }
        }
        waits.add(waited);
      }
      expect(waits, [0, 2, 4, 8, 16, 32, 64]);
      t.dispose();
    });
    test('discard drops the batch and the error report', () async {
      final transport = FakeTransport()
        ..results.addAll([TrailSendResult.discard, TrailSendResult.discard]);
      final t = fakeTracker(transport);
      t.event('click', search);
      t.error('failure', null);
      await t.flush();
      await t.flush();
      expect(transport.events.length, 1);
      expect(transport.errors.length, 1);
      t.dispose();
    });
    test(
      'rotateSession creates a new session and resends pending events',
      () async {
        var current = DateTime(2026);
        final transport = FakeTransport()
          ..results.add(TrailSendResult.rotateSession);
        final t = fakeTracker(transport, now: () => current);
        t.event('click', search);
        t.event('submit', search);
        await t.flush();
        current = current.add(const Duration(seconds: 2));
        await t.flush();
        expect(transport.events.length, 2);
        final first = transport.events[0];
        final next = transport.events[1];
        expect(next['session_id'], isNot(first['session_id']));
        expect(
          (next['events'] as List).map((e) => [e['seq'], e['event_type']]),
          [
            [0, 'click'],
            [1, 'submit'],
          ],
        );
        t.dispose();
      },
    );
    test('a transport that throws acts as retry', () async {
      var current = DateTime(2026);
      var calls = 0;
      final t = ScreenTrail(
        appId: 'demo_app',
        buildVersion: '1',
        screens: const [],
        transport: HttpTrailTransport(
          eventsUri: eventsUri,
          errorsUri: errorsUri,
          client: MockClient((_) async {
            calls++;
            if (calls == 1) throw http.ClientException('offline');
            return http.Response('{}', 202);
          }),
        ),
        autoFlush: false,
        now: () => current,
      );
      t.event('click', search);
      await t.flush();
      current = current.add(const Duration(seconds: 2));
      await t.flush();
      await t.flush();
      expect(calls, 2);
      t.dispose();
    });
  });

  group('HttpTrailTransport status mapping', () {
    Future<TrailSendResult> send(int status) => HttpTrailTransport(
      eventsUri: eventsUri,
      errorsUri: errorsUri,
      client: MockClient((_) async => http.Response('{}', status)),
    ).sendEvents({'events': []});
    final expected = {
      202: TrailSendResult.sent,
      200: TrailSendResult.sent,
      409: TrailSendResult.rotateSession,
      400: TrailSendResult.discard,
      413: TrailSendResult.discard,
      422: TrailSendResult.discard,
      429: TrailSendResult.retry,
      500: TrailSendResult.retry,
    };
    for (final entry in expected.entries) {
      test('${entry.key} is ${entry.value.name}', () async {
        expect(await send(entry.key), entry.value);
      });
    }
    test('a network error is retry', () async {
      final transport = HttpTrailTransport(
        eventsUri: eventsUri,
        errorsUri: errorsUri,
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(await transport.sendErrors({}), TrailSendResult.retry);
    });
    testWidgets('a 10 second timeout is retry', (tester) async {
      final never = Completer<http.Response>();
      final transport = HttpTrailTransport(
        eventsUri: eventsUri,
        errorsUri: errorsUri,
        client: MockClient((_) => never.future),
      );
      TrailSendResult? result;
      unawaited(transport.sendEvents({}).then((r) => result = r));
      await tester.pump(const Duration(milliseconds: 9900));
      expect(result, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(result, TrailSendResult.retry);
    });
  });

  group('recordTypedText', () {
    for (final record in [false, true]) {
      test('recordTypedText: $record', () async {
        final transport = FakeTransport();
        final t = fakeTracker(transport, recordTypedText: record);
        t.event('input', search, value: 'typed words');
        t.event('input', password, value: 'secret-one');
        t.event(
          'input',
          const TrailElement(
            id: 'checkout.card.input',
            label: 'Número',
            path: 'checkout > form > card',
          ),
          value: '4111111111111111',
          sensitive: true,
        );
        await t.flush();
        final events = (transport.events.single['events'] as List)
            .cast<Map<String, dynamic>>();
        expect(events.length, 3);
        expect(events.every((e) => e['event_type'] == 'input'), isTrue);
        expect(events[0]['value'], record ? 'typed words' : isNull);
        expect(events[0]['sensitive'], isFalse);
        expect(events[1]['value'], isNull);
        expect(events[2]['value'], isNull);
        expect(events[1]['sensitive'], isTrue);
        expect(events[2]['sensitive'], isTrue);
        final all = jsonEncode(transport.events);
        expect(all, isNot(contains('secret-one')));
        expect(all, isNot(contains('4111111111111111')));
        if (!record) expect(all, isNot(contains('typed words')));
        t.dispose();
      });
    }
    test('recordTypedText is false by default', () {
      final t = ScreenTrail(
        appId: 'demo_app',
        buildVersion: '1',
        screens: const [],
        transport: FakeTransport(),
        autoFlush: false,
      );
      expect(t.recordTypedText, isFalse);
      t.dispose();
    });
  });

  test('construction without a transport throws a clear error', () {
    expect(
      () =>
          ScreenTrail(appId: 'demo_app', buildVersion: '1', screens: const []),
      throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', 'transport')
            .having((e) => e.message, 'message', contains('TrailTransport')),
      ),
    );
  });
}
