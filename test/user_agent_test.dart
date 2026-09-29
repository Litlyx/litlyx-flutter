import 'dart:math';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litlyx_flutter/src/user_agent.dart';

const String iosVersion = 'Version 18.1 (Build 22B83)';
const String androidKernel =
    'Linux 5.15.110-android14-11-gabc1234 #1 SMP PREEMPT Mon Jan 1 2024';

/// A subset of the case-sensitive patterns of the Litlyx broker's bot filter
/// (producer/src/controller.ts), focused on HTTP libraries and on words that
/// an app name or a random token could produce.
const List<String> brokerBotPatterns = <String>[
  r'Googlebot\/',
  'bingbot',
  '[wW]get',
  'Python-urllib',
  'python-requests',
  'aiohttp',
  'httpx',
  'libwww-perl',
  'httpunit',
  'Go-http-client',
  'okhttp',
  'HttpUrlConnection',
  '^Apache-HttpClient',
  'axios',
  'node-fetch',
  r'Fetch\/',
  '^curl',
  'HeadlessChrome',
  'PhantomJS',
  'Jetty',
  'http_get',
  r'AHC\/',
  'WhatsApp',
  'Viber',
  'Synapse',
  'Sonic',
  'speedy',
  'fluffy',
  'Trove',
  'Yeti',
  'Genieo',
  'Feedly',
  'Fever',
  'Mastodon',
  'NextCloud',
  r'(^| )sentry\/',
  r'Buck\/',
  r'NING\/',
  r'Daum\/',
  r'YaK\/',
  r'^BW\/',
  r'(^| )PTST\/',
  'Scrapy',
  'Applebot',
  'facebookexternalhit',
  'Chrome-Lighthouse',
];

/// Every platform and form factor the SDK can report.
const List<DeviceSnapshot> allDevices = <DeviceSnapshot>[
  DeviceSnapshot(
    platform: TargetPlatform.iOS,
    operatingSystemVersion: iosVersion,
    shortestSide: 393,
  ),
  DeviceSnapshot(
    platform: TargetPlatform.iOS,
    operatingSystemVersion: iosVersion,
    shortestSide: 820,
  ),
  DeviceSnapshot(platform: TargetPlatform.iOS),
  DeviceSnapshot(
    platform: TargetPlatform.android,
    operatingSystemVersion: androidKernel,
    shortestSide: 411,
  ),
  DeviceSnapshot(
    platform: TargetPlatform.android,
    operatingSystemVersion: androidKernel,
    shortestSide: 800,
  ),
  DeviceSnapshot(
    platform: TargetPlatform.android,
    operatingSystemVersion: 'Linux 4.14.190-perf-g1234 #1 SMP PREEMPT',
  ),
  DeviceSnapshot(
    platform: TargetPlatform.macOS,
    operatingSystemVersion: 'Version 14.5 (Build 23F79)',
  ),
  DeviceSnapshot(platform: TargetPlatform.windows),
  DeviceSnapshot(platform: TargetPlatform.linux),
  DeviceSnapshot(platform: TargetPlatform.fuchsia),
  DeviceSnapshot(platform: TargetPlatform.android, isWeb: true),
  DeviceSnapshot(
    platform: TargetPlatform.iOS,
    isWeb: true,
    browserUserAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
        'Mobile/15E148 Safari/604.1',
  ),
];

String build(DeviceSnapshot device) =>
    buildUserAgent(device, appName: 'MangaTrack', appVersion: '1.2.3');

void main() {
  group('buildUserAgent', () {
    test('iPhone', () {
      expect(
        build(allDevices[0]),
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 '
        'MangaTrack/1.2.3',
      );
    });

    test('iPad (shortest side >= 600)', () {
      expect(
        build(allDevices[1]),
        'Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 '
        'MangaTrack/1.2.3',
      );
    });

    test('iOS with unknown version and screen falls back to an iPhone', () {
      expect(build(allDevices[2]), startsWith('Mozilla/5.0 (iPhone; CPU '));
      expect(build(allDevices[2]), contains(' OS 17_0 like Mac OS X'));
    });

    test('Android phone', () {
      expect(
        build(allDevices[3]),
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 '
        'MangaTrack/1.2.3',
      );
    });

    test('Android tablet drops "Mobile"', () {
      final ua = build(allDevices[4]);
      expect(
        ua,
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 MangaTrack/1.2.3',
      );
      expect(ua, isNot(contains('Mobile')));
    });

    test('Android without a versioned kernel omits the version', () {
      expect(build(allDevices[5]), startsWith('Mozilla/5.0 (Linux; Android; '));
    });

    test('desktop platforms', () {
      expect(
        build(allDevices[6]),
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) MangaTrack/1.2.3',
      );
      expect(build(allDevices[7]), startsWith('Mozilla/5.0 (Windows NT 10.0;'));
      expect(
          build(allDevices[8]), startsWith('Mozilla/5.0 (X11; Linux x86_64)'));
    });

    test('web uses the browser user agent, or a browser-like fallback', () {
      expect(
          build(allDevices[10]), '$fallbackBrowserUserAgent MangaTrack/1.2.3');
      expect(
        build(allDevices[11]),
        '${allDevices[11].browserUserAgent} MangaTrack/1.2.3',
      );
    });

    test('app token is optional', () {
      final device = allDevices[0];
      expect(buildUserAgent(device), endsWith('Mobile/15E148'));
      expect(buildUserAgent(device, appName: 'Manga'), endsWith(' Manga'));
      expect(buildUserAgent(device, appVersion: '1.0'), endsWith('15E148'));
    });
  });

  group('sanitizing', () {
    test('appName keeps only [A-Za-z0-9]', () {
      expect(sanitizeAppName('Manga Track! (β)'), 'MangaTrack');
      expect(sanitizeAppName('My App/2.0 (evil)'), 'MyApp20evil');
      expect(sanitizeAppName(' ?! '), isNull);
      expect(sanitizeAppName(null), isNull);
      expect(sanitizeAppName('a' * 80), hasLength(50));
    });

    test('appVersion drops build metadata and unsafe characters', () {
      expect(sanitizeAppVersion('1.2.3+45'), '1.2.3');
      expect(sanitizeAppVersion('2.0.0-beta.1'), '2.0.0-beta.1');
      expect(sanitizeAppVersion('1.0; rm -rf /'), '1.0rm-rf');
      expect(sanitizeAppVersion('+45'), isNull);
      expect(sanitizeAppVersion('9' * 40), hasLength(20));
    });

    test('a hostile app name cannot break the user agent', () {
      final ua = buildUserAgent(
        allDevices[0],
        appName: 'x) Googlebot/2.1 (',
        appVersion: '1 (compatible)',
      );
      expect(ua, endsWith(' xGooglebot21/1compatible'));
      expect(ua.split(' ').last, matches(RegExp(r'^[A-Za-z0-9]+/[\w.\-]+$')));
    });
  });

  group('OS versions', () {
    test('Apple versions use underscores', () {
      expect(appleOsVersion(iosVersion), '18_1');
      expect(appleOsVersion('Version 17.4.1 (Build 21E236)'), '17_4_1');
      expect(appleOsVersion('unknown'), isNull);
      expect(appleOsVersion(null), isNull);
    });

    test('Android release comes from the GKI kernel tag', () {
      expect(androidVersion(androidKernel), '14');
      expect(androidVersion('Linux 5.10.198-android12-9-00085-g2c7d'), '12');
      expect(androidVersion('Linux 4.19.157-perf+ #1 SMP PREEMPT'), isNull);
      expect(androidVersion(null), isNull);
    });
  });

  group('bot filter safety', () {
    test('no generated user agent contains a bot-like word', () {
      for (final device in allDevices) {
        for (final ua in <String>[
          build(device),
          withSessionNonce(build(device), 'abc123'),
          buildUserAgent(device,
              appName: 'Manga Tracker', appVersion: '0.0.4+13'),
        ]) {
          final lower = ua.toLowerCase();
          for (final word in <String>[
            'bot',
            'crawl',
            'spider',
            'headless',
            'curl',
            'http',
            'dart',
          ]) {
            expect(lower, isNot(contains(word)), reason: ua);
          }
          expect(containsBotLikeWord(ua), isFalse, reason: ua);
          for (final pattern in brokerBotPatterns) {
            expect(
              RegExp(pattern).hasMatch(ua),
              isFalse,
              reason: '"$pattern" matches "$ua"',
            );
          }
        }
      }
    });

    test('session nonces are 6 hex characters and never spell a bot word', () {
      final random = Random(42);
      final base = build(allDevices[0]);
      for (var i = 0; i < 2000; i++) {
        final nonce = generateSessionNonce(random);
        expect(nonce, matches(RegExp(r'^[0-9a-f]{6}$')));
        final ua = withSessionNonce(base, nonce);
        expect(ua, '$base s/$nonce');
        expect(containsBotLikeWord(ua), isFalse, reason: ua);
      }
    });

    test('containsBotLikeWord flags typical client libraries', () {
      expect(containsBotLikeWord('Dart/3.5 (dart:io)'), isTrue);
      expect(containsBotLikeWord('Mozilla/5.0 HeadlessChrome/120'), isTrue);
      expect(containsBotLikeWord('curl/8.4.0'), isTrue);
      expect(containsBotLikeWord(build(allDevices[3])), isFalse);
    });
  });

  group('screen size', () {
    testWidgets('prefers the physical display, then the first view', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      final dispatcher = tester.binding.platformDispatcher;

      tester.view.display.size = const Size(2048, 2732);
      tester.view.display.devicePixelRatio = 2;
      expect(logicalShortestSide(dispatcher), 1024);

      tester.view.display.size = Size.zero;
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      expect(logicalShortestSide(dispatcher), 393);

      tester.view.physicalSize = Size.zero;
      expect(logicalShortestSide(dispatcher), isNull);
    });

    test('tablet threshold and pending size', () {
      expect(allDevices[0].isTablet, isFalse);
      expect(allDevices[1].isTablet, isTrue);
      expect(allDevices[2].isScreenSizePending, isTrue);
      expect(allDevices[6].isScreenSizePending, isFalse);
      expect(allDevices[10].isScreenSizePending, isFalse);
    });

    test('DeviceSnapshot.current reads the host platform', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final device = DeviceSnapshot.current();
      expect(device.platform, defaultTargetPlatform);
      expect(device.isWeb, kIsWeb);
      expect(device.operatingSystemVersion, isNotEmpty);
    });
  });
}
