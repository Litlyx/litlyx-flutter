import 'package:flutter_test/flutter_test.dart';
import 'package:litlyx_flutter/src/config.dart';
import 'package:litlyx_flutter/src/transport.dart';

import 'support/fake_broker.dart';

void main() {
  group('LitlyxConfig', () {
    test('defaults to the hosted broker', () {
      final config = LitlyxConfig(projectId: 'pid');
      expect(config.endpoint('/visit').toString(),
          'https://broker.litlyx.com/visit');
      expect(config.website, 'flutter-app');
      expect(config.maxQueueSize, 500);
    });

    test('self-hosted endpoints', () {
      expect(
        LitlyxConfig(projectId: 'p', host: 'stats.example.com', port: 8443)
            .endpoint('/event')
            .toString(),
        'https://stats.example.com:8443/event',
      );
      expect(
        LitlyxConfig(
                projectId: 'p', host: '10.0.2.2', port: 3999, secure: false)
            .endpoint('/keep_alive')
            .toString(),
        'http://10.0.2.2:3999/keep_alive',
      );
    });

    test('normalizes host, port, website and queue size', () {
      expect(LitlyxConfig.normalizeHost('https://stats.example.com/'),
          'stats.example.com');
      expect(LitlyxConfig.normalizeHost(' stats.example.com:3000/x '),
          'stats.example.com');
      expect(LitlyxConfig.normalizeHost(''), LitlyxConfig.defaultHost);
      expect(LitlyxConfig(projectId: 'p', port: 0).port, 443);
      expect(LitlyxConfig(projectId: 'p', port: 70000, secure: false).port, 80);
      expect(
          LitlyxConfig(projectId: 'p', website: '  ').website, 'flutter-app');
      expect(
          LitlyxConfig(projectId: 'p', website: ' io.app ').website, 'io.app');
      expect(LitlyxConfig(projectId: 'p', maxQueueSize: 0).maxQueueSize, 1);
    });
  });

  group('LitlyxTransport', () {
    late FakeBroker broker;
    setUp(() => broker = FakeBroker());

    LitlyxTransport transport({bool? header, void Function(String)? log}) =>
        LitlyxTransport(
          config: LitlyxConfig(projectId: 'pid'),
          client: broker.client,
          sendUserAgentHeader: header,
          log: log,
        );

    test('posts JSON with the body user agent as User-Agent header', () async {
      final outcome = await transport(header: true).post(
        '/event',
        <String, Object?>{'pid': 'pid', 'name': 'x', 'userAgent': 'UA/1'},
      );
      expect(outcome, SendOutcome.success);
      final request = broker.requests.single;
      expect(request.headers['User-Agent'], 'UA/1');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(FakeBroker.decode(request), <String, Object?>{
        'pid': 'pid',
        'name': 'x',
        'userAgent': 'UA/1',
      });
    });

    test('can skip the User-Agent header (browsers forbid it)', () async {
      await transport(header: false).post(
        '/event',
        <String, Object?>{'pid': 'pid', 'name': 'x', 'userAgent': 'UA/1'},
      );
      expect(broker.requests.single.headers.containsKey('User-Agent'), isFalse);
    });

    test('network errors are retried, bad bodies are dropped', () async {
      broker.offline = true;
      expect(
        await transport().post('/event', <String, Object?>{'pid': 'pid'}),
        SendOutcome.retry,
      );
      expect(
        await transport().post('/event', <String, Object?>{'n': double.nan}),
        SendOutcome.drop,
      );
    });

    test('debug logging explains rejections', () async {
      final logs = <String>[];
      broker.status = 400;
      await transport(log: logs.add).post('/visit', <String, Object?>{});
      expect(logs.first, startsWith('-> POST https://broker.litlyx.com/visit'));
      expect(logs.last, contains('domain whitelist'));
    });
  });
}
