import 'dart:math';

/// Eksponensial backoff hisoblagichi.
///
/// Mirrors the `PostHogQueue` policy in `posthog-android`: starts at 1s,
/// doubles on each failure, capped at 30s.
///
/// Two deliberate differences from PostHog upstream:
///
/// 1. **Jitter added.** In the official SDK the delay is exact. When many
///    devices come back online at once (a cell network recovering, say) they
///    all retry in the same instant and surge the server. A random 0-25% of
///    the computed delay is added.
/// 2. **The queue is never dropped.** The official SDK calls
///    `dropAllRecords()` after `maxRetries` (3), erasing the whole queue from
///    disk, which loses data during a long offline stretch. Here the queue is
///    kept and only the delay stays at its maximum; `maxQueueSize` guards
///    against unbounded growth.
class PostHogRetryPolicy {
  PostHogRetryPolicy({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const _initialDelay = Duration(seconds: 1);
  static const _maxDelay = Duration(seconds: 30);

  int _failureCount = 0;

  /// No new attempt is made before this time.
  DateTime? _pausedUntil;

  /// Number of consecutive failures.
  int get failureCount => _failureCount;

  /// Whether a request may be sent right now.
  bool canAttempt({DateTime? now}) {
    final pausedUntil = _pausedUntil;
    if (pausedUntil == null) return true;
    return !(now ?? DateTime.now()).isBefore(pausedUntil);
  }

  /// Time left before the next attempt. `Duration.zero` when not paused.
  Duration remainingDelay({DateTime? now}) {
    final pausedUntil = _pausedUntil;
    if (pausedUntil == null) return Duration.zero;
    final current = now ?? DateTime.now();
    if (!current.isBefore(pausedUntil)) return Duration.zero;
    return pausedUntil.difference(current);
  }

  /// Clears the state after a successful request.
  void onSuccess() {
    _failureCount = 0;
    _pausedUntil = null;
  }

  /// Schedules the next attempt after a failure.
  ///
  /// [retryAfterSeconds] is the server's `Retry-After` value, which always
  /// wins, because the server knows its own load.
  Duration onFailure({int? retryAfterSeconds, DateTime? now}) {
    _failureCount++;

    final Duration delay;
    if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      delay = Duration(seconds: retryAfterSeconds);
    } else {
      final exponent = _failureCount - 1;
      // Past 2^30 an int overflow is possible; it is capped anyway.
      final multiplier = exponent >= 30 ? (1 << 30) : (1 << exponent);
      final rawMillis = _initialDelay.inMilliseconds * multiplier;
      final cappedMillis = min(rawMillis, _maxDelay.inMilliseconds);
      // Jitter: 0-25% qo'shimcha.
      final jitter = (cappedMillis * 0.25 * _random.nextDouble()).round();
      delay = Duration(milliseconds: cappedMillis + jitter);
    }

    _pausedUntil = (now ?? DateTime.now()).add(delay);
    return delay;
  }

  /// Holatni boshlang'ich qiymatga qaytaradi.
  void reset() {
    _failureCount = 0;
    _pausedUntil = null;
  }
}
