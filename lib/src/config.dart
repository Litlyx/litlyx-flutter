import 'package:flutter/foundation.dart';

/// Immutable settings of a Litlyx client, built from the arguments of
/// `Litlyx.init`.
@immutable
class LitlyxConfig {
  /// Creates a configuration, normalizing [host], [port], [website] and
  /// [maxQueueSize] to safe values.
  LitlyxConfig({
    required this.projectId,
    String host = defaultHost,
    int port = 443,
    this.secure = true,
    String? website,
    this.appName,
    this.appVersion,
    this.debug = false,
    this.trackLifecycle = true,
    this.sessionNonce = false,
    int maxQueueSize = 500,
  })  : host = normalizeHost(host),
        port = (port < 1 || port > 65535) ? (secure ? 443 : 80) : port,
        website = (website == null || website.trim().isEmpty)
            ? defaultWebsite
            : website.trim(),
        maxQueueSize = maxQueueSize < 1 ? 1 : maxQueueSize;

  /// Host of the hosted Litlyx broker.
  static const String defaultHost = 'broker.litlyx.com';

  /// `website` value sent when none is configured.
  static const String defaultWebsite = 'flutter-app';

  /// Litlyx project id (the `pid` field of every request).
  final String projectId;

  /// Broker host name, without scheme or path.
  final String host;

  /// Broker TCP port.
  final int port;

  /// Whether to use `https` (true) or `http` (false).
  final bool secure;

  /// Value of the `website` field, e.g. the app bundle id. It is matched
  /// against the project's domain whitelist, if one is configured.
  final String website;

  /// Optional app name appended to the user agent.
  final String? appName;

  /// Optional app version appended to the user agent after [appName].
  final String? appVersion;

  /// Whether every request, response and dropped call is logged with
  /// `debugPrint`.
  final bool debug;

  /// Whether sessions are kept alive and the queue is flushed following the
  /// app lifecycle.
  final bool trackLifecycle;

  /// Whether a random session token is appended to the user agent.
  final bool sessionNonce;

  /// Maximum number of requests kept in the offline queue.
  final int maxQueueSize;

  /// Full URL of the broker endpoint at [path] (for example `/event`).
  Uri endpoint(String path) => Uri(
        scheme: secure ? 'https' : 'http',
        host: host,
        port: port,
        path: path,
      );

  /// Strips an accidental scheme, port or path from [host]
  /// (`https://example.com:3000/` becomes `example.com`). Use `port` and
  /// `secure` to configure the port and the scheme.
  static String normalizeHost(String host) {
    final trimmed = host.trim();
    if (trimmed.isEmpty) return defaultHost;
    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final parsed = Uri.tryParse(withScheme)?.host ?? '';
    return parsed.isEmpty ? defaultHost : parsed;
  }
}

/// Limits and timings used by the SDK internals.
abstract final class LitlyxLimits {
  /// Timeout of a single HTTP request.
  static const Duration requestTimeout = Duration(seconds: 10);

  /// Foreground time represented by one non-instant keep-alive; the Litlyx
  /// dashboard counts session duration in these units.
  static const Duration keepAliveInterval = Duration(seconds: 60);

  /// Time in background after which a new session nonce is generated.
  static const Duration sessionNonceIdle = Duration(minutes: 30);

  /// Queued requests older than this are discarded.
  static const Duration queueMaxAge = Duration(days: 7);

  /// First retry delay of the offline queue.
  static const Duration retryBaseDelay = Duration(seconds: 5);

  /// Upper bound of the retry delay of the offline queue.
  static const Duration retryMaxDelay = Duration(minutes: 10);

  /// Calls made before `Litlyx.init` completes that are kept in memory.
  static const int maxPreInitCalls = 100;

  /// Maximum number of metadata entries per event.
  static const int maxMetadataKeys = 20;

  /// Maximum length of any string sent to Litlyx.
  static const int maxStringLength = 200;

  /// Maximum number of UTM parameters per screen view.
  static const int maxUtmParams = 10;

  /// Maximum size of an encoded request body (the broker accepts 25 KB).
  static const int maxBodyBytes = 20 * 1024;
}
