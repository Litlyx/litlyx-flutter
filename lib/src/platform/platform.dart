// Platform facts that need `dart:io` (native) or `dart:js_interop` (web).
// Conditional exports keep the package importable on every platform.
export 'platform_stub.dart'
    if (dart.library.io) 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart';
