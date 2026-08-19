import 'dart:convert';

import '../feature_flag_result.dart';
import '../posthog_config.dart';
import '../util/logging.dart';
import 'posthog_api.dart';
import 'posthog_identity_manager.dart';
import 'posthog_preferences.dart';

/// Loads, caches and evaluates feature flags.
///
/// Differs from PostHog upstream: in the official plugin this lived in the
/// native SDK's `PostHogFeatureFlags` class. In pure Dart the `/flags/?v=2`
/// endpoint is called directly.
class PostHogFeatureFlags {
  PostHogFeatureFlags({
    required PostHogApi api,
    required PostHogPreferences preferences,
    required PostHogIdentityManager identity,
    this.onFeatureFlagsLoaded,
  })  : _api = api,
        _preferences = preferences,
        _identity = identity {
    _restoreFromCache();
  }

  final PostHogApi _api;
  final PostHogPreferences _preferences;
  final PostHogIdentityManager _identity;

  /// Called once the flags have loaded.
  final OnFeatureFlagsCallback? onFeatureFlagsLoaded;

  static const _flagsKey = 'posthog.featureFlags';
  static const _payloadsKey = 'posthog.featureFlagPayloads';

  /// Flag values: a `bool`, or a variant name (`String`).
  final Map<String, Object> _flags = {};

  /// Bayroqlarga biriktirilgan JSON payload'lar.
  final Map<String, Object?> _payloads = {};

  /// Person properties sent when evaluating the flags.
  final Map<String, Object> personProperties = {};

  /// Guruh property'lari.
  final Map<String, Map<String, Object>> groupProperties = {};

  /// Joriy guruhlar.
  final Map<String, String> groups = {};

  /// Flags for which `$feature_flag_called` has already been sent.
  ///
  /// Sent once per flag — otherwise a frequently checked flag would generate
  /// thousands of pointless events.
  final Set<String> _calledFlags = {};

  /// In-flight load; concurrent callers share a single request.
  Future<void>? _pendingReload;

  /// Barcha ma'lum bayroqlar.
  Map<String, Object> allFlags() => Map<String, Object>.from(_flags);

  /// Returns the flag result, or `null` when the flag is unknown.
  PostHogFeatureFlagResult? getFeatureFlagResult(String key) {
    if (!_flags.containsKey(key)) return null;

    final value = _flags[key];
    if (value is String) {
      return PostHogFeatureFlagResult(
        key: key,
        enabled: true,
        variant: value,
        payload: _payloads[key],
      );
    }
    return PostHogFeatureFlagResult(
      key: key,
      enabled: value == true,
      payload: _payloads[key],
    );
  }

  /// Bayroqning JSON payload'ini qaytaradi.
  Object? getPayload(String key) => _payloads[key];

  /// `$feature_flag_called` yuborilishi kerakligini bildiradi.
  ///
  /// `true` on the first call; `false` if it was already sent.
  bool markFlagCalled(String key) => _calledFlags.add(key);

  /// Reloads the flags from the server.
  Future<void> reload() {
    final pending = _pendingReload;
    if (pending != null) return pending;

    final future = _doReload();
    _pendingReload = future;
    return future.whenComplete(() => _pendingReload = null);
  }

  Future<void> _doReload() async {
    try {
      final result = await _api.flags(
        distinctId: _identity.distinctId,
        groups: groups.isEmpty ? null : groups,
        personProperties: personProperties.isEmpty ? null : personProperties,
        groupProperties: groupProperties.isEmpty ? null : groupProperties,
      );

      if (!result.success || result.body == null) {
        // Tarmoq xatosi — cache'dagi qiymatlar kuchda qoladi.
        printIfDebug('[PostHog] could not load feature flags, using the cache');
        return;
      }

      final decoded = jsonDecode(result.body!);
      if (decoded is! Map<String, dynamic>) return;

      if (decoded['quotaLimited'] == true) {
        printIfDebug('[PostHog] feature flag quota exceeded');
        return;
      }

      _parseResponse(decoded);
      _persist();
      onFeatureFlagsLoaded?.call();
    } catch (e) {
      printIfDebug('[PostHog] error reloading feature flags: $e');
    }
  }

  void _parseResponse(Map<String, dynamic> response) {
    // In the `/flags?v=2` response, `flags` holds a full object per flag.
    final flagsField = response['flags'];
    if (flagsField is Map) {
      _flags.clear();
      _payloads.clear();
      for (final entry in flagsField.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;

        final variant = value['variant'];
        final enabled = value['enabled'] == true;

        if (variant is String && variant.isNotEmpty) {
          _flags[key] = variant;
        } else {
          _flags[key] = enabled;
        }

        final metadata = value['metadata'];
        if (metadata is Map && metadata['payload'] != null) {
          _payloads[key] = _decodePayload(metadata['payload']);
        }
      }
      return;
    }

    // Older response shape: `featureFlags` + `featureFlagPayloads`.
    final legacyFlags = response['featureFlags'];
    if (legacyFlags is Map) {
      _flags.clear();
      _payloads.clear();
      for (final entry in legacyFlags.entries) {
        final value = entry.value;
        if (value is bool || value is String) {
          _flags[entry.key.toString()] = value as Object;
        }
      }
    }

    final legacyPayloads = response['featureFlagPayloads'];
    if (legacyPayloads is Map) {
      for (final entry in legacyPayloads.entries) {
        _payloads[entry.key.toString()] = _decodePayload(entry.value);
      }
    }
  }

  /// Payloads may arrive from the server as a JSON string.
  static Object? _decodePayload(Object? value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  /// Applies bootstrap values, used until the first request completes.
  void applyBootstrap({
    Map<String, Object>? featureFlags,
    Map<String, Object?>? featureFlagPayloads,
  }) {
    if (featureFlags != null) {
      for (final entry in featureFlags.entries) {
        final value = entry.value;
        // Only bool and String are supported, as stated in the
        // `PostHogBootstrapConfig` docs.
        if (value is bool || value is String) {
          _flags[entry.key] = value;
        }
      }
    }
    if (featureFlagPayloads != null) {
      _payloads.addAll(featureFlagPayloads);
    }
  }

  /// Bayroqlarni tozalaydi (`reset()` chaqirilganda).
  void clear() {
    _flags.clear();
    _payloads.clear();
    _calledFlags.clear();
    personProperties.clear();
    groupProperties.clear();
    groups.clear();
    _preferences.remove(_flagsKey);
    _preferences.remove(_payloadsKey);
  }

  void _restoreFromCache() {
    final storedFlags = _preferences.getMap(_flagsKey);
    if (storedFlags != null) {
      for (final entry in storedFlags.entries) {
        final value = entry.value;
        if (value is bool || value is String) {
          _flags[entry.key] = value as Object;
        }
      }
    }

    final storedPayloads = _preferences.getMap(_payloadsKey);
    if (storedPayloads != null) {
      _payloads.addAll(storedPayloads);
    }
  }

  void _persist() {
    _preferences.set(_flagsKey, Map<String, Object>.from(_flags));
    _preferences.set(_payloadsKey, Map<String, Object?>.from(_payloads));
  }
}
