import 'dart:async';

import 'package:flutter/widgets.dart';

import 'config.dart';

/// Follows the app lifecycle to keep Litlyx sessions alive.
///
/// When the app comes to the foreground it calls [onResume] (with the time
/// spent in background), sends an `instant` keep-alive, which opens the
/// session without adding duration, and flushes the queue. While the app
/// stays in the foreground it sends a regular keep-alive for every
/// [interval] of accumulated foreground time; Litlyx adds one unit of
/// session duration per regular keep-alive. When the app goes to the
/// background (`hidden` or `paused`) the timer stops and the queue is
/// flushed.
class LitlyxLifecycle with WidgetsBindingObserver {
  /// Creates the observer; call [attach] to start it.
  LitlyxLifecycle({
    required this.binding,
    required this.keepAlive,
    required this.flush,
    this.onResume,
    this.sendKeepAlives = true,
    this.interval = LitlyxLimits.keepAliveInterval,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Binding the observer is registered with.
  final WidgetsBinding binding;

  /// Sends a keep-alive; `instant` is true when a foreground period starts.
  final void Function({required bool instant}) keepAlive;

  /// Flushes the offline queue.
  final void Function() flush;

  /// Called when the app enters the foreground, before the keep-alive, with
  /// the time spent in background (`null` the first time).
  final void Function(Duration? timeInBackground)? onResume;

  /// Whether keep-alives are sent and the queue flushed on lifecycle changes.
  /// When false only [onResume] is called.
  final bool sendKeepAlives;

  /// Foreground time represented by one regular keep-alive.
  final Duration interval;

  final DateTime Function() _clock;
  bool? _inForeground;
  bool _attached = false;
  DateTime? _foregroundSince;
  DateTime? _backgroundSince;
  Duration _unreported = Duration.zero;
  Timer? _timer;

  /// Whether the app is currently considered in the foreground.
  bool get isInForeground => _inForeground ?? false;

  /// Whether the periodic keep-alive timer is running.
  bool get isKeepAliveScheduled => _timer != null;

  /// Registers with [binding]. If the app is already resumed the foreground
  /// period starts immediately; otherwise it starts on the first `resumed`
  /// event, so background launches don't open sessions.
  void attach() {
    if (_attached) return;
    _attached = true;
    binding.addObserver(this);
    if (binding.lifecycleState == AppLifecycleState.resumed) _enterForeground();
  }

  /// Unregisters from [binding] and stops the timer.
  void detach() {
    if (!_attached) return;
    _attached = false;
    binding.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _enterForeground();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _enterBackground();
      case AppLifecycleState.inactive:
        // Transitional (system dialogs, app switcher): keep the current state.
        break;
    }
  }

  void _enterForeground() {
    if (_inForeground ?? false) return;
    _inForeground = true;
    final now = _clock();
    final since = _backgroundSince;
    _backgroundSince = null;
    onResume?.call(since == null ? null : _nonNegative(now.difference(since)));
    _foregroundSince = now;
    if (!sendKeepAlives) return;
    keepAlive(instant: true);
    flush();
    _schedule(interval - _unreported);
  }

  void _enterBackground() {
    if (!(_inForeground ?? false)) return;
    _inForeground = false;
    final now = _clock();
    _timer?.cancel();
    _timer = null;
    final since = _foregroundSince;
    if (since != null) {
      final total = _unreported + _nonNegative(now.difference(since));
      // Keep the remainder for the next foreground period (below one tick).
      _unreported = total >= interval ? Duration.zero : total;
    }
    _foregroundSince = null;
    _backgroundSince = now;
    if (sendKeepAlives) flush();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _tick);
  }

  void _tick() {
    _timer = null;
    if (!(_inForeground ?? false)) return;
    _unreported = Duration.zero;
    _foregroundSince = _clock();
    keepAlive(instant: false);
    _schedule(interval);
  }

  static Duration _nonNegative(Duration duration) =>
      duration.isNegative ? Duration.zero : duration;
}
