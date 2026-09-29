import 'dart:js_interop';

@JS('navigator')
external _Navigator? get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external String? get userAgent;
}

/// Raw operating system version: not available on the web.
String? operatingSystemVersion() => null;

/// The browser's own user agent (`navigator.userAgent`), or `null`.
String? browserUserAgent() {
  try {
    return _navigator?.userAgent;
  } catch (_) {
    return null;
  }
}
