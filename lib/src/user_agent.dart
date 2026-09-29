import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher, Size;

import 'package:flutter/foundation.dart';

import 'platform/platform.dart' as host;

/// Logical screen side (in logical pixels) from which a device is treated as
/// a tablet.
const double tabletShortestSide = 600;

/// Generic desktop Chrome user agent, used on the web when the browser's own
/// user agent can't be read.
const String fallbackBrowserUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) $_blinkEngine $_chromeVersion '
    'Safari/537.36';

/// Words that bot filters commonly match (case-insensitive). The SDK never
/// generates them; `debug` mode warns when an app name introduces one.
const List<String> botLikeWords = <String>[
  'bot',
  'crawl',
  'spider',
  'headless',
  'curl',
  'http',
  'dart',
];

const String _webKitEngine = 'AppleWebKit/605.1.15 (KHTML, like Gecko)';
const String _blinkEngine = 'AppleWebKit/537.36 (KHTML, like Gecko)';
const String _chromeVersion = 'Chrome/120.0.0.0';
const String _iosBuild = 'Mobile/15E148';
const String _nonceAlphabet = '0123456789abcdef';

/// The facts about the running device that the user agent is derived from.
@immutable
class DeviceSnapshot {
  /// Creates a snapshot from explicit values (mainly for tests).
  const DeviceSnapshot({
    required this.platform,
    this.isWeb = false,
    this.operatingSystemVersion,
    this.shortestSide,
    this.browserUserAgent,
  });

  /// Reads the current device. [dispatcher] defaults to
  /// [PlatformDispatcher.instance].
  factory DeviceSnapshot.current([PlatformDispatcher? dispatcher]) {
    return DeviceSnapshot(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
      operatingSystemVersion: host.operatingSystemVersion(),
      browserUserAgent: host.browserUserAgent(),
      shortestSide:
          logicalShortestSide(dispatcher ?? PlatformDispatcher.instance),
    );
  }

  /// The operating system family.
  final TargetPlatform platform;

  /// Whether the app runs in a browser.
  final bool isWeb;

  /// Raw OS version (`Platform.operatingSystemVersion`), if known.
  final String? operatingSystemVersion;

  /// Shortest side of the screen in logical pixels, if known.
  final double? shortestSide;

  /// `navigator.userAgent` on the web.
  final String? browserUserAgent;

  /// Whether the screen is large enough to be a tablet (iPad, Android tablet).
  bool get isTablet => (shortestSide ?? 0) >= tabletShortestSide;

  /// Whether [isTablet] matters for this platform but the screen size isn't
  /// known yet (it can be zero before the first frame).
  bool get isScreenSizePending =>
      !isWeb &&
      shortestSide == null &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
}

/// Shortest side of the screen in logical pixels, preferring the physical
/// display (stable in split screen) over the first view. Returns `null` when
/// no size is known yet.
double? logicalShortestSide(PlatformDispatcher dispatcher) {
  try {
    for (final display in dispatcher.displays) {
      final side = _logicalShortestSide(display.size, display.devicePixelRatio);
      if (side != null) return side;
    }
  } catch (_) {
    // Some embedders don't report displays.
  }
  try {
    for (final view in dispatcher.views) {
      final side =
          _logicalShortestSide(view.physicalSize, view.devicePixelRatio);
      if (side != null) return side;
    }
  } catch (_) {
    // No view yet.
  }
  return null;
}

double? _logicalShortestSide(Size physicalSize, double devicePixelRatio) {
  if (devicePixelRatio <= 0 || physicalSize.isEmpty) return null;
  return physicalSize.shortestSide / devicePixelRatio;
}

/// Builds a browser-like user agent for [device], ending with
/// `AppName/appVersion` when [appName] is given.
///
/// Litlyx derives sessions from the user agent and IP address and rejects
/// user agents that look like bots, so the result mimics a real mobile
/// browser and never contains words such as `bot`, `http` or `dart`.
String buildUserAgent(
  DeviceSnapshot device, {
  String? appName,
  String? appVersion,
}) {
  final base = _baseUserAgent(device);
  final token = appProductToken(appName, appVersion);
  return token == null ? base : '$base $token';
}

String _baseUserAgent(DeviceSnapshot device) {
  if (device.isWeb) {
    final browser = device.browserUserAgent?.trim() ?? '';
    return browser.isEmpty ? fallbackBrowserUserAgent : browser;
  }
  switch (device.platform) {
    case TargetPlatform.iOS:
      final version = appleOsVersion(device.operatingSystemVersion) ?? '17_0';
      return device.isTablet
          ? 'Mozilla/5.0 (iPad; CPU OS $version like Mac OS X) '
              '$_webKitEngine $_iosBuild'
          : 'Mozilla/5.0 (iPhone; CPU iPhone OS $version like Mac OS X) '
              '$_webKitEngine $_iosBuild';
    case TargetPlatform.android:
      final version = androidVersion(device.operatingSystemVersion);
      final os = version == null ? 'Android' : 'Android $version';
      return device.isTablet
          ? 'Mozilla/5.0 (Linux; $os) $_blinkEngine $_chromeVersion '
              'Safari/537.36'
          : 'Mozilla/5.0 (Linux; $os; Mobile) $_blinkEngine $_chromeVersion '
              'Mobile Safari/537.36';
    case TargetPlatform.macOS:
      final version =
          appleOsVersion(device.operatingSystemVersion) ?? '10_15_7';
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X $version) $_webKitEngine';
    case TargetPlatform.windows:
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) $_blinkEngine '
          '$_chromeVersion Safari/537.36';
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return 'Mozilla/5.0 (X11; Linux x86_64) $_blinkEngine $_chromeVersion '
          'Safari/537.36';
  }
}

/// Extracts an Apple OS version in user-agent form (`18_1`) from strings such
/// as `Version 18.1 (Build 22B83)`.
String? appleOsVersion(String? operatingSystemVersion) {
  if (operatingSystemVersion == null) return null;
  final match = RegExp(r'\d+(\.\d+)*').firstMatch(operatingSystemVersion);
  return match?.group(0)?.replaceAll('.', '_');
}

/// Best-effort Android release from the kernel string that
/// `Platform.operatingSystemVersion` returns on Android (for example
/// `Linux 5.15.110-android14-11-g…`). The tag names the Android generation of
/// the kernel, which can lag behind the installed release; it is missing on
/// older, non-GKI kernels, in which case `null` is returned.
String? androidVersion(String? operatingSystemVersion) {
  if (operatingSystemVersion == null) return null;
  final match = RegExp(r'android[-_ ]?(\d{1,2})\b', caseSensitive: false)
      .firstMatch(operatingSystemVersion);
  return match?.group(1);
}

/// The `AppName/version` product token, or `null` without a usable name.
String? appProductToken(String? appName, String? appVersion) {
  final name = sanitizeAppName(appName);
  if (name == null) return null;
  final version = sanitizeAppVersion(appVersion);
  return version == null ? name : '$name/$version';
}

/// Keeps only `[A-Za-z0-9]` (max 50 characters) so that the app name is a
/// valid user-agent product; `null` when nothing is left.
String? sanitizeAppName(String? appName) {
  if (appName == null) return null;
  final cleaned = appName.replaceAll(RegExp('[^A-Za-z0-9]'), '');
  if (cleaned.isEmpty) return null;
  return cleaned.length > 50 ? cleaned.substring(0, 50) : cleaned;
}

/// Drops build metadata (`1.2.3+45` becomes `1.2.3`) and keeps only
/// `[A-Za-z0-9._-]` (max 20 characters); `null` when nothing is left.
String? sanitizeAppVersion(String? appVersion) {
  if (appVersion == null) return null;
  final plus = appVersion.indexOf('+');
  final core = plus == -1 ? appVersion : appVersion.substring(0, plus);
  final cleaned = core.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  if (cleaned.isEmpty) return null;
  return cleaned.length > 20 ? cleaned.substring(0, 20) : cleaned;
}

/// Whether [userAgent] contains one of [botLikeWords] (case-insensitive).
bool containsBotLikeWord(String userAgent) {
  final lower = userAgent.toLowerCase();
  return botLikeWords.any(lower.contains);
}

/// A random 6-character session token (lowercase hex, so it can't spell a
/// bot-like word).
String generateSessionNonce(math.Random random) {
  return String.fromCharCodes(
    List<int>.generate(
      6,
      (_) => _nonceAlphabet.codeUnitAt(random.nextInt(_nonceAlphabet.length)),
    ),
  );
}

/// Appends the session token to [userAgent] as ` s/<nonce>`.
String withSessionNonce(String userAgent, String nonce) =>
    '$userAgent s/$nonce';
