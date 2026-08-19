import 'package:flutter_test/flutter_test.dart';
import 'package:posthog/src/internal/posthog_session_manager.dart';

void main() {
  group('PostHogSessionManager', () {
    late DateTime now;
    late PostHogSessionManager session;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      session = PostHogSessionManager(now: () => now);
    });

    test('has no session before one starts', () {
      expect(session.sessionId, isNull);
    });

    test('starts a session on demand', () {
      session.startSession();

      expect(session.sessionId, isNotNull);
      expect(session.startedAt, now);
    });

    test('keeps the same id while the user stays active', () {
      session.startSession();
      final id = session.sessionId;

      now = now.add(const Duration(minutes: 10));
      session.touchSession();

      expect(session.sessionId, id);
    });

    test('does not restart an already running session', () {
      session.startSession();
      final id = session.sessionId;

      session.startSession();

      expect(session.sessionId, id);
    });

    test('rotates after 30 minutes of inactivity', () {
      session.startSession();
      final id = session.sessionId;

      now = now.add(const Duration(minutes: 31));

      final rotated = session.sessionId;
      expect(rotated, isNotNull);
      expect(rotated, isNot(id));
    });

    test('keeps the session just under the inactivity threshold', () {
      session.startSession();
      final id = session.sessionId;

      now = now.add(const Duration(minutes: 29, seconds: 59));

      expect(session.sessionId, id);
    });

    test('rotates exactly at the inactivity threshold', () {
      session.startSession();
      final id = session.sessionId;

      now = now.add(const Duration(minutes: 30));

      expect(session.sessionId, isNot(id));
    });

    test('rotates after 24 hours even when the user stays active', () {
      session.startSession();
      final id = session.sessionId;

      // Har 10 daqiqada faollik — idle hech qachon yuzaga kelmaydi.
      for (var i = 0; i < 6 * 24; i++) {
        now = now.add(const Duration(minutes: 10));
        session.touchSession();
      }

      expect(session.sessionId, isNot(id));
    });

    // Fon eventlari (push, sync) allaqachon tugagan sessiyani tiriltirmasligi
    // kerak — aks holda sessiya davomiyligi statistikasi buziladi.
    test('clears rather than rotates when idle in the background', () {
      session.startSession();
      session.isAppInBackground = true;

      now = now.add(const Duration(minutes: 31));

      expect(session.sessionId, isNull);
    });

    test('ignores touches while in the background', () {
      session.startSession();
      final id = session.sessionId;
      session.isAppInBackground = true;

      now = now.add(const Duration(minutes: 20));
      session.touchSession();

      // Faoliyat vaqti yangilanmagan, shuning uchun 31 daqiqada idle bo'ladi.
      session.isAppInBackground = false;
      now = now.add(const Duration(minutes: 11));

      expect(session.sessionId, isNot(id));
    });

    test('starts a fresh session when touched with none active', () {
      expect(session.sessionId, isNull);

      session.touchSession();

      expect(session.sessionId, isNotNull);
    });

    test('endSession() drops the current session', () {
      session.startSession();
      expect(session.sessionId, isNotNull);

      session.endSession();

      expect(session.sessionId, isNull);
      expect(session.startedAt, isNull);
    });

    test('rotate() forces a new id', () {
      session.startSession();
      final id = session.sessionId;

      final rotated = session.rotate();

      expect(rotated, isNot(id));
      expect(session.sessionId, rotated);
      expect(session.startedAt, now);
    });

    test('issues time-ordered session ids', () {
      session.startSession();
      final first = session.sessionId!;

      now = now.add(const Duration(hours: 1));
      final second = session.rotate();

      expect(first.compareTo(second), lessThan(0));
    });
  });
}
