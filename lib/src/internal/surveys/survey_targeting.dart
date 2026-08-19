import 'dart:convert';

import '../../util/logging.dart';
import '../../util/platform_io_stub.dart'
    if (dart.library.io) '../../util/platform_io_real.dart';
import '../posthog_api.dart';
import '../posthog_feature_flags.dart';
import '../posthog_preferences.dart';

/// Loads surveys and evaluates their display conditions.
///
/// Differs from PostHog upstream: survey selection lived entirely in the native
/// SDK (`PostHogSurveysIntegration`) — Dart only waited for a `showSurvey`
/// call. Here all of the logic is in Dart: loading from remote config,
/// filtering, and remembering what has been seen.
class SurveyTargeting {
  SurveyTargeting({
    required PostHogApi api,
    required PostHogPreferences preferences,
    required PostHogFeatureFlags flags,
  })  : _api = api,
        _preferences = preferences,
        _flags = flags;

  final PostHogApi _api;
  final PostHogPreferences _preferences;
  final PostHogFeatureFlags _flags;

  static const _surveysCacheKey = 'posthog.surveys';
  static const _seenPrefix = 'posthog.seenSurvey_';
  static const _lastSeenDateKey = 'posthog.lastSeenSurveyDate';

  /// Loaded surveys, as raw JSON.
  List<Map<String, dynamic>> _surveys = [];

  /// Surveys keyed by event name, checked on `capture()`.
  final Map<String, Set<String>> _eventActivated = {};

  /// Surveys that an event has activated.
  final Set<String> _activatedByEvent = {};

  /// Loads the surveys from remote config.
  Future<void> load() async {
    try {
      final result = await _api.remoteConfig();
      if (result.success && result.body != null) {
        final decoded = jsonDecode(result.body!);
        if (decoded is Map<String, dynamic>) {
          final surveys = decoded['surveys'];
          if (surveys is List) {
            _surveys = surveys.whereType<Map>().map(Map<String, dynamic>.from).toList();
            _preferences.set(_surveysCacheKey, {'items': _surveys});
            _rebuildEventMap();
            return;
          }
        }
      }
      // Network failure: fall back to the cache.
      _restoreFromCache();
    } catch (e) {
      printIfDebug('[PostHog] could not load surveys: $e');
      _restoreFromCache();
    }
  }

  void _restoreFromCache() {
    final cached = _preferences.getMap(_surveysCacheKey);
    final items = cached?['items'];
    if (items is List) {
      _surveys = items.whereType<Map>().map(Map<String, dynamic>.from).toList();
      _rebuildEventMap();
    }
  }

  void _rebuildEventMap() {
    _eventActivated.clear();
    for (final survey in _surveys) {
      final id = survey['id'] as String?;
      if (id == null) continue;

      final conditions = survey['conditions'];
      if (conditions is! Map) continue;

      final events = conditions['events'];
      if (events is! Map) continue;

      final values = events['values'];
      if (values is! List) continue;

      for (final entry in values) {
        if (entry is Map) {
          final name = entry['name'] as String?;
          if (name != null && name.isNotEmpty) {
            _eventActivated.putIfAbsent(name, () => {}).add(id);
          }
        }
      }
    }
  }

  /// Called when an event is captured, which may activate a survey.
  void onEvent(String eventName) {
    final ids = _eventActivated[eventName];
    if (ids != null) _activatedByEvent.addAll(ids);
  }

  /// Returns the first survey eligible to be shown.
  Map<String, dynamic>? nextSurvey({DateTime? now}) {
    final current = now ?? DateTime.now();
    for (final survey in _surveys) {
      if (_matches(survey, current)) return survey;
    }
    return null;
  }

  /// Whether a survey satisfies every condition.
  ///
  /// The filter order matches `getActiveMatchingSurveys()` in
  /// `posthog-android`: cheap checks first, flag evaluation last.
  bool _matches(Map<String, dynamic> survey, DateTime now) {
    final id = survey['id'] as String?;
    if (id == null) return false;

    // 1. Active: started but not ended.
    if (survey['startDate'] == null) return false;
    if (survey['endDate'] != null) return false;

    final conditions = survey['conditions'];

    // 2. Device type.
    if (conditions is Map) {
      final deviceTypes = conditions['deviceTypes'];
      if (deviceTypes is List && deviceTypes.isNotEmpty) {
        final matchType =
            conditions['deviceTypesMatchType'] as String? ?? 'icontains';
        if (!_matchesDeviceType(deviceTypes, matchType)) return false;
      }
    }

    // 3. Already seen.
    final canRepeat = _canActivateRepeatedly(survey);
    if (!canRepeat && hasSeen(id)) return false;

    // 4. Wait period.
    if (conditions is Map) {
      final waitDays = conditions['seenSurveyWaitPeriodInDays'];
      if (waitDays is int && waitDays > 0) {
        final lastSeen = _preferences.getString(_lastSeenDateKey);
        if (lastSeen != null) {
          final parsed = DateTime.tryParse(lastSeen);
          if (parsed != null &&
              now.difference(parsed).inDays < waitDays) {
            return false;
          }
        }
      }
    }

    // 5. Flags — all of them must be enabled.
    for (final key in _requiredFlagKeys(survey, canRepeat)) {
      final result = _flags.getFeatureFlagResult(key);
      if (result == null || !result.enabled) return false;
    }

    // 6. Event activation.
    if (_eventActivated.values.any((ids) => ids.contains(id))) {
      if (!_activatedByEvent.contains(id)) return false;
    }

    return true;
  }

  List<String> _requiredFlagKeys(Map<String, dynamic> survey, bool canRepeat) {
    final keys = <String>[];

    void addIfPresent(Object? value) {
      if (value is String && value.isNotEmpty) keys.add(value);
    }

    addIfPresent(survey['linkedFlagKey']);
    addIfPresent(survey['targetingFlagKey']);
    // The internal targeting flag does not apply to repeatedly activatable
    // surveys — it would block them after the first display.
    if (!canRepeat) {
      addIfPresent(survey['internalTargetingFlagKey']);
    }

    final featureFlagKeys = survey['featureFlagKeys'];
    if (featureFlagKeys is List) {
      for (final entry in featureFlagKeys) {
        if (entry is Map) addIfPresent(entry['value']);
      }
    }

    return keys;
  }

  static bool _canActivateRepeatedly(Map<String, dynamic> survey) {
    final schedule = survey['schedule'];
    if (schedule == 'always') return true;

    final conditions = survey['conditions'];
    if (conditions is Map) {
      final events = conditions['events'];
      if (events is Map && events['repeatedActivation'] == true) return true;
    }
    return false;
  }

  static bool _matchesDeviceType(List<Object?> deviceTypes, String matchType) {
    final current = platformDeviceType.toLowerCase();
    final values = deviceTypes
        .whereType<String>()
        .map((e) => e.toLowerCase())
        .toList();

    switch (matchType) {
      case 'exact':
        return values.contains(current);
      case 'is_not':
        return !values.contains(current);
      case 'not_icontains':
        return !values.any((v) => current.contains(v) || v.contains(current));
      case 'icontains':
      default:
        return values.any((v) => current.contains(v) || v.contains(current));
    }
  }

  /// Whether the survey has been seen.
  bool hasSeen(String surveyId) =>
      _preferences.getBool('$_seenPrefix$surveyId') ?? false;

  /// Marks the survey as seen.
  void markSeen(String surveyId, {DateTime? now}) {
    _preferences.set('$_seenPrefix$surveyId', true);
    _preferences.set(
      _lastSeenDateKey,
      (now ?? DateTime.now()).toIso8601String(),
    );
    _activatedByEvent.remove(surveyId);
  }

  /// Barcha holatni tozalaydi (`reset()` chaqirilganda).
  void clear() {
    _surveys = [];
    _eventActivated.clear();
    _activatedByEvent.clear();
    _preferences.remove(_surveysCacheKey);
    _preferences.remove(_lastSeenDateKey);
  }
}
