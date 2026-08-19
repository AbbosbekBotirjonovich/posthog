import '../posthog_config.dart';
import 'context/posthog_context.dart';
import 'posthog_identity_manager.dart';
import 'posthog_session_manager.dart';

/// Builds the final property set sent with an event.
///
/// Differs from PostHog upstream: mirrors `PostHog.buildProperties()` in
/// `posthog-android`, merge order included.
class PostHogPropertyBuilder {
  PostHogPropertyBuilder({
    required PostHogContext context,
    required PostHogIdentityManager identity,
    required PostHogSessionManager session,
  })  : _context = context,
        _identity = identity,
        _session = session;

  final PostHogContext _context;
  final PostHogIdentityManager _identity;
  final PostHogSessionManager _session;

  /// Persistent properties added by the user through `register()`.
  final Map<String, Object> superProperties = {};

  /// Current feature flags, added as `$feature/<key>`.
  Map<String, Object> featureFlags = {};

  /// Current groups.
  final Map<String, String> groups = {};

  /// Builds the event's complete property set.
  ///
  /// When [appendSharedProps] is `false` the static/dynamic context is left
  /// out. That is for `$snapshot` events: they are emitted very frequently and
  /// attaching the full context to each would inflate traffic sharply. The
  /// backend does not expect it either — context is taken from the session's
  /// ordinary events.
  Future<Map<String, Object>> build({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
    String? screenName,
    PostHogPersonProfiles personProfiles = PostHogPersonProfiles.identifiedOnly,
    bool appendSharedProps = true,
    bool sendFeatureFlags = true,
  }) async {
    final result = <String, Object>{};

    if (appendSharedProps) {
      result.addAll(superProperties);
      result.addAll(await _context.staticContext());
      result.addAll(_context.dynamicContext());

      if (sendFeatureFlags && featureFlags.isNotEmpty) {
        final active = <String>[];
        for (final entry in featureFlags.entries) {
          result['\$feature/${entry.key}'] = entry.value;
          final value = entry.value;
          // Only enabled flags make the list; `false` means disabled.
          if (value == true || (value is String && value.isNotEmpty)) {
            active.add(entry.key);
          }
        }
        if (active.isNotEmpty) {
          result['\$active_feature_flags'] = active;
        }
      }

      if (groups.isNotEmpty) {
        result['\$groups'] = Map<String, String>.from(groups);
      }

      if (screenName != null && screenName.isNotEmpty) {
        result['\$screen_name'] = screenName;
      }

      result['\$is_identified'] = _identity.isIdentified;
      result['\$process_person_profile'] = _shouldProcessPerson(personProfiles);
      result['\$device_id'] = _identity.anonymousId;
    }

    // The SDK identity is always sent, `$snapshot` included.
    result.addAll(_context.sdkInfo());

    final sessionId = _session.sessionId;
    if (sessionId != null) {
      result['\$session_id'] = sessionId;
      if (!appendSharedProps) {
        // For replay events the backend expects `$window_id`, and it must
        // carry the same value as `$session_id`.
        result['\$window_id'] = sessionId;
        result['distinct_id'] = _identity.distinctId;
      }
    }

    // Caller-supplied properties come last: they may override the context,
    // which is intentional.
    if (properties != null) {
      result.addAll(properties);
    }

    if (userProperties != null && userProperties.isNotEmpty) {
      result['\$set'] = userProperties;
    }
    if (userPropertiesSetOnce != null && userPropertiesSetOnce.isNotEmpty) {
      result['\$set_once'] = userPropertiesSetOnce;
    }

    return result;
  }

  bool _shouldProcessPerson(PostHogPersonProfiles personProfiles) {
    switch (personProfiles) {
      case PostHogPersonProfiles.never:
        return false;
      case PostHogPersonProfiles.always:
        return true;
      case PostHogPersonProfiles.identifiedOnly:
        return _identity.isIdentified;
    }
  }
}
