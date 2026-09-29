import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'lifecycle.dart';
import 'navigator_observer.dart';
import 'queue.dart';
import 'storage.dart';
import 'transport.dart';
import 'user_agent.dart';

/// Shared preferences key of the choice persisted by [Litlyx.setEnabled].
const String enabledStorageKey = 'litlyx.enabled.v1';

/// Whether the running Litlyx client logs in debug mode (used by the
/// navigator observer).
bool get litlyxDebugLogging => Litlyx._client?.config.debug ?? false;

/// A single Litlyx tracker: builds request bodies, owns the offline queue,
/// the transport and the lifecycle observer.
///
/// Apps use the static [Litlyx] facade, which manages one instance; tests
/// create instances with [LitlyxClient.create] to inject dependencies.
class LitlyxClient {
  LitlyxClient._({
    required this.config,
    required LitlyxStore store,
    required http.Client httpClient,
    required bool ownsHttpClient,
    required DeviceSnapshot Function() device,
    required DateTime Function() clock,
    required math.Random random,
    required bool enabled,
  })  : _store = store,
        _httpClient = httpClient,
        _ownsHttpClient = ownsHttpClient,
        _device = device,
        _clock = clock,
        _random = random,
        _enabled = enabled {
    _transport = LitlyxTransport(
      config: config,
      client: httpClient,
      log: config.debug ? _log : null,
    );
    _queue = RequestQueue(
      store: store,
      send: _transport.post,
      maxSize: config.maxQueueSize,
      clock: clock,
      random: random,
      log: _log,
    );
  }

  /// Creates and starts a client.
  ///
  /// The tracking choice persisted by [setEnabled] wins over [enabled].
  /// Every dependency can be injected: [httpClient] (closed on [dispose] only
  /// when created here), [store] (shared preferences by default), [device]
  /// (user agent inputs), [clock], [random] and [binding].
  static Future<LitlyxClient> create(
    LitlyxConfig config, {
    bool enabled = true,
    http.Client? httpClient,
    LitlyxStore? store,
    DeviceSnapshot Function()? device,
    DateTime Function()? clock,
    math.Random? random,
    WidgetsBinding? binding,
  }) async {
    final resolvedBinding =
        binding ?? WidgetsFlutterBinding.ensureInitialized();
    final resolvedStore = store ?? await SharedPreferencesStore.open();
    final client = LitlyxClient._(
      config: config,
      store: resolvedStore,
      httpClient: httpClient ?? http.Client(),
      ownsHttpClient: httpClient == null,
      device:
          device ?? () => _currentDevice(resolvedBinding.platformDispatcher),
      clock: clock ?? DateTime.now,
      random: random ?? _defaultRandom(),
      enabled: resolvedStore.getBool(enabledStorageKey) ?? enabled,
    );
    client._start(resolvedBinding);
    return client;
  }

  /// Configuration of this client.
  final LitlyxConfig config;

  final LitlyxStore _store;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final DeviceSnapshot Function() _device;
  final DateTime Function() _clock;
  final math.Random _random;
  late final LitlyxTransport _transport;
  late final RequestQueue _queue;
  LitlyxLifecycle? _lifecycle;

  bool _enabled;
  bool _disposed = false;
  String? _lastPage;
  String? _nonce;
  String? _baseUserAgent;

  /// Whether requests are sent.
  bool get isEnabled => _enabled;

  /// The offline queue.
  @visibleForTesting
  RequestQueue get queue => _queue;

  /// The lifecycle observer, when [LitlyxConfig.trackLifecycle] or
  /// [LitlyxConfig.sessionNonce] is on.
  @visibleForTesting
  LitlyxLifecycle? get lifecycle => _lifecycle;

  /// User agent sent in every body and as the `User-Agent` header, including
  /// the session nonce when enabled.
  String get userAgent {
    var base = _baseUserAgent;
    if (base == null) {
      final device = _device();
      base = buildUserAgent(
        device,
        appName: config.appName,
        appVersion: config.appVersion,
      );
      // Before the first frame the screen size can be unknown; don't freeze a
      // phone user agent on a tablet.
      if (!device.isScreenSizePending) _baseUserAgent = base;
    }
    final nonce = _nonce;
    return nonce == null ? base : withSessionNonce(base, nonce);
  }

  void _start(WidgetsBinding binding) {
    if (config.sessionNonce) _nonce = generateSessionNonce(_random);
    _queue.load();
    if (_queue.length > 0) {
      // Deliver what a previous run left, or drop it if tracking is off.
      unawaited(_enabled ? _queue.flush() : _queue.clear());
    }
    if (config.trackLifecycle || config.sessionNonce) {
      _lifecycle = LitlyxLifecycle(
        binding: binding,
        keepAlive: _sendKeepAlive,
        flush: () => unawaited(flush()),
        onResume: _onResume,
        sendKeepAlives: config.trackLifecycle,
        clock: _clock,
      )..attach();
    }
    if (config.debug) {
      final ua = userAgent;
      _log('initialized: project ${config.projectId}, endpoint '
          '${config.endpoint('')}, website "${config.website}", '
          '${_enabled ? 'enabled' : 'disabled'}, user agent "$ua"');
      if (config.website == LitlyxConfig.defaultWebsite) {
        _log('`website` is "${LitlyxConfig.defaultWebsite}"; pass your bundle '
            'id and add it to the domain whitelist if the project uses one');
      }
      if (containsBotLikeWord(ua)) {
        _log('warning: the user agent contains a bot-like word '
            '(${botLikeWords.join(', ')}); bot blocking may reject it');
      }
    }
  }

  /// Queues a custom event. See [Litlyx.event].
  void event(String name, {Map<String, Object>? metadata}) {
    if (_disposed) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _log('ignored an event with an empty name');
      return;
    }
    if (!_enabled) {
      _log('tracking disabled: event "$trimmed" not sent');
      return;
    }
    final values = sanitizeMetadata(metadata, log: _log);
    _queue.add('/event', <String, Object?>{
      'pid': config.projectId,
      'name': truncate(trimmed),
      if (values != null) 'metadata': jsonEncode(values),
      'website': config.website,
      'userAgent': userAgent,
    });
  }

  /// Queues a screen view. See [Litlyx.screen].
  void screen(String page, {String? referrer, Map<String, String>? utm}) {
    if (_disposed) return;
    final path = normalizePage(page);
    if (path == null) {
      _log('ignored a screen view with an empty page');
      return;
    }
    final previous = _lastPage;
    _lastPage = path;
    if (!_enabled) {
      _log('tracking disabled: screen "$path" not sent');
      return;
    }
    final explicitReferrer = referrer?.trim() ?? '';
    _queue.add('/visit', <String, Object?>{
      'pid': config.projectId,
      'website': config.website,
      'page': path,
      'referrer': explicitReferrer.isNotEmpty
          ? truncate(explicitReferrer)
          : previous ?? 'self',
      'userAgent': userAgent,
      ...normalizeUtm(utm),
    });
  }

  /// Enables or disables tracking and persists the choice. Disabling
  /// clears the offline queue.
  Future<void> setEnabled(bool enabled) async {
    if (_disposed) return;
    _enabled = enabled;
    _log(enabled ? 'tracking enabled' : 'tracking disabled, queue cleared');
    final persisted = _store.setBool(enabledStorageKey, enabled);
    if (!enabled) await _queue.clear();
    await persisted;
  }

  /// Sends the queued requests now. See [Litlyx.flush].
  Future<void> flush() async {
    if (_disposed || !_enabled) return;
    await _queue.flush();
  }

  /// Stops timers and observers and closes the HTTP client it created.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.detach();
    _queue.dispose();
    if (_ownsHttpClient) _httpClient.close();
  }

  void _sendKeepAlive({required bool instant}) {
    if (_disposed || !_enabled) return;
    unawaited(
      _transport.post('/keep_alive', <String, Object?>{
        'pid': config.projectId,
        'website': config.website,
        'userAgent': userAgent,
        'instant': instant,
      }),
    );
  }

  void _onResume(Duration? timeInBackground) {
    if (!config.sessionNonce || timeInBackground == null) return;
    if (timeInBackground < LitlyxLimits.sessionNonceIdle) return;
    _nonce = generateSessionNonce(_random);
    _log('new session after ${timeInBackground.inMinutes} min in background');
    // Start the new session on the screen the user returns to.
    final page = _lastPage;
    _lastPage = null;
    if (page != null) screen(page);
  }

  void _log(String message) {
    if (config.debug) debugPrint('[litlyx] $message');
  }

  static DeviceSnapshot _currentDevice(PlatformDispatcher dispatcher) {
    try {
      return DeviceSnapshot.current(dispatcher);
    } catch (_) {
      return DeviceSnapshot(platform: defaultTargetPlatform, isWeb: kIsWeb);
    }
  }

  static math.Random _defaultRandom() {
    try {
      return math.Random.secure();
    } catch (_) {
      return math.Random();
    }
  }
}

/// Cookie-free, privacy-friendly analytics for Flutter apps with
/// [Litlyx](https://litlyx.com).
///
/// Call [init] once, as early as possible, then track screens with
/// [LitlyxNavigatorObserver] or [screen] and custom events with [event]:
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Litlyx.init('YOUR_PROJECT_ID', website: 'com.example.app');
///   runApp(const MyApp());
/// }
///
/// // Anywhere in the app:
/// Litlyx.event('purchase', metadata: {'plan': 'yearly', 'price': 29.99});
/// ```
///
/// Every method is safe to call at any time: calls made before [init]
/// completes are buffered, requests are queued offline and retried, and
/// nothing ever throws to the caller (in debug builds, assertions flag
/// invalid arguments).
abstract final class Litlyx {
  static LitlyxClient? _client;
  static Future<void>? _initializing;
  static final List<void Function(LitlyxClient client)> _pending =
      <void Function(LitlyxClient client)>[];
  static bool? _pendingEnabled;
  static DateTime Function()? _testClock;
  static int _generation = 0;

  /// Starts Litlyx for the project [projectId] (Litlyx dashboard, project
  /// settings).
  ///
  /// Awaiting is optional: calls made before initialization completes are
  /// buffered (up to 100) and sent afterwards. Calling [init] again has no
  /// effect. It calls `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// * [host], [port] and [secure] locate the broker; change them only when
  ///   self-hosting Litlyx (`host` is a bare host name, without scheme).
  /// * [website] is sent as the `website` field, typically the app bundle id
  ///   such as `com.example.app` (defaults to `flutter-app`). If the project
  ///   has a domain whitelist, the value must match one of its entries or
  ///   Litlyx rejects every request.
  /// * [appName] and [appVersion] are appended to the user agent as
  ///   `AppName/1.2.3`. The name keeps only `[A-Za-z0-9]` and must not
  ///   contain bot-like words, which bot blocking would reject.
  /// * [debug] logs every request, response and dropped call with
  ///   `debugPrint`.
  /// * [enabled] is the initial tracking state; a choice persisted with
  ///   [setEnabled] (for example a user opt-out) always wins.
  /// * [trackLifecycle] keeps the session alive while the app is in the
  ///   foreground (a keep-alive when resumed, then one per minute) and
  ///   flushes the queue on resume and pause.
  /// * [sessionNonce] appends ` s/<random>` to the user agent, renewed at
  ///   every cold start and after 30 minutes in background. Litlyx derives
  ///   sessions from IP address and user agent, so users of the same device
  ///   model behind one network (carrier NAT, office Wi-Fi) are otherwise
  ///   merged; the nonce separates them, at the cost of counting every new
  ///   session as a new unique visitor.
  /// * [maxQueueSize] caps the offline queue (the oldest requests are
  ///   dropped first).
  /// * [client] replaces the HTTP client, for tests.
  static Future<void> init(
    String projectId, {
    String host = LitlyxConfig.defaultHost,
    int port = 443,
    bool secure = true,
    String? website,
    String? appName,
    String? appVersion,
    bool debug = false,
    bool enabled = true,
    bool trackLifecycle = true,
    bool sessionNonce = false,
    int maxQueueSize = 500,
    http.Client? client,
  }) {
    final running = _initializing;
    if (running != null) {
      if (debug) debugPrint('[litlyx] init() was already called; ignored');
      return running;
    }
    assert(
      projectId.trim().isNotEmpty,
      'Litlyx.init: the project id must not be empty.',
    );
    final completer = Completer<void>();
    _initializing = completer.future;
    unawaited(
      _initialize(
        () => LitlyxConfig(
          projectId: projectId.trim(),
          host: host,
          port: port,
          secure: secure,
          website: website,
          appName: appName,
          appVersion: appVersion,
          debug: debug,
          trackLifecycle: trackLifecycle,
          sessionNonce: sessionNonce,
          maxQueueSize: maxQueueSize,
        ),
        enabled: enabled,
        httpClient: client,
        debug: debug,
      ).whenComplete(completer.complete),
    );
    return completer.future;
  }

  static Future<void> _initialize(
    LitlyxConfig Function() buildConfig, {
    required bool enabled,
    required http.Client? httpClient,
    required bool debug,
  }) async {
    final generation = _generation;
    try {
      final instance = await LitlyxClient.create(
        buildConfig(),
        enabled: enabled,
        httpClient: httpClient,
        clock: _testClock,
      );
      if (generation != _generation) {
        // resetForTesting() ran while initializing.
        await instance.dispose();
        return;
      }
      final pendingEnabled = _pendingEnabled;
      _pendingEnabled = null;
      if (pendingEnabled != null) {
        unawaited(instance.setEnabled(pendingEnabled));
      }
      _client = instance;
      final pending = List<void Function(LitlyxClient client)>.of(_pending);
      _pending.clear();
      for (final call in pending) {
        _guard(() => call(instance));
      }
    } catch (error, stackTrace) {
      if (generation == _generation) _initializing = null;
      _reportInternalError(error, stackTrace, force: debug);
    }
  }

  /// Sends the custom event [name] with optional flat [metadata].
  ///
  /// Metadata values must be `String` or `num`; up to 20 keys are kept and
  /// strings are cut to 200 characters. Never include personal data: in
  /// debug builds an assertion rejects unsupported values and keys that look
  /// like PII (`email`, `phone`, `password`, `user_id`, `token`, ...); in
  /// release builds unsupported values are dropped.
  ///
  /// ```dart
  /// Litlyx.event('chapter_read', metadata: {'genre': 'shonen', 'page': 12});
  /// ```
  ///
  /// Fire-and-forget: the event is queued and sent in the background.
  static void event(String name, {Map<String, Object>? metadata}) {
    assert(
      name.trim().isNotEmpty,
      'Litlyx.event: the event name must not be empty.',
    );
    assert(() {
      final problem = describeMetadataProblem(metadata);
      if (problem != null) {
        throw AssertionError('Litlyx.event("$name"): $problem');
      }
      return true;
    }());
    final copy = metadata == null ? null : Map<String, Object>.of(metadata);
    _dispatch((client) => client.event(name, metadata: copy));
  }

  /// Records a view of the screen [page], a path such as `/home`.
  ///
  /// A leading `/` is added when missing and query strings are removed.
  /// [referrer] defaults to the previous screen, or `self` for the first
  /// one. [utm] adds campaign parameters; keys may omit the `utm_` prefix
  /// (`{'source': 'newsletter'}`).
  ///
  /// [LitlyxNavigatorObserver] calls this for named routes.
  static void screen(
    String page, {
    String? referrer,
    Map<String, String>? utm,
  }) {
    assert(
      page.trim().isNotEmpty,
      'Litlyx.screen: the page must not be empty.',
    );
    final copy = utm == null ? null : Map<String, String>.of(utm);
    _dispatch((client) => client.screen(page, referrer: referrer, utm: copy));
  }

  /// Enables or disables tracking, for example from a consent dialog or an
  /// "anonymous statistics" switch.
  ///
  /// The choice is persisted and survives restarts, overriding the
  /// `enabled` argument of [init]. Disabling drops everything that is
  /// buffered or queued and stops all network requests.
  static Future<void> setEnabled(bool enabled) async {
    final client = _client;
    if (client == null) {
      _pendingEnabled = enabled;
      if (!enabled) _pending.clear();
      return;
    }
    try {
      await client.setEnabled(enabled);
    } catch (error, stackTrace) {
      _reportInternalError(error, stackTrace);
    }
  }

  /// Whether tracking is enabled. `false` until [init] completes, unless
  /// [setEnabled] was called before.
  static bool get isEnabled => _client?.isEnabled ?? _pendingEnabled ?? false;

  /// Tries to send every queued request now, ignoring the retry backoff.
  ///
  /// Completes when the queue is empty or a request failed (it will be
  /// retried later). Never throws.
  static Future<void> flush() async {
    try {
      final initializing = _initializing;
      if (_client == null && initializing != null) await initializing;
      await _client?.flush();
    } catch (error, stackTrace) {
      _reportInternalError(error, stackTrace);
    }
  }

  /// Disposes the current client and forgets all static state, so that
  /// [init] can run again. [clock] replaces `DateTime.now` for the next
  /// [init].
  @visibleForTesting
  static Future<void> resetForTesting({DateTime Function()? clock}) async {
    _generation++;
    final client = _client;
    _client = null;
    _initializing = null;
    _pending.clear();
    _pendingEnabled = null;
    _testClock = clock;
    await client?.dispose();
  }

  static void _dispatch(void Function(LitlyxClient client) call) {
    final client = _client;
    if (client != null) {
      _guard(() => call(client));
      return;
    }
    if (_pendingEnabled == false) return;
    if (_pending.length >= LitlyxLimits.maxPreInitCalls) _pending.removeAt(0);
    _pending.add(call);
  }

  static void _guard(void Function() body) {
    try {
      body();
    } catch (error, stackTrace) {
      _reportInternalError(error, stackTrace);
    }
  }

  static void _reportInternalError(
    Object error,
    StackTrace stackTrace, {
    bool force = false,
  }) {
    if (force || kDebugMode || litlyxDebugLogging) {
      debugPrint('[litlyx] internal error (ignored): $error\n$stackTrace');
    }
  }
}
