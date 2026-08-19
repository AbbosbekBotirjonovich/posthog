import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:posthog/src/internal/posthog_retry_policy.dart';

/// Jitter'ni nolga tushiruvchi Random — kechikishlarni aniq tekshirish uchun.
class _ZeroRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.0;

  @override
  int nextInt(int max) => 0;
}

/// Jitter'ni maksimumga chiqaruvchi Random.
class _MaxRandom implements Random {
  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1.0;

  @override
  int nextInt(int max) => max - 1;
}

void main() {
  group('PostHogRetryPolicy', () {
    test('allows an attempt before any failure', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());

      expect(policy.canAttempt(), isTrue);
      expect(policy.failureCount, 0);
      expect(policy.remainingDelay(), Duration.zero);
    });

    test('backs off exponentially: 1, 2, 4, 8, 16 seconds', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      expect(policy.onFailure(now: now), const Duration(seconds: 1));
      expect(policy.onFailure(now: now), const Duration(seconds: 2));
      expect(policy.onFailure(now: now), const Duration(seconds: 4));
      expect(policy.onFailure(now: now), const Duration(seconds: 8));
      expect(policy.onFailure(now: now), const Duration(seconds: 16));
    });

    test('caps the delay at 30 seconds', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      for (var i = 0; i < 10; i++) {
        policy.onFailure(now: now);
      }

      expect(policy.onFailure(now: now), const Duration(seconds: 30));
    });

    test('stays capped after very many failures (no overflow)', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      // 1 << 64 int overflow'ga olib kelishi mumkin edi.
      for (var i = 0; i < 100; i++) {
        policy.onFailure(now: now);
      }

      final delay = policy.onFailure(now: now);
      expect(delay, const Duration(seconds: 30));
      expect(delay.isNegative, isFalse);
    });

    test('adds at most 25% jitter', () {
      final policy = PostHogRetryPolicy(random: _MaxRandom());
      final now = DateTime(2026, 1, 1);

      // 1s baza + 25% = 1250ms
      expect(policy.onFailure(now: now), const Duration(milliseconds: 1250));
    });

    // Server o'z yukini biladi, shuning uchun Retry-After har doim ustuvor.
    test('honors Retry-After over the computed backoff', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      expect(
        policy.onFailure(retryAfterSeconds: 120, now: now),
        const Duration(seconds: 120),
      );
    });

    test('ignores a non-positive Retry-After', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      expect(
        policy.onFailure(retryAfterSeconds: 0, now: now),
        const Duration(seconds: 1),
      );
    });

    test('blocks attempts until the delay elapses', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      policy.onFailure(now: now);

      expect(policy.canAttempt(now: now), isFalse);
      expect(
        policy.canAttempt(now: now.add(const Duration(milliseconds: 999))),
        isFalse,
      );
      expect(
        policy.canAttempt(now: now.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('reports the remaining delay', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      policy.onFailure(now: now);

      expect(
        policy.remainingDelay(now: now.add(const Duration(milliseconds: 400))),
        const Duration(milliseconds: 600),
      );
      expect(
        policy.remainingDelay(now: now.add(const Duration(seconds: 5))),
        Duration.zero,
      );
    });

    test('resets the backoff after a success', () {
      final policy = PostHogRetryPolicy(random: _ZeroRandom());
      final now = DateTime(2026, 1, 1);

      policy.onFailure(now: now);
      policy.onFailure(now: now);
      expect(policy.failureCount, 2);

      policy.onSuccess();

      expect(policy.failureCount, 0);
      expect(policy.canAttempt(now: now), isTrue);
      // Backoff nolga qaytdi: keyingi xato yana 1 soniyadan boshlanadi.
      expect(policy.onFailure(now: now), const Duration(seconds: 1));
    });
  });
}
