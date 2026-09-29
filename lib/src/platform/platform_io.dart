import 'dart:io' show Platform;

/// Raw operating system version as reported by `dart:io`, e.g.
/// `Version 18.1 (Build 22B83)` on iOS or the kernel release on Android.
String? operatingSystemVersion() {
  try {
    return Platform.operatingSystemVersion;
  } catch (_) {
    return null;
  }
}

/// The browser's own user agent: always `null` outside the web.
String? browserUserAgent() => null;
