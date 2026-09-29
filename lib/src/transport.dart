import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// What to do with a request after trying to send it.
enum SendOutcome {
  /// Accepted by the broker (2xx).
  success,

  /// Rejected for good (4xx other than 408/429, unexpected 3xx): don't retry.
  drop,

  /// Temporary failure (5xx, 408, 429, timeout, network error): retry later.
  retry,
}

/// Posts JSON bodies to the Litlyx broker.
class LitlyxTransport {
  /// Creates a transport for [config] using [client].
  LitlyxTransport({
    required this.config,
    required http.Client client,
    this.timeout = LitlyxLimits.requestTimeout,
    bool? sendUserAgentHeader,
    void Function(String message)? log,
  })  : _client = client,
        // Browsers refuse to override the User-Agent header.
        sendUserAgentHeader = sendUserAgentHeader ?? !kIsWeb,
        _log = log;

  /// Broker location.
  final LitlyxConfig config;

  /// Timeout of a single request.
  final Duration timeout;

  /// Whether the body's `userAgent` is also sent as the `User-Agent` header.
  final bool sendUserAgentHeader;

  final http.Client _client;
  final void Function(String message)? _log;

  /// Classifies an HTTP status code.
  static SendOutcome outcomeForStatus(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return SendOutcome.success;
    if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
      return SendOutcome.retry;
    }
    return SendOutcome.drop;
  }

  /// POSTs [body] as JSON to [path]. Never throws.
  Future<SendOutcome> post(String path, Map<String, Object?> body) async {
    final String encoded;
    final Uri uri;
    try {
      encoded = jsonEncode(body);
      uri = config.endpoint(path);
    } catch (error) {
      _log?.call('dropping $path: cannot encode the request ($error)');
      return SendOutcome.drop;
    }
    final userAgent = body['userAgent'];
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (sendUserAgentHeader && userAgent is String) 'User-Agent': userAgent,
    };
    _log?.call('-> POST $uri $encoded');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .post(uri, headers: headers, body: encoded)
          .timeout(timeout);
      final outcome = outcomeForStatus(response.statusCode);
      _log?.call(
        '<- ${response.statusCode} $path in ${stopwatch.elapsedMilliseconds} ms'
        '${_explain(response.statusCode, outcome)}',
      );
      return outcome;
    } on TimeoutException {
      _log?.call('<- timeout $path after ${timeout.inSeconds} s (will retry)');
      return SendOutcome.retry;
    } catch (error) {
      _log?.call('<- network error on $path: $error (will retry)');
      return SendOutcome.retry;
    }
  }

  static String _explain(int statusCode, SendOutcome outcome) {
    switch (outcome) {
      case SendOutcome.success:
        return '';
      case SendOutcome.retry:
        return ' (will retry)';
      case SendOutcome.drop:
        if (statusCode == 400) {
          return ' (dropped: Litlyx refused to log it; check that `website` '
              "matches the project's domain whitelist, that the IP isn't "
              "blacklisted and that bot blocking isn't matching the user "
              'agent)';
        }
        if (statusCode >= 300 && statusCode < 400) {
          return ' (dropped: unexpected redirect, check host/port/secure)';
        }
        return ' (dropped)';
    }
  }
}
