import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litlyx_flutter/src/config.dart';
import 'package:litlyx_flutter/src/litlyx.dart';
import 'package:litlyx_flutter/src/storage.dart';
import 'package:litlyx_flutter/src/user_agent.dart';

import 'support/fake_broker.dart';

const DeviceSnapshot iphone = DeviceSnapshot(
  platform: TargetPlatform.iOS,
  operatingSystemVersion: 'Version 18.1 (Build 22B83)',
  shortestSide: 393,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBroker broker;

  setUp(() => broker = FakeBroker());

  /// Creates a client inside [async], with a clock that follows fake time.
  LitlyxClient createClient(
    FakeAsync async, {
    bool trackLifecycle = true,
    bool sessionNonce = false,
    int seed = 3,
  }) {
    final start = DateTime.utc(2026, 9, 1, 8);
    LitlyxClient? client;
    LitlyxClient.create(
      LitlyxConfig(
        projectId: 'pid',
        website: 'io.mangatracker.app',
        appName: 'MangaTrack',
        appVersion: '1.2.3',
        trackLifecycle: trackLifecycle,
        sessionNonce: sessionNonce,
      ),
      httpClient: broker.client,
      store: MemoryStore(),
      device: () => iphone,
      clock: () => start.add(async.elapsed),
      random: Random(seed),
      binding: binding,
    ).then((created) => client = created);
    async.flushMicrotasks();
    addTearDown(() => client!.dispose());
    return client!;
  }

  void setState(LitlyxClient client, AppLifecycleState state) =>
      client.lifecycle!.didChangeAppLifecycleState(state);

  List<Object?> instants() =>
      broker.bodies('/keep_alive').map((body) => body['instant']).toList();

  test('resume sends an instant keep-alive, then one per minute', () {
    fakeAsync((async) {
      final client = createClient(async);
      expect(broker.requests, isEmpty);

      setState(client, AppLifecycleState.resumed);
      async.flushMicrotasks();
      final request = broker.requestsTo('/keep_alive').single;
      expect(request.url.toString(), 'https://broker.litlyx.com/keep_alive');
      expect(FakeBroker.decode(request), <String, Object?>{
        'pid': 'pid',
        'website': 'io.mangatracker.app',
        'userAgent': client.userAgent,
        'instant': true,
      });
      expect(request.headers['User-Agent'], client.userAgent);
      expect(request.headers['Content-Type'], startsWith('application/json'));

      async.elapse(const Duration(seconds: 59));
      expect(instants(), <Object?>[true]);
      async.elapse(const Duration(seconds: 1));
      expect(instants(), <Object?>[true, false]);
      async.elapse(const Duration(minutes: 2));
      expect(instants(), <Object?>[true, false, false, false]);
    });
  });

  test('background stops keep-alives; foreground time accumulates', () {
    fakeAsync((async) {
      final client = createClient(async);
      setState(client, AppLifecycleState.resumed);
      async.elapse(const Duration(seconds: 40));
      setState(client, AppLifecycleState.inactive);
      setState(client, AppLifecycleState.hidden);
      setState(client, AppLifecycleState.paused);
      expect(client.lifecycle!.isKeepAliveScheduled, isFalse);
      async.elapse(const Duration(minutes: 10));
      expect(instants(), <Object?>[true]);

      setState(client, AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(instants(), <Object?>[true, true]);
      // 40 s + 20 s of foreground time make one duration unit.
      async.elapse(const Duration(seconds: 19));
      expect(instants(), <Object?>[true, true]);
      async.elapse(const Duration(seconds: 1));
      expect(instants(), <Object?>[true, true, false]);
    });
  });

  group('through the real binding', () {
    void sendLifecycle(FakeAsync async, AppLifecycleState state) {
      binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );
      async.flushMicrotasks();
    }

    tearDown(binding.resetInternalState);

    test('starts at init when the app is already in the foreground', () {
      fakeAsync((async) {
        sendLifecycle(async, AppLifecycleState.resumed);
        final client = createClient(async);
        async.flushMicrotasks();
        expect(instants(), <Object?>[true]);

        sendLifecycle(async, AppLifecycleState.paused);
        expect(client.lifecycle!.isInForeground, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(instants(), <Object?>[true]);

        sendLifecycle(async, AppLifecycleState.resumed);
        expect(instants(), <Object?>[true, true]);
      });
    });

    test('a background launch waits for the first resume', () {
      fakeAsync((async) {
        sendLifecycle(async, AppLifecycleState.paused);
        final client = createClient(async);
        async.elapse(const Duration(minutes: 5));
        expect(broker.requests, isEmpty);
        expect(client.lifecycle!.isInForeground, isFalse);

        sendLifecycle(async, AppLifecycleState.resumed);
        expect(instants(), <Object?>[true]);
      });
    });
  });

  test('inactive (system overlays) does not pause the session', () {
    fakeAsync((async) {
      final client = createClient(async);
      setState(client, AppLifecycleState.resumed);
      setState(client, AppLifecycleState.inactive);
      async.elapse(const Duration(seconds: 60));
      setState(client, AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(instants(), <Object?>[true, false]);
    });
  });

  test('pause and resume flush the queue, ignoring the backoff', () {
    fakeAsync((async) {
      final client = createClient(async);
      setState(client, AppLifecycleState.resumed);
      broker.offline = true;
      client.event('offline');
      async.flushMicrotasks();
      expect(broker.requestsTo('/event'), hasLength(1));
      expect(client.queue.isRetryScheduled, isTrue);

      setState(client, AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(broker.requestsTo('/event'), hasLength(2));

      broker.offline = false;
      setState(client, AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(broker.requestsTo('/event'), hasLength(3));
      expect(client.queue.length, 0);
    });
  });

  test('no keep-alives when disabled or when trackLifecycle is false', () {
    fakeAsync((async) {
      final disabled = createClient(async);
      disabled.setEnabled(false);
      setState(disabled, AppLifecycleState.resumed);
      async.elapse(const Duration(minutes: 3));
      expect(broker.requests, isEmpty);

      final untracked = createClient(async, trackLifecycle: false);
      expect(untracked.lifecycle, isNull);
    });
  });

  group('session nonce', () {
    test('is appended to the user agent and differs per cold start', () {
      fakeAsync((async) {
        final first = createClient(async, sessionNonce: true, seed: 1);
        final second = createClient(async, sessionNonce: true, seed: 2);
        final pattern = RegExp(r' MangaTrack/1\.2\.3 s/[0-9a-f]{6}$');
        expect(first.userAgent, matches(pattern));
        expect(second.userAgent, matches(pattern));
        expect(first.userAgent, isNot(second.userAgent));
        expect(createClient(async).userAgent, endsWith(' MangaTrack/1.2.3'));
      });
    });

    test('rotates after 30 min in background and restarts the screen', () {
      fakeAsync((async) {
        final client = createClient(async, sessionNonce: true);
        setState(client, AppLifecycleState.resumed);
        client.screen('/library');
        async.flushMicrotasks();
        final firstAgent = client.userAgent;

        setState(client, AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 29));
        setState(client, AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(client.userAgent, firstAgent);
        expect(broker.requestsTo('/visit'), hasLength(1));

        setState(client, AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 31));
        setState(client, AppLifecycleState.resumed);
        async.flushMicrotasks();
        final secondAgent = client.userAgent;
        expect(secondAgent, isNot(firstAgent));

        final visits = broker.bodies('/visit');
        expect(visits, hasLength(2));
        expect(visits.last['page'], '/library');
        expect(visits.last['referrer'], 'self');
        expect(visits.last['userAgent'], secondAgent);
        expect(
            broker.bodies('/keep_alive').last, containsPair('instant', true));
        expect(
          broker.bodies('/keep_alive').last['userAgent'],
          secondAgent,
        );
      });
    });

    test('rotates even when trackLifecycle is false', () {
      fakeAsync((async) {
        final client = createClient(
          async,
          sessionNonce: true,
          trackLifecycle: false,
        );
        final firstAgent = client.userAgent;
        setState(client, AppLifecycleState.resumed);
        setState(client, AppLifecycleState.paused);
        async.elapse(const Duration(hours: 1));
        setState(client, AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(client.userAgent, isNot(firstAgent));
        expect(broker.requestsTo('/keep_alive'), isEmpty);
      });
    });
  });

  test('the user agent waits for a known screen size before freezing', () {
    fakeAsync((async) {
      var device = const DeviceSnapshot(platform: TargetPlatform.iOS);
      LitlyxClient? client;
      LitlyxClient.create(
        LitlyxConfig(projectId: 'pid', trackLifecycle: false),
        httpClient: broker.client,
        store: MemoryStore(),
        device: () => device,
        binding: binding,
      ).then((created) => client = created);
      async.flushMicrotasks();
      addTearDown(() => client!.dispose());

      expect(client!.userAgent, contains('(iPhone;'));
      device = const DeviceSnapshot(
        platform: TargetPlatform.iOS,
        shortestSide: 1024,
      );
      expect(client!.userAgent, contains('(iPad;'));
      device = const DeviceSnapshot(
        platform: TargetPlatform.iOS,
        shortestSide: 390,
      );
      expect(client!.userAgent, contains('(iPad;'), reason: 'frozen');
    });
  });
}
