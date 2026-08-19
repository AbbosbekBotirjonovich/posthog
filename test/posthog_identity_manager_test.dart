import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/posthog_identity_manager.dart';
import 'package:posthog_dart/src/internal/posthog_preferences.dart';

/// Xotiradagi soxta ombor.
class _FakeStore implements PreferencesStore {
  String? content;

  @override
  Future<void> initialize({required String projectToken}) async {}

  @override
  Future<String?> read() async => content;

  @override
  Future<void> write(String value) async {
    content = value;
  }
}

void main() {
  late _FakeStore store;
  late PostHogPreferences preferences;
  late PostHogIdentityManager identity;

  setUp(() async {
    store = _FakeStore();
    preferences = PostHogPreferences(
      projectToken: 'test_token',
      store: store,
    );
    await preferences.load();
    identity = PostHogIdentityManager(preferences);
  });

  group('PostHogIdentityManager', () {
    test('generates a stable anonymous id', () {
      final first = identity.anonymousId;
      final second = identity.anonymousId;

      expect(first, isNotEmpty);
      expect(second, first);
    });

    test('uses the anonymous id as distinct id before identify', () {
      expect(identity.distinctId, identity.anonymousId);
      expect(identity.isIdentified, isFalse);
    });

    test('identify switches the distinct id', () {
      identity.identify('user-123');

      expect(identity.distinctId, 'user-123');
      expect(identity.isIdentified, isTrue);
    });

    // Backend anon va identifikatsiyalangan shaxsni shu property orqali
    // birlashtiradi.
    test('identify returns the previous anonymous id for merging', () {
      final anonymousId = identity.anonymousId;

      final previous = identity.identify('user-123');

      expect(previous, anonymousId);
    });

    // Ikkinchi marta yuborilsa backend shaxslarni noto'g'ri birlashtirardi.
    test('identify returns null when the user is already identified', () {
      identity.identify('user-123');

      final previous = identity.identify('user-456');

      expect(previous, isNull);
      expect(identity.distinctId, 'user-456');
    });

    test('identify returns null when re-identifying the same anonymous id', () {
      final anonymousId = identity.anonymousId;

      final previous = identity.identify(anonymousId);

      expect(previous, isNull);
    });

    test('identify ignores a blank user id', () {
      final before = identity.distinctId;

      identity.identify('   ');

      expect(identity.distinctId, before);
      expect(identity.isIdentified, isFalse);
    });

    test('identify trims the user id', () {
      identity.identify('  user-123  ');

      expect(identity.distinctId, 'user-123');
    });

    test('reset clears the identity and issues a new anonymous id', () {
      final originalAnonymous = identity.anonymousId;
      identity.identify('user-123');

      identity.reset();

      expect(identity.isIdentified, isFalse);
      expect(identity.anonymousId, isNot(originalAnonymous));
      expect(identity.distinctId, identity.anonymousId);
    });

    // Bir qurilmadagi chiqish/kirish sikllari yangi qurilma sifatida
    // hisoblanmasligi kerak.
    test('reset can keep the anonymous id', () {
      final originalAnonymous = identity.anonymousId;
      identity.identify('user-123');

      identity.reset(reuseAnonymousId: true);

      expect(identity.anonymousId, originalAnonymous);
      expect(identity.isIdentified, isFalse);
    });

    test('persists the identity across instances', () async {
      identity.identify('user-123');
      await preferences.flush();

      final reloaded = PostHogPreferences(
        projectToken: 'test_token',
        store: store,
      );
      await reloaded.load();
      final restored = PostHogIdentityManager(reloaded);

      expect(restored.distinctId, 'user-123');
      expect(restored.isIdentified, isTrue);
    });

    group('bootstrap', () {
      test('seeds an identified distinct id', () {
        identity.applyBootstrap(distinctId: 'user-123', isIdentifiedId: true);

        expect(identity.distinctId, 'user-123');
        expect(identity.isIdentified, isTrue);
      });

      test('seeds an anonymous id', () {
        identity.applyBootstrap(distinctId: 'anon-abc', isIdentifiedId: false);

        expect(identity.anonymousId, 'anon-abc');
        expect(identity.distinctId, 'anon-abc');
        expect(identity.isIdentified, isFalse);
      });

      // Bootstrap faqat birinchi ishga tushishda ma'noga ega; mavjud
      // foydalanuvchini qayta yozish uni boshqa shaxsga aylantirardi.
      test('never overwrites an existing identity', () {
        identity.identify('real-user');

        identity.applyBootstrap(distinctId: 'boot-user', isIdentifiedId: true);

        expect(identity.distinctId, 'real-user');
      });

      test('never overwrites an existing anonymous id', () {
        final existing = identity.anonymousId;

        identity.applyBootstrap(distinctId: 'boot-anon', isIdentifiedId: false);

        expect(identity.anonymousId, existing);
      });

      test('ignores a blank distinct id', () {
        identity.applyBootstrap(distinctId: '  ', isIdentifiedId: true);

        expect(identity.isIdentified, isFalse);
      });

      test('ignores a null distinct id', () {
        identity.applyBootstrap(distinctId: null, isIdentifiedId: true);

        expect(identity.isIdentified, isFalse);
      });
    });
  });

  group('PostHogPreferences', () {
    test('round-trips values through the store', () async {
      preferences.set('key', 'value');
      preferences.set('count', 42);
      preferences.set('flag', true);
      await preferences.flush();

      final reloaded = PostHogPreferences(
        projectToken: 'test_token',
        store: store,
      );
      await reloaded.load();

      expect(reloaded.getString('key'), 'value');
      expect(reloaded.getInt('count'), 42);
      expect(reloaded.getBool('flag'), isTrue);
    });

    test('returns null for a wrongly typed value', () {
      preferences.set('key', 'not-an-int');

      expect(preferences.getInt('key'), isNull);
      expect(preferences.getBool('key'), isNull);
    });

    test('setting null removes the key', () {
      preferences.set('key', 'value');
      preferences.set('key', null);

      expect(preferences.getString('key'), isNull);
    });

    test('clear() empties everything', () async {
      preferences.set('key', 'value');

      await preferences.clear();

      expect(preferences.getString('key'), isNull);
      expect(store.content, '{}');
    });

    // Buzilgan holat SDK'ni ishdan chiqarmasligi kerak.
    test('starts empty when the stored state is corrupted', () async {
      store.content = '{not valid json';

      final loaded = PostHogPreferences(
        projectToken: 'test_token',
        store: store,
      );
      await loaded.load();

      expect(loaded.getString('anything'), isNull);
    });
  });
}
