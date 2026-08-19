import 'posthog_preferences.dart';
import 'posthog_uuid.dart';

/// Manages user identity: anonymous id, distinct id, identified state.
///
/// Differs from PostHog upstream: mirrors the identity part of `PostHog.kt` in
/// `posthog-android`. The logic is reproduced exactly, because the backend
/// relies on these rules to merge anonymous into identified persons.
class PostHogIdentityManager {
  PostHogIdentityManager(this._preferences);

  final PostHogPreferences _preferences;

  static const _anonymousIdKey = 'posthog.anonymousId';
  static const _distinctIdKey = 'posthog.distinctId';
  static const _isIdentifiedKey = 'posthog.isIdentified';

  /// Device identifier, sent as the `$device_id` property.
  ///
  /// Generated and persisted on first access.
  String get anonymousId {
    final stored = _preferences.getString(_anonymousIdKey);
    if (stored != null && stored.isNotEmpty) return stored;

    final generated = PostHogUuid.generate();
    _preferences.set(_anonymousIdKey, generated);
    return generated;
  }

  /// The current `distinct_id`.
  ///
  /// Equal to [anonymousId] until `identify()` is called.
  String get distinctId {
    final stored = _preferences.getString(_distinctIdKey);
    if (stored != null && stored.isNotEmpty) return stored;
    return anonymousId;
  }

  /// Whether the user has been identified.
  bool get isIdentified {
    final stored = _preferences.getBool(_isIdentifiedKey);
    if (stored != null) return stored;
    return distinctId != anonymousId;
  }

  /// Identifies the user.
  ///
  /// Returns the previous anonymous id, which must be sent as
  /// `$anon_distinct_id`, or `null` when the user was already identified under
  /// this id.
  ///
  /// The backend merges anonymous and identified persons through
  /// `$anon_distinct_id`, so it must only be sent on a genuine transition.
  String? identify(String userId) {
    final trimmed = userId.trim();
    if (trimmed.isEmpty) return null;

    final previousDistinctId = distinctId;
    final wasIdentified = isIdentified;

    _preferences.set(_distinctIdKey, trimmed);
    _preferences.set(_isIdentifiedKey, true);

    // Re-linking an already identified user could merge the wrong persons, so
    // the anonymous id is only sent when moving out of the anonymous state.
    if (wasIdentified) return null;
    if (previousDistinctId == trimmed) return null;
    return previousDistinctId;
  }

  /// Resets the identity to its initial state.
  ///
  /// When [reuseAnonymousId] is `true` the device identifier is kept, so
  /// sign-out/sign-in cycles on one device are not counted as new devices.
  void reset({bool reuseAnonymousId = false}) {
    _preferences.remove(_distinctIdKey);
    _preferences.remove(_isIdentifiedKey);
    if (!reuseAnonymousId) {
      _preferences.set(_anonymousIdKey, PostHogUuid.generate());
    }
  }

  /// Seeds the identity from bootstrap values on first launch.
  ///
  /// Never overwrites an existing identity: bootstrap only makes sense on the
  /// very first run.
  void applyBootstrap({
    required String? distinctId,
    required bool isIdentifiedId,
  }) {
    if (distinctId == null || distinctId.trim().isEmpty) return;
    if (_preferences.getString(_distinctIdKey) != null) return;
    if (_preferences.getString(_anonymousIdKey) != null) return;

    final trimmed = distinctId.trim();
    if (isIdentifiedId) {
      _preferences.set(_distinctIdKey, trimmed);
      _preferences.set(_isIdentifiedKey, true);
    } else {
      _preferences.set(_anonymousIdKey, trimmed);
    }
  }
}
