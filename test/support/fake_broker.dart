import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for the Litlyx broker, built on [MockClient].
class FakeBroker {
  /// Every request received, in order.
  final List<http.Request> requests = <http.Request>[];

  /// Status code returned when [statusFor] is null.
  int status = 200;

  /// Per-request status code (overrides [status]).
  int Function(http.Request request)? statusFor;

  /// When true, requests fail with a network error.
  bool offline = false;

  /// When true, requests never complete (to trigger the client timeout).
  bool hang = false;

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) {
    requests.add(request);
    if (offline) {
      return Future<http.Response>.error(
        http.ClientException('offline', request.url),
      );
    }
    if (hang) return Completer<http.Response>().future;
    return Future<http.Response>.value(
      http.Response('', statusFor?.call(request) ?? status),
    );
  }

  /// Requests sent to [path] (`/visit`, `/event`, `/keep_alive`).
  List<http.Request> requestsTo(String path) =>
      requests.where((request) => request.url.path == path).toList();

  /// Decoded JSON bodies sent to [path].
  List<Map<String, Object?>> bodies(String path) =>
      requestsTo(path).map(decode).toList();

  /// Decodes the JSON body of [request].
  static Map<String, Object?> decode(http.Request request) =>
      jsonDecode(request.body) as Map<String, Object?>;
}
