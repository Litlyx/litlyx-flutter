import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litlyx_flutter/src/config.dart';
import 'package:litlyx_flutter/src/queue.dart';
import 'package:litlyx_flutter/src/storage.dart';
import 'package:litlyx_flutter/src/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_broker.dart';

void main() {
  late FakeBroker broker;
  late SharedPreferences prefs;
  late LitlyxStore store;
  late DateTime now;
  final queues = <RequestQueue>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    store = SharedPreferencesStore(prefs);
    broker = FakeBroker();
    now = DateTime.utc(2026, 9, 1, 12);
  });

  tearDown(() {
    for (final queue in queues) {
      queue.dispose();
    }
    queues.clear();
  });

  RequestQueue newQueue({int maxSize = 500, DateTime Function()? clock}) {
    final transport = LitlyxTransport(
      config: LitlyxConfig(projectId: 'pid'),
      client: broker.client,
      sendUserAgentHeader: true,
    );
    final queue = RequestQueue(
      store: store,
      send: transport.post,
      maxSize: maxSize,
      clock: clock ?? () => now,
      random: Random(7),
    )..load();
    queues.add(queue);
    return queue;
  }

  Map<String, Object?> event(String name) =>
      <String, Object?>{'pid': 'pid', 'name': name};

  List<Map<String, Object?>> stored() {
    final raw = prefs.getString(RequestQueue.storageKey);
    if (raw == null) return const <Map<String, Object?>>[];
    return (jsonDecode(raw) as List<Object?>).cast<Map<String, Object?>>();
  }

  List<Object?> sentNames() =>
      broker.bodies('/event').map((body) => body['name']).toList();

  test('persists requests as {id, path, body, ts, attempts}', () async {
    broker.offline = true;
    final queue = newQueue();
    queue.add('/event', event('a'));
    await queue.flush();

    final entries = stored();
    expect(entries, hasLength(1));
    expect(
      entries.single.keys,
      unorderedEquals(<String>['id', 'path', 'body', 'ts', 'attempts']),
    );
    expect(entries.single['path'], '/event');
    expect(entries.single['body'], event('a'));
    expect(entries.single['ts'], now.millisecondsSinceEpoch);
    expect(entries.single['attempts'], 1);
    expect(entries.single['id'], isA<String>());
  });

  test('removes delivered requests from storage', () async {
    final queue = newQueue();
    queue.add('/event', event('a'));
    await queue.flush();
    expect(sentNames(), <String>['a']);
    expect(queue.length, 0);
    expect(prefs.containsKey(RequestQueue.storageKey), isFalse);
  });

  test('sends sequentially and stops at the first failure', () async {
    broker.statusFor =
        (request) => FakeBroker.decode(request)['name'] == 'b' ? 503 : 200;
    final queue = newQueue();
    queue
      ..add('/event', event('a'))
      ..add('/event', event('b'))
      ..add('/event', event('c'));
    await queue.flush();

    expect(sentNames(), <String>['a', 'b']);
    expect(queue.items.map((item) => item.body['name']), <String>['b', 'c']);
    expect(queue.items.first.attempts, 1);
    expect(queue.isRetryScheduled, isTrue);
  });

  test('drops 4xx rejections but keeps 5xx, 408 and 429 for retry', () async {
    const retried = <int>{408, 429, 500, 502, 503};
    final queue = newQueue();
    for (final status in <int>[400, 403, 404, 413, 408, 429, 500, 502, 503]) {
      await queue.clear();
      broker.status = status;
      queue.add('/event', event('status-$status'));
      await queue.flush();
      expect(queue.length, retried.contains(status) ? 1 : 0, reason: '$status');
      if (retried.contains(status)) {
        expect(queue.items.single.attempts, 1);
        expect(queue.isRetryScheduled, isTrue);
      }
    }
    expect(broker.requests, hasLength(9));
  });

  test('outcomeForStatus', () {
    expect(LitlyxTransport.outcomeForStatus(200), SendOutcome.success);
    expect(LitlyxTransport.outcomeForStatus(204), SendOutcome.success);
    expect(LitlyxTransport.outcomeForStatus(301), SendOutcome.drop);
    expect(LitlyxTransport.outcomeForStatus(400), SendOutcome.drop);
    expect(LitlyxTransport.outcomeForStatus(404), SendOutcome.drop);
    expect(LitlyxTransport.outcomeForStatus(408), SendOutcome.retry);
    expect(LitlyxTransport.outcomeForStatus(429), SendOutcome.retry);
    expect(LitlyxTransport.outcomeForStatus(500), SendOutcome.retry);
    expect(LitlyxTransport.outcomeForStatus(503), SendOutcome.retry);
  });

  test('restores the persisted queue and replays it on flush', () async {
    broker.offline = true;
    final first = newQueue();
    first
      ..add('/event', event('a'))
      ..add('/visit', <String, Object?>{'pid': 'pid', 'page': '/home'});
    await first.flush();
    first.dispose();
    expect(stored(), hasLength(2));

    broker.offline = false;
    broker.requests.clear();
    final second = newQueue();
    expect(second.length, 2);
    await second.flush();
    expect(broker.requests.map((request) => request.url.path), <String>[
      '/event',
      '/visit',
    ]);
    expect(stored(), isEmpty);
  });

  test('keeps at most maxSize requests, dropping the oldest', () async {
    broker.offline = true;
    final queue = newQueue(maxSize: 3);
    for (final name in <String>['a', 'b', 'c', 'd', 'e']) {
      queue.add('/event', event(name));
    }
    await queue.flush();
    expect(queue.items.map((item) => item.body['name']), <String>[
      'c',
      'd',
      'e',
    ]);
    expect(
        stored()
            .map((entry) => (entry['body']! as Map<String, Object?>)['name']),
        <String>[
          'c',
          'd',
          'e',
        ]);
  });

  test('discards requests older than 7 days', () async {
    broker.offline = true;
    final queue = newQueue(clock: () => now);
    queue.add('/event', event('old'));
    await queue.flush();
    now = now.add(const Duration(days: 3));
    queue.add('/event', event('recent'));
    await queue.flush();

    now = now.add(const Duration(days: 4, minutes: 1));
    broker
      ..offline = false
      ..requests.clear();
    await queue.flush();
    expect(sentNames(), <String>['recent']);
    expect(queue.length, 0);
  });

  test('discards expired and malformed entries on load', () async {
    final fresh = <String, Object?>{
      'id': '1',
      'path': '/event',
      'body': event('fresh'),
      'ts': now.millisecondsSinceEpoch,
      'attempts': 2,
    };
    final expired = <String, Object?>{
      ...fresh,
      'id': '2',
      'ts': now.subtract(const Duration(days: 8)).millisecondsSinceEpoch,
    };
    final keepAlive = <String, Object?>{...fresh, 'id': '3', 'path': '/x'};
    await prefs.setString(
      RequestQueue.storageKey,
      jsonEncode(<Object?>[fresh, expired, keepAlive, 'garbage', 42]),
    );
    broker.offline = true;
    final queue = newQueue();
    expect(queue.items.map((item) => item.id), <String>['1']);
    expect(queue.items.single.attempts, 2);

    await prefs.setString(RequestQueue.storageKey, '{not json');
    final broken = newQueue();
    expect(broken.length, 0);
  });

  test('drops bodies larger than 20 KB', () async {
    final queue = newQueue();
    final accepted = queue.add('/event', <String, Object?>{
      'pid': 'pid',
      'name': 'big',
      'metadata': 'x' * (LitlyxLimits.maxBodyBytes + 1),
    });
    expect(accepted, isFalse);
    expect(queue.length, 0);
    expect(broker.requests, isEmpty);
  });

  group('retry backoff', () {
    test('retryDelay doubles from 5 s up to 10 min', () {
      expect(retryDelay(1), const Duration(seconds: 5));
      expect(retryDelay(2), const Duration(seconds: 10));
      expect(retryDelay(3), const Duration(seconds: 20));
      expect(retryDelay(7), const Duration(seconds: 320));
      expect(retryDelay(8), const Duration(minutes: 10));
      expect(retryDelay(1000), const Duration(minutes: 10));
    });

    test('retryDelay adds ±20% jitter', () {
      final random = Random(1);
      for (var attempts = 1; attempts < 12; attempts++) {
        final base = retryDelay(attempts).inMilliseconds;
        final jittered = retryDelay(attempts, random).inMilliseconds;
        expect(jittered, inInclusiveRange(base * 0.8, base * 1.2));
      }
    });

    test('retries on a timer, without extra requests in between', () {
      fakeAsync((async) {
        broker.offline = true;
        final queue = newQueue(clock: () => now);
        queue.add('/event', event('a'));
        async.flushMicrotasks();
        expect(broker.requests, hasLength(1));
        expect(queue.isRetryScheduled, isTrue);

        // New events during the backoff are queued without sending.
        queue.add('/event', event('b'));
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 3));
        expect(broker.requests, hasLength(1));

        // First retry after 5 s ± 20%.
        async.elapse(const Duration(seconds: 3));
        expect(broker.requests, hasLength(2));
        expect(queue.items.first.attempts, 2);

        // Second retry 10 s ± 20% after the first one (at 4-6 s).
        async.elapse(const Duration(seconds: 5));
        expect(broker.requests, hasLength(2));
        broker.offline = false;
        async.elapse(const Duration(seconds: 8));
        expect(sentNames(), <String>['a', 'a', 'a', 'b']);
        expect(queue.length, 0);
        expect(queue.isRetryScheduled, isFalse);
      });
    });

    test('flush() ignores the backoff', () {
      fakeAsync((async) {
        broker.offline = true;
        final queue = newQueue(clock: () => now);
        queue.add('/event', event('a'));
        async.flushMicrotasks();
        expect(queue.isRetryScheduled, isTrue);

        broker.offline = false;
        unawaited(queue.flush());
        async.flushMicrotasks();
        expect(queue.length, 0);
        expect(queue.isRetryScheduled, isFalse);
      });
    });

    test('a request that times out after 10 s is retried', () {
      fakeAsync((async) {
        broker.hang = true;
        final queue = newQueue(clock: () => now);
        queue.add('/event', event('a'));
        async.elapse(const Duration(seconds: 9));
        expect(queue.isRetryScheduled, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(queue.isRetryScheduled, isTrue);
        expect(queue.items.single.attempts, 1);
      });
    });

    test('clear() empties memory and storage and cancels the retry', () async {
      broker.offline = true;
      final queue = newQueue();
      queue.add('/event', event('a'));
      await queue.flush();
      expect(queue.isRetryScheduled, isTrue);
      await queue.clear();
      expect(queue.length, 0);
      expect(queue.isRetryScheduled, isFalse);
      expect(prefs.containsKey(RequestQueue.storageKey), isFalse);
    });
  });

  group('payload guards', () {
    test('sanitizeMetadata keeps String and finite num values', () {
      expect(
        sanitizeMetadata(<String, Object>{
          'genre': 'shonen',
          'page': 12,
          'rating': 4.5,
          'flag': true,
          'list': <int>[1],
          'nan': double.nan,
          ' ': 'empty key',
        }),
        <String, Object>{'genre': 'shonen', 'page': 12, 'rating': 4.5},
      );
      expect(sanitizeMetadata(null), isNull);
      expect(sanitizeMetadata(<String, Object>{}), isNull);
      expect(sanitizeMetadata(<String, Object>{'flag': false}), isNull);
    });

    test('sanitizeMetadata keeps 20 keys and truncates strings to 200', () {
      final many = <String, Object>{
        for (var i = 0; i < 30; i++) 'key$i': 'v' * 300,
      };
      final result = sanitizeMetadata(many)!;
      expect(result, hasLength(LitlyxLimits.maxMetadataKeys));
      expect(result.keys.first, 'key0');
      expect(result.values.every((value) => value == 'v' * 200), isTrue);
    });

    test('describeMetadataProblem flags invalid values and PII keys', () {
      expect(describeMetadataProblem(null), isNull);
      expect(
        describeMetadataProblem(<String, Object>{'plan': 'pro', 'price': 9}),
        isNull,
      );
      expect(
        describeMetadataProblem(<String, Object>{'premium': true}),
        contains('bool'),
      );
      expect(
        describeMetadataProblem(<String, Object>{'ratio': double.infinity}),
        contains('cannot be encoded'),
      );
      for (final key in <String>[
        'email',
        'userEmail',
        'e-mail',
        'password',
        'phone_number',
        'user_id',
        'userId',
        'authToken',
      ]) {
        expect(
          describeMetadataProblem(<String, Object>{key: 'x'}),
          contains('personal data'),
          reason: key,
        );
      }
      for (final key in <String>['name', 'manga_name', 'genre', 'screen']) {
        expect(looksLikePiiKey(key), isFalse, reason: key);
      }
    });

    test('truncate does not split surrogate pairs', () {
      expect(truncate('abc', 5), 'abc');
      expect(truncate('abcdef', 3), 'abc');
      final emoji = '${'a' * 199}\u{1F600}';
      expect(truncate(emoji), 'a' * 199);
    });

    test('normalizePage', () {
      expect(normalizePage('/home'), '/home');
      expect(normalizePage('details'), '/details');
      expect(normalizePage(' /manga/42?ref=push#top '), '/manga/42');
      expect(normalizePage('?q=1'), '/');
      expect(normalizePage('   '), isNull);
      expect(normalizePage('/${'x' * 300}'), hasLength(200));
    });

    test('normalizeUtm', () {
      expect(
        normalizeUtm(<String, String>{
          'source': 'newsletter',
          'UTM_Medium': 'email',
          'utm_campaign': ' launch ',
          'content': '',
          '': 'x',
        }),
        <String, String>{
          'utm_source': 'newsletter',
          'utm_medium': 'email',
          'utm_campaign': 'launch',
        },
      );
      expect(normalizeUtm(null), isEmpty);
      expect(
        normalizeUtm(<String, String>{
          for (var i = 0; i < 20; i++) 'k$i': 'v',
        }),
        hasLength(LitlyxLimits.maxUtmParams),
      );
    });
  });
}
