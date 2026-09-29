import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'storage.dart';
import 'transport.dart';

/// Sends one request and reports what to do with it.
typedef SendRequest = Future<SendOutcome> Function(
  String path,
  Map<String, Object?> body,
);

/// A `/visit` or `/event` request waiting in the offline queue.
@immutable
class QueuedRequest {
  /// Creates a queued request.
  const QueuedRequest({
    required this.id,
    required this.path,
    required this.body,
    required this.timestamp,
    this.attempts = 0,
  });

  /// Unique id of the request.
  final String id;

  /// Broker endpoint, `/visit` or `/event`.
  final String path;

  /// JSON body, sent as-is.
  final Map<String, Object?> body;

  /// Creation time in milliseconds since epoch (`ts` in storage).
  final int timestamp;

  /// Failed delivery attempts so far.
  final int attempts;

  /// Copy with a different [attempts] count.
  QueuedRequest withAttempts(int attempts) => QueuedRequest(
        id: id,
        path: path,
        body: body,
        timestamp: timestamp,
        attempts: attempts,
      );

  /// Storage representation: `{id, path, body, ts, attempts}`.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'path': path,
        'body': body,
        'ts': timestamp,
        'attempts': attempts,
      };

  /// Parses [toJson] output; returns `null` for malformed entries.
  static QueuedRequest? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final path = json['path'];
    final body = json['body'];
    final timestamp = json['ts'];
    final attempts = json['attempts'];
    if (id is! String ||
        path is! String ||
        !RequestQueue.queueablePaths.contains(path) ||
        body is! Map<String, Object?> ||
        timestamp is! int) {
      return null;
    }
    return QueuedRequest(
      id: id,
      path: path,
      body: Map<String, Object?>.of(body),
      timestamp: timestamp,
      attempts: attempts is int && attempts > 0 ? attempts : 0,
    );
  }
}

/// Persisted FIFO of `/visit` and `/event` requests.
///
/// Requests are stored in shared preferences under [storageKey], sent one at
/// a time, and removed on success or on a permanent rejection (4xx other than
/// 408/429). On a temporary failure (5xx, 408, 429, timeout, no network)
/// delivery stops and is retried after [retryDelay]. The queue keeps at most
/// `maxSize` requests (the oldest are dropped first) for at most
/// [LitlyxLimits.queueMaxAge]. Delivery is at-least-once.
class RequestQueue {
  /// Creates a queue; call [load] before use.
  RequestQueue({
    required LitlyxStore store,
    required SendRequest send,
    this.maxSize = 500,
    this.maxAge = LitlyxLimits.queueMaxAge,
    DateTime Function()? clock,
    math.Random? random,
    void Function(String message)? log,
  })  : _store = store,
        _send = send,
        _clock = clock ?? DateTime.now,
        _random = random ?? math.Random(),
        _log = log ?? _silent;

  /// Shared preferences key holding the JSON-encoded queue.
  static const String storageKey = 'litlyx.queue.v1';

  /// Endpoints that are queued; keep-alives are best-effort and never queued.
  static const Set<String> queueablePaths = <String>{'/visit', '/event'};

  /// Maximum number of queued requests.
  final int maxSize;

  /// Maximum age of a queued request.
  final Duration maxAge;

  final LitlyxStore _store;
  final SendRequest _send;
  final DateTime Function() _clock;
  final math.Random _random;
  final void Function(String message) _log;

  final List<QueuedRequest> _items = <QueuedRequest>[];
  Timer? _retryTimer;
  Future<void>? _draining;
  bool _drainAgain = false;
  Future<void>? _saving;
  bool _dirty = false;
  bool _disposed = false;
  int _sequence = 0;

  static void _silent(String message) {}

  /// Snapshot of the queued requests, oldest first.
  List<QueuedRequest> get items => List<QueuedRequest>.unmodifiable(_items);

  /// Number of queued requests.
  int get length => _items.length;

  /// Whether a retry timer is pending.
  bool get isRetryScheduled => _retryTimer != null;

  /// Restores the persisted queue, discarding malformed and expired entries.
  void load() {
    final raw = _store.getString(storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List<Object?>) {
        for (final entry in decoded) {
          final request = QueuedRequest.tryParse(entry);
          if (request != null) _items.add(request);
        }
        if (_items.length != decoded.length) _dirty = true;
      } else {
        _dirty = true;
      }
    } catch (_) {
      _log('discarding an unreadable offline queue');
      _dirty = true;
    }
    _dropExpired();
    _trimToMaxSize();
    if (_items.isNotEmpty) _log('restored ${_items.length} queued request(s)');
    unawaited(_persist());
  }

  /// Queues a request and starts delivering it, unless a retry is pending.
  ///
  /// Returns `false` when the request is dropped because its encoded body is
  /// larger than [LitlyxLimits.maxBodyBytes].
  bool add(String path, Map<String, Object?> body) {
    if (_disposed) return false;
    assert(queueablePaths.contains(path), '$path is not queueable');
    final size = encodedSize(body);
    if (size > LitlyxLimits.maxBodyBytes) {
      _log('dropping $path: body is $size bytes '
          '(max ${LitlyxLimits.maxBodyBytes})');
      return false;
    }
    final now = _clock();
    _items.add(
      QueuedRequest(
        id: _nextId(now),
        path: path,
        body: body,
        timestamp: now.millisecondsSinceEpoch,
      ),
    );
    _trimToMaxSize();
    _dirty = true;
    unawaited(_persist());
    if (_retryTimer == null) unawaited(_startDrain());
    return true;
  }

  /// Sends the queued requests now, cancelling any pending retry timer.
  /// Completes when the queue is empty or delivery failed. Never throws.
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    _retryTimer?.cancel();
    _retryTimer = null;
    return _startDrain();
  }

  /// Removes every queued request, in memory and in storage.
  Future<void> clear() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _items.clear();
    _dirty = true;
    return _persist();
  }

  /// Stops the retry timer; the queue must not be used afterwards.
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _startDrain() {
    final running = _draining;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    final future = _drainLoop();
    _draining = future;
    return future;
  }

  Future<void> _drainLoop() async {
    try {
      do {
        _drainAgain = false;
        await _drainOnce();
      } while (_drainAgain &&
          !_disposed &&
          _retryTimer == null &&
          _items.isNotEmpty);
    } catch (error) {
      _log('offline queue error: $error');
    } finally {
      _draining = null;
    }
  }

  Future<void> _drainOnce() async {
    var sentSinceSave = 0;
    try {
      while (!_disposed) {
        _dropExpired();
        if (_items.isEmpty) break;
        final request = _items.first;
        final outcome = await _send(request.path, request.body);
        if (_disposed) return;
        final index = _items.indexWhere((item) => item.id == request.id);
        if (outcome == SendOutcome.retry) {
          final attempts = request.attempts + 1;
          if (index != -1) {
            _items[index] = request.withAttempts(attempts);
            _dirty = true;
          }
          if (_items.isNotEmpty) _scheduleRetry(attempts);
          return;
        }
        if (index != -1) {
          _items.removeAt(index);
          _dirty = true;
        }
        // Persist in batches while draining a long backlog.
        if (++sentSinceSave >= 10) {
          sentSinceSave = 0;
          await _persist();
        }
      }
    } finally {
      await _persist();
    }
  }

  void _scheduleRetry(int attempts) {
    _retryTimer?.cancel();
    final delay = retryDelay(attempts, _random);
    _log('delivery failed (attempt $attempts); retrying in '
        '${delay.inSeconds} s');
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_startDrain());
    });
  }

  void _dropExpired() {
    final oldest = _clock().subtract(maxAge).millisecondsSinceEpoch;
    final before = _items.length;
    _items.removeWhere((item) => item.timestamp < oldest);
    final removed = before - _items.length;
    if (removed > 0) {
      _dirty = true;
      _log('dropped $removed queued request(s) older than '
          '${maxAge.inDays} days');
    }
  }

  void _trimToMaxSize() {
    final limit = math.max(1, maxSize);
    while (_items.length > limit) {
      final dropped = _items.removeAt(0);
      _dirty = true;
      _log('queue full ($limit): dropped the oldest ${dropped.path}');
    }
  }

  Future<void> _persist() {
    if (!_dirty) return _saving ?? Future<void>.value();
    return _saving ??= _saveLoop();
  }

  Future<void> _saveLoop() async {
    try {
      while (_dirty) {
        _dirty = false;
        if (_items.isEmpty) {
          await _store.remove(storageKey);
        } else {
          final json = jsonEncode(
            _items.map((item) => item.toJson()).toList(growable: false),
          );
          await _store.setString(storageKey, json);
        }
      }
    } catch (error) {
      _log('could not persist the offline queue: $error');
    } finally {
      _saving = null;
    }
  }

  String _nextId(DateTime now) {
    _sequence = (_sequence + 1) & 0xffff;
    return '${now.microsecondsSinceEpoch.toRadixString(36)}-'
        '${_sequence.toRadixString(36)}-'
        '${_random.nextInt(0x7fffffff).toRadixString(36)}';
  }
}

/// Delay before the next delivery attempt after [attempts] failures:
/// 5 s after the first failure, doubling up to 10 min, with ±20% jitter
/// drawn from [random] (no jitter when `null`).
Duration retryDelay(int attempts, [math.Random? random]) {
  final exponent = math.min(math.max(attempts - 1, 0), 16);
  final base =
      LitlyxLimits.retryBaseDelay.inMilliseconds * math.pow(2, exponent);
  final capped = math.min(base, LitlyxLimits.retryMaxDelay.inMilliseconds);
  final jitter = random == null ? 1.0 : 0.8 + random.nextDouble() * 0.4;
  return Duration(milliseconds: (capped * jitter).round());
}

// ---------------------------------------------------------------------------
// Payload guards
// ---------------------------------------------------------------------------

/// Metadata keys that look like personal data. Litlyx is cookie-free and
/// anonymous, so e-mails, phone numbers, user ids, passwords and tokens must
/// never be sent.
final RegExp piiKeyPattern = RegExp(
  r'mail|password|passwd|phone|user[_\-]?id|token',
  caseSensitive: false,
);

/// Whether [key] looks like it holds personal data (see [piiKeyPattern]).
bool looksLikePiiKey(String key) => piiKeyPattern.hasMatch(key);

/// Describes the first developer error in [metadata] (unsupported value,
/// non-finite number, PII-like key), or returns `null` when it is valid.
/// Used by debug-mode assertions.
String? describeMetadataProblem(Map<String, Object>? metadata) {
  if (metadata == null) return null;
  for (final entry in metadata.entries) {
    final key = entry.key;
    final value = entry.value;
    if (looksLikePiiKey(key)) {
      return 'metadata key "$key" looks like personal data. Litlyx is '
          'cookie-free and anonymous: never send e-mails, phone numbers, user '
          'ids, passwords or tokens.';
    }
    if (value is! String && value is! num) {
      return 'metadata "$key" is a ${value.runtimeType}; only String and num '
          'values are supported (other values are dropped in release builds).';
    }
    if (value is double && !value.isFinite) {
      return 'metadata "$key" is $value, which cannot be encoded as JSON.';
    }
  }
  return null;
}

/// Keeps at most [LitlyxLimits.maxMetadataKeys] entries with a non-empty key
/// and a String or finite num value, truncating strings to
/// [LitlyxLimits.maxStringLength]. Returns `null` when nothing is left.
Map<String, Object>? sanitizeMetadata(
  Map<String, Object>? metadata, {
  void Function(String message)? log,
}) {
  if (metadata == null || metadata.isEmpty) return null;
  final result = <String, Object>{};
  for (final entry in metadata.entries) {
    final key = truncate(entry.key.trim());
    final value = entry.value;
    if (key.isEmpty) {
      log?.call('metadata: dropped an entry with an empty key');
      continue;
    }
    if (result.length >= LitlyxLimits.maxMetadataKeys) {
      log?.call('metadata: more than ${LitlyxLimits.maxMetadataKeys} keys, '
          'the extra keys were dropped');
      break;
    }
    if (value is String) {
      result[key] = truncate(value);
    } else if (value is num && value.isFinite) {
      result[key] = value;
    } else {
      log?.call('metadata: dropped "$key" (unsupported value '
          '${value.runtimeType})');
    }
  }
  return result.isEmpty ? null : result;
}

/// Normalizes a screen path: trims it, strips the query string and fragment,
/// adds a leading `/` and truncates it. Returns `null` for blank input.
String? normalizePage(String page) {
  var path = page.trim();
  if (path.isEmpty) return null;
  final cut = path.indexOf(RegExp('[?#]'));
  if (cut != -1) path = path.substring(0, cut);
  if (!path.startsWith('/')) path = '/$path';
  return truncate(path);
}

/// Normalizes UTM parameters to `utm_*` keys (`source` becomes `utm_source`)
/// with non-empty, truncated values; at most [LitlyxLimits.maxUtmParams].
Map<String, String> normalizeUtm(Map<String, String>? utm) {
  final result = <String, String>{};
  if (utm == null) return result;
  for (final entry in utm.entries) {
    if (result.length >= LitlyxLimits.maxUtmParams) break;
    var key =
        entry.key.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9_]'), '');
    if (!key.startsWith('utm_')) key = 'utm_$key';
    final value = entry.value.trim();
    if (key == 'utm_' || value.isEmpty) continue;
    result[truncate(key)] = truncate(value);
  }
  return result;
}

/// Truncates [value] to [maxLength] UTF-16 code units without splitting a
/// surrogate pair.
String truncate(String value, [int maxLength = LitlyxLimits.maxStringLength]) {
  if (value.length <= maxLength) return value;
  var end = maxLength;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return value.substring(0, end);
}

/// Size in bytes of [body] encoded as UTF-8 JSON (`maxBodyBytes + 1` when it
/// can't be encoded).
int encodedSize(Map<String, Object?> body) {
  try {
    return utf8.encode(jsonEncode(body)).length;
  } catch (_) {
    return LitlyxLimits.maxBodyBytes + 1;
  }
}
