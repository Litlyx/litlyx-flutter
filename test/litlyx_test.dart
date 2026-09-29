import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:litlyx_flutter/litlyx_flutter.dart';
import 'package:litlyx_flutter/src/litlyx.dart' show enabledStorageKey;
import 'package:litlyx_flutter/src/queue.dart' show RequestQueue;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBroker broker;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    await Litlyx.resetForTesting();
    broker = FakeBroker();
  });

  tearDown(Litlyx.resetForTesting);

  Future<void> init({
    bool enabled = true,
    int maxQueueSize = 500,
    String projectId = 'pid-123',
  }) {
    return Litlyx.init(
      projectId,
      website: 'io.mangatracker.app',
      appName: 'MangaTrack',
      appVersion: '1.2.3+13',
      enabled: enabled,
      maxQueueSize: maxQueueSize,
      trackLifecycle: false,
      client: broker.client,
    );
  }

  List<Map<String, Object?>> storedQueue() {
    final raw = prefs.getString(RequestQueue.storageKey);
    if (raw == null) return const <Map<String, Object?>>[];
    return (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();
  }

  List<Object?> eventNames() =>
      broker.bodies('/event').map((body) => body['name']).toList();

  void expectCommonFields(http.Request request) {
    final body = FakeBroker.decode(request);
    expect(request.method, 'POST');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    expect(body['pid'], 'pid-123');
    expect(body['website'], 'io.mangatracker.app');
    final userAgent = body['userAgent'];
    expect(userAgent, isA<String>());
    expect(userAgent, startsWith('Mozilla/5.0 ('));
    expect(userAgent, endsWith(' MangaTrack/1.2.3'));
    expect(request.headers['User-Agent'], userAgent);
  }

  group('wire format', () {
    test('POST /visit', () async {
      await init();
      Litlyx.screen('/home');
      Litlyx.screen('library', utm: <String, String>{'source': 'push'});
      await Litlyx.flush();

      final requests = broker.requestsTo('/visit');
      expect(requests, hasLength(2));
      expect(
        requests.first.url.toString(),
        'https://broker.litlyx.com/visit',
      );
      requests.forEach(expectCommonFields);
      final bodies = broker.bodies('/visit');
      expect(
          bodies[0].keys,
          unorderedEquals(<String>[
            'pid',
            'website',
            'page',
            'referrer',
            'userAgent',
          ]));
      expect(bodies[0]['page'], '/home');
      expect(bodies[0]['referrer'], 'self');
      expect(bodies[1]['page'], '/library');
      expect(bodies[1]['referrer'], '/home');
      expect(bodies[1]['utm_source'], 'push');
    });

    test('POST /event with metadata as a JSON string', () async {
      await init();
      Litlyx.event(
        'chapter_read',
        metadata: <String, Object>{'genre': 'shonen', 'page': 12, 'r': 4.5},
      );
      Litlyx.event('app_open');
      await Litlyx.flush();

      final requests = broker.requestsTo('/event');
      expect(requests, hasLength(2));
      expect(
        requests.first.url.toString(),
        'https://broker.litlyx.com/event',
      );
      requests.forEach(expectCommonFields);
      final bodies = broker.bodies('/event');
      expect(bodies[0]['name'], 'chapter_read');
      expect(bodies[0]['metadata'], isA<String>());
      expect(
        jsonDecode(bodies[0]['metadata']! as String),
        <String, Object>{'genre': 'shonen', 'page': 12, 'r': 4.5},
      );
      expect(
          bodies[1].keys,
          unorderedEquals(<String>[
            'pid',
            'name',
            'website',
            'userAgent',
          ]));
    });

    test('self-hosted broker', () async {
      await Litlyx.init(
        'pid-123',
        host: 'https://analytics.example.com/',
        port: 3000,
        secure: false,
        trackLifecycle: false,
        client: broker.client,
      );
      Litlyx.event('ping');
      await Litlyx.flush();
      expect(
        broker.requests.single.url.toString(),
        'http://analytics.example.com:3000/event',
      );
      expect(
          FakeBroker.decode(broker.requests.single)['website'], 'flutter-app');
    });
  });

  group('screens', () {
    test('referrer defaults to the previous screen', () async {
      await init();
      Litlyx.screen('/a');
      Litlyx.screen('/b');
      Litlyx.screen('/c', referrer: 'https://news.example.com');
      Litlyx.screen('/d');
      await Litlyx.flush();
      expect(broker.bodies('/visit').map((body) => body['referrer']), <String>[
        'self',
        '/a',
        'https://news.example.com',
        '/c',
      ]);
    });

    test('pages get a leading slash and lose query strings', () async {
      await init();
      Litlyx.screen('manga?id=3#top');
      await Litlyx.flush();
      expect(broker.bodies('/visit').single['page'], '/manga');
    });
  });

  group('before init', () {
    test('calls are buffered and replayed in order', () async {
      Litlyx.screen('/splash');
      Litlyx.event('early');
      expect(Litlyx.isEnabled, isFalse);
      await init();
      await Litlyx.flush();
      expect(broker.requests.map((request) => request.url.path), <String>[
        '/visit',
        '/event',
      ]);
      expect(Litlyx.isEnabled, isTrue);
    });

    test('the buffer keeps the last 100 calls', () async {
      for (var i = 0; i < 150; i++) {
        Litlyx.event('e$i');
      }
      await init();
      await Litlyx.flush();
      final names = eventNames();
      expect(names, hasLength(100));
      expect(names.first, 'e50');
      expect(names.last, 'e149');
    });

    test('flush() waits for a pending init', () async {
      Litlyx.event('early');
      final initializing = init();
      await Litlyx.flush();
      expect(eventNames(), <String>['early']);
      await initializing;
    });

    test('a second init() is ignored', () async {
      await init();
      await init(projectId: 'another-project');
      Litlyx.event('x');
      await Litlyx.flush();
      expect(FakeBroker.decode(broker.requests.single)['pid'], 'pid-123');
    });
  });

  group('opt-out', () {
    test('is persisted, clears the queue and wins over enabled: true',
        () async {
      broker.offline = true;
      await init();
      Litlyx.event('queued');
      await Litlyx.flush();
      expect(storedQueue(), hasLength(1));

      await Litlyx.setEnabled(false);
      expect(Litlyx.isEnabled, isFalse);
      expect(prefs.getBool(enabledStorageKey), isFalse);
      expect(storedQueue(), isEmpty);

      broker
        ..offline = false
        ..requests.clear();
      Litlyx.event('ignored');
      Litlyx.screen('/ignored');
      await Litlyx.flush();
      expect(broker.requests, isEmpty);

      // Cold start: the persisted choice wins over `enabled: true`.
      await Litlyx.resetForTesting();
      await init();
      expect(Litlyx.isEnabled, isFalse);
      Litlyx.event('still-ignored');
      await Litlyx.flush();
      expect(broker.requests, isEmpty);

      await Litlyx.setEnabled(true);
      Litlyx.event('back');
      await Litlyx.flush();
      expect(eventNames(), <String>['back']);
    });

    test('setEnabled(false) before init drops buffered calls', () async {
      Litlyx.event('before');
      await Litlyx.setEnabled(false);
      Litlyx.event('after');
      expect(Litlyx.isEnabled, isFalse);
      await init();
      await Litlyx.flush();
      expect(Litlyx.isEnabled, isFalse);
      expect(broker.requests, isEmpty);
      expect(prefs.getBool(enabledStorageKey), isFalse);
    });

    test('consent flow: enabled: false until the user opts in', () async {
      await init(enabled: false);
      Litlyx.event('no-consent');
      await Litlyx.flush();
      expect(broker.requests, isEmpty);

      await Litlyx.setEnabled(true);
      await Litlyx.resetForTesting();
      await init(enabled: false);
      expect(Litlyx.isEnabled, isTrue);
      Litlyx.event('consented');
      await Litlyx.flush();
      expect(eventNames(), <String>['consented']);
    });
  });

  group('offline queue', () {
    test('network failures are queued and replayed after a restart', () async {
      broker.offline = true;
      await init();
      Litlyx.event('offline');
      Litlyx.screen('/offline');
      await Litlyx.flush();
      expect(storedQueue().map((entry) => entry['path']), <String>[
        '/event',
        '/visit',
      ]);

      await Litlyx.resetForTesting();
      broker
        ..offline = false
        ..requests.clear();
      await init();
      await Litlyx.flush();
      expect(broker.requests.map((request) => request.url.path), <String>[
        '/event',
        '/visit',
      ]);
      expect(storedQueue(), isEmpty);
    });

    test('4xx responses are dropped, 5xx responses are kept', () async {
      broker.status = 400;
      await init();
      Litlyx.event('rejected');
      await Litlyx.flush();
      expect(storedQueue(), isEmpty);

      broker.status = 500;
      Litlyx.event('server-error');
      await Litlyx.flush();
      expect(storedQueue(), hasLength(1));

      broker.status = 200;
      await Litlyx.flush();
      expect(storedQueue(), isEmpty);
      expect(eventNames(), <String>[
        'rejected',
        'server-error',
        'server-error',
      ]);
    });

    test('maxQueueSize drops the oldest requests', () async {
      broker.offline = true;
      await init(maxQueueSize: 3);
      for (final name in <String>['a', 'b', 'c', 'd', 'e']) {
        Litlyx.event(name);
      }
      await Litlyx.flush();
      expect(
        storedQueue().map(
          (entry) => (entry['body']! as Map<String, Object?>)['name'],
        ),
        <String>['c', 'd', 'e'],
      );
    });

    test('requests older than 7 days expire', () async {
      var now = DateTime.utc(2026, 1, 1);
      await Litlyx.resetForTesting(clock: () => now);
      broker.offline = true;
      await init();
      Litlyx.event('stale');
      await Litlyx.flush();
      expect(storedQueue(), hasLength(1));

      now = now.add(const Duration(days: 7, seconds: 1));
      broker
        ..offline = false
        ..requests.clear();
      await Litlyx.flush();
      expect(broker.requests, isEmpty);
      expect(storedQueue(), isEmpty);
    });
  });

  group('argument checks', () {
    test('debug assertions reject invalid metadata and PII keys', () {
      expect(
        () => Litlyx.event('x', metadata: <String, Object>{'premium': true}),
        throwsAssertionError,
      );
      expect(
        () => Litlyx.event('x', metadata: <String, Object>{'email': 'a@b.c'}),
        throwsAssertionError,
      );
      expect(
        () => Litlyx.event('x', metadata: <String, Object>{'userId': 42}),
        throwsAssertionError,
      );
      expect(() => Litlyx.event(' '), throwsAssertionError);
      expect(() => Litlyx.screen(''), throwsAssertionError);
    });

    test('metadata is copied when the call is made', () async {
      final metadata = <String, Object>{'step': 1};
      Litlyx.event('copy', metadata: metadata);
      metadata['step'] = 2;
      await init();
      await Litlyx.flush();
      expect(
        jsonDecode(broker.bodies('/event').single['metadata']! as String),
        <String, Object>{'step': 1},
      );
    });

    test('nothing throws when the broker fails', () async {
      broker.statusFor = (_) => throw StateError('boom');
      await init();
      Litlyx.event('x');
      Litlyx.screen('/x');
      await Litlyx.flush();
      await Litlyx.setEnabled(false);
      await Litlyx.flush();
    });
  });
}
