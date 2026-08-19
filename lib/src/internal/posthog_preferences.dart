import 'dart:async';
import 'dart:convert';

import '../util/logging.dart';
import 'storage/preferences_file_store.dart'
    if (dart.library.js_interop) 'storage/preferences_memory_store.dart';

/// Key-value store holding the SDK's state.
///
/// Differs from PostHog upstream: in the official plugin this was the native
/// SDK's `PostHogPreferences` (Android `SharedPreferences`, iOS
/// `UserDefaults`). In pure Dart a single JSON file is used.
///
/// A dedicated file is used instead of the `shared_preferences` package
/// because the SDK's state (anonymousId, distinctId, super properties, flag
/// cache) should not share a store with the host app's own settings — that
/// risks key collisions and accidental clearing.
class PostHogPreferences {
  PostHogPreferences({
    required this.projectToken,
    PreferencesStore? store,
  }) : _store = store ?? createPreferencesStore();

  final String projectToken;
  final PreferencesStore _store;

  Map<String, Object?> _values = {};
  bool _loaded = false;

  /// Debounce timer that coalesces writes into a short window instead of
  /// hitting the disk on every change.
  Timer? _writeTimer;
  static const _writeDebounce = Duration(milliseconds: 200);

  /// Reads the persisted state. Called once from `setup()`.
  Future<void> load() async {
    if (_loaded) return;
    try {
      await _store.initialize(projectToken: projectToken);
      final content = await _store.read();
      if (content != null && content.isNotEmpty) {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          _values = Map<String, Object?>.from(decoded);
        }
      }
    } catch (e) {
      // Corrupt state: start from empty. This loses the user's identifier,
      // but the SDK keeps working.
      printIfDebug('[PostHog] could not read persisted state: $e');
      _values = {};
    }
    _loaded = true;
  }

  Object? get(String key) => _values[key];

  String? getString(String key) {
    final value = _values[key];
    return value is String ? value : null;
  }

  bool? getBool(String key) {
    final value = _values[key];
    return value is bool ? value : null;
  }

  int? getInt(String key) {
    final value = _values[key];
    return value is int ? value : null;
  }

  Map<String, Object?>? getMap(String key) {
    final value = _values[key];
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    return null;
  }

  void set(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _scheduleWrite();
  }

  void remove(String key) {
    _values.remove(key);
    _scheduleWrite();
  }

  /// Barcha kalitlarni o'chiradi.
  Future<void> clear() async {
    _values.clear();
    _writeTimer?.cancel();
    _writeTimer = null;
    try {
      await _store.write('{}');
    } catch (e) {
      printIfDebug('[PostHog] could not clear state: $e');
    }
  }

  void _scheduleWrite() {
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, () {
      unawaited(flush());
    });
  }

  /// Performs any pending write immediately.
  ///
  /// Called from `close()` — otherwise the app could exit before the last
  /// changes reach the disk.
  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    try {
      await _store.write(jsonEncode(_values));
    } catch (e) {
      printIfDebug('[PostHog] could not persist state: $e');
    }
  }
}

/// Platformaga xos saqlash.
abstract class PreferencesStore {
  Future<void> initialize({required String projectToken});

  Future<String?> read();

  Future<void> write(String content);
}
