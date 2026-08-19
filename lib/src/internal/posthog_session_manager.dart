import 'posthog_uuid.dart';

/// Manages the session: its id, start time and rotation rules.
///
/// Differs from PostHog upstream: mirrors `PostHogSessionManager` in
/// `posthog-android`. The rules are reproduced exactly, because session replay
/// and funnel analysis depend on precisely these session boundaries.
class PostHogSessionManager {
  PostHogSessionManager({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Maximum session duration. A session running longer than this is rotated
  /// even if the user is still active.
  static const maxDuration = Duration(hours: 24);

  /// Inactivity threshold. A gap longer than this starts a new session.
  static const inactivityDuration = Duration(minutes: 30);

  String? _sessionId;
  DateTime? _startedAt;
  DateTime? _lastActivityAt;

  /// Whether the app is in the background.
  ///
  /// This changes the rotation behaviour: in the background the session is
  /// cleared rather than rotated — otherwise a background task (push, sync)
  /// would resurrect a session that had already ended.
  bool isAppInBackground = false;

  /// The current session id, if a session is active.
  String? get sessionId {
    final id = _sessionId;
    if (id == null) return null;

    final now = _now();
    if (_isIdle(now) || _isMaxExpired(now)) {
      if (isAppInBackground) {
        _clear();
        return null;
      }
      return _rotate(now);
    }
    return id;
  }

  /// When the session started.
  DateTime? get startedAt => _startedAt;

  /// Starts a session if one is not already running.
  ///
  /// Called when the app comes to the foreground.
  void startSession() {
    if (_sessionId != null) return;
    final now = _now();
    _sessionId = PostHogUuid.generate();
    _startedAt = now;
    _lastActivityAt = now;
  }

  /// Refreshes the activity timestamp; called on every `capture()`.
  ///
  /// Does nothing in the background: background events must not extend a
  /// session.
  void touchSession() {
    if (isAppInBackground) return;
    final now = _now();

    if (_sessionId == null) {
      startSession();
      return;
    }

    if (_isIdle(now) || _isMaxExpired(now)) {
      _rotate(now);
      return;
    }
    _lastActivityAt = now;
  }

  /// Sessiyani tugatadi.
  void endSession() => _clear();

  /// Sessiyani majburan yangilaydi (`reset()` chaqirilganda).
  String rotate() => _rotate(_now());

  bool _isIdle(DateTime now) {
    final last = _lastActivityAt;
    if (last == null) return true;
    return !now.isBefore(last.add(inactivityDuration));
  }

  bool _isMaxExpired(DateTime now) {
    final started = _startedAt;
    if (started == null) return true;
    return !now.isBefore(started.add(maxDuration));
  }

  String _rotate(DateTime now) {
    final id = PostHogUuid.generate();
    _sessionId = id;
    _startedAt = now;
    _lastActivityAt = now;
    return id;
  }

  void _clear() {
    _sessionId = null;
    _startedAt = null;
    _lastActivityAt = null;
  }
}
