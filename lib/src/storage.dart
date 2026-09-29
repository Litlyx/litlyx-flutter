import 'package:shared_preferences/shared_preferences.dart';

/// Minimal key-value persistence used by the SDK. Implementations never
/// throw: failures are swallowed so that analytics can't break the app.
abstract interface class LitlyxStore {
  /// Reads a string, or `null` when missing or unreadable.
  String? getString(String key);

  /// Reads a bool, or `null` when missing or unreadable.
  bool? getBool(String key);

  /// Writes a string.
  Future<void> setString(String key, String value);

  /// Writes a bool.
  Future<void> setBool(String key, bool value);

  /// Deletes a key.
  Future<void> remove(String key);
}

/// [LitlyxStore] backed by `SharedPreferences`.
class SharedPreferencesStore implements LitlyxStore {
  /// Wraps an already loaded [SharedPreferences] instance.
  SharedPreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  /// Opens the shared preferences, falling back to a [MemoryStore] when the
  /// platform storage is unavailable.
  static Future<LitlyxStore> open() async {
    try {
      return SharedPreferencesStore(await SharedPreferences.getInstance());
    } catch (_) {
      return MemoryStore();
    }
  }

  @override
  String? getString(String key) {
    try {
      return _prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  @override
  bool? getBool(String key) {
    try {
      return _prefs.getBool(key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    try {
      await _prefs.setString(key, value);
    } catch (_) {
      // Best effort: the value stays in the in-memory cache.
    }
  }

  @override
  Future<void> setBool(String key, bool value) async {
    try {
      await _prefs.setBool(key, value);
    } catch (_) {
      // Best effort.
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await _prefs.remove(key);
    } catch (_) {
      // Best effort.
    }
  }
}

/// Volatile [LitlyxStore], used when no platform storage is available.
class MemoryStore implements LitlyxStore {
  final Map<String, Object> _values = <String, Object>{};

  @override
  String? getString(String key) {
    final value = _values[key];
    return value is String ? value : null;
  }

  @override
  bool? getBool(String key) {
    final value = _values[key];
    return value is bool ? value : null;
  }

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}
