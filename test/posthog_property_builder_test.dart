import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/context/posthog_context.dart';
import 'package:posthog_dart/src/internal/posthog_identity_manager.dart';
import 'package:posthog_dart/src/internal/posthog_preferences.dart';
import 'package:posthog_dart/src/internal/posthog_property_builder.dart';
import 'package:posthog_dart/src/internal/posthog_session_manager.dart';
import 'package:posthog_dart/src/posthog_config.dart';

class _FakeStore implements PreferencesStore {
  String? content;

  @override
  Future<void> initialize({required String projectToken}) async {}

  @override
  Future<String?> read() async => content;

  @override
  Future<void> write(String value) async => content = value;
}

void main() {
  late PostHogPropertyBuilder builder;
  late PostHogIdentityManager identity;
  late PostHogSessionManager session;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final preferences = PostHogPreferences(
      projectToken: 't',
      store: _FakeStore(),
    );
    await preferences.load();

    identity = PostHogIdentityManager(preferences);
    session = PostHogSessionManager()..startSession();
    builder = PostHogPropertyBuilder(
      context: PostHogContext(),
      identity: identity,
      session: session,
    );
  });

  group('PostHogPropertyBuilder', () {
    test('attaches the SDK identity to every event', () async {
      final result = await builder.build(eventName: 'test');

      expect(result[r'$lib'], 'posthog-flutter');
      expect(result[r'$lib_version'], isNotNull);
    });

    test('attaches the session and device ids', () async {
      final result = await builder.build(eventName: 'test');

      expect(result[r'$session_id'], session.sessionId);
      expect(result[r'$device_id'], identity.anonymousId);
    });

    test('merges super properties', () async {
      builder.superProperties['plan'] = 'pro';

      final result = await builder.build(eventName: 'test');

      expect(result['plan'], 'pro');
    });

    // Foydalanuvchi bergan property kontekstni ustidan yozishi kerak.
    test('lets caller properties win over context', () async {
      builder.superProperties['plan'] = 'free';

      final result = await builder.build(
        eventName: 'test',
        properties: {'plan': 'enterprise'},
      );

      expect(result['plan'], 'enterprise');
    });

    test('exposes user properties under the PostHog keys', () async {
      final result = await builder.build(
        eventName: 'test',
        userProperties: {'a': 1},
        userPropertiesSetOnce: {'b': 2},
      );

      expect(result[r'$set'], {'a': 1});
      expect(result[r'$set_once'], {'b': 2});
    });

    test('omits empty user property maps', () async {
      final result = await builder.build(
        eventName: 'test',
        userProperties: {},
        userPropertiesSetOnce: {},
      );

      expect(result.containsKey(r'$set'), isFalse);
      expect(result.containsKey(r'$set_once'), isFalse);
    });

    group('feature flags', () {
      test('exposes each flag under a per-flag key', () async {
        builder.featureFlags = {'beta': true, 'theme': 'dark'};

        final result = await builder.build(eventName: 'test');

        expect(result[r'$feature/beta'], isTrue);
        expect(result[r'$feature/theme'], 'dark');
      });

      // Faqat yoqilgan bayroqlar ro'yxatga kiradi.
      test('lists only enabled flags as active', () async {
        builder.featureFlags = {
          'on': true,
          'off': false,
          'variant': 'dark',
        };

        final result = await builder.build(eventName: 'test');

        final active = result[r'$active_feature_flags'] as List;
        expect(active, containsAll(['on', 'variant']));
        expect(active, isNot(contains('off')));
      });

      test('omits flags when sendFeatureFlags is off', () async {
        builder.featureFlags = {'beta': true};

        final result = await builder.build(
          eventName: 'test',
          sendFeatureFlags: false,
        );

        expect(result.containsKey(r'$feature/beta'), isFalse);
      });
    });

    group('person profile mode', () {
      test('never mode disables person processing', () async {
        final result = await builder.build(
          eventName: 'test',
          personProfiles: PostHogPersonProfiles.never,
        );

        expect(result[r'$process_person_profile'], isFalse);
      });

      test('always mode enables person processing', () async {
        final result = await builder.build(
          eventName: 'test',
          personProfiles: PostHogPersonProfiles.always,
        );

        expect(result[r'$process_person_profile'], isTrue);
      });

      test('identifiedOnly follows the identity state', () async {
        final anonymous = await builder.build(
          eventName: 'test',
          personProfiles: PostHogPersonProfiles.identifiedOnly,
        );
        expect(anonymous[r'$process_person_profile'], isFalse);
        expect(anonymous[r'$is_identified'], isFalse);

        identity.identify('user-123');

        final identified = await builder.build(
          eventName: 'test',
          personProfiles: PostHogPersonProfiles.identifiedOnly,
        );
        expect(identified[r'$process_person_profile'], isTrue);
        expect(identified[r'$is_identified'], isTrue);
      });
    });

    test('attaches groups when set', () async {
      builder.groups['company'] = 'acme';

      final result = await builder.build(eventName: 'test');

      expect(result[r'$groups'], {'company': 'acme'});
    });

    test('attaches the screen name when given', () async {
      final result = await builder.build(
        eventName: 'test',
        screenName: 'Checkout',
      );

      expect(result[r'$screen_name'], 'Checkout');
    });

    // `$snapshot` eventlari juda tez-tez yuboriladi; ularga to'liq kontekst
    // qo'shilsa trafik keskin oshardi va backend buni kutmaydi.
    group('appendSharedProps: false (snapshot rejimi)', () {
      test('omits the shared context', () async {
        builder.superProperties['plan'] = 'pro';
        builder.featureFlags = {'beta': true};

        final result = await builder.build(
          eventName: r'$snapshot',
          appendSharedProps: false,
        );

        expect(result.containsKey('plan'), isFalse);
        expect(result.containsKey(r'$feature/beta'), isFalse);
        expect(result.containsKey(r'$device_id'), isFalse);
        expect(result.containsKey(r'$os_name'), isFalse);
      });

      // SDK identifikatori replay eventlarida ham kerak.
      test('still carries the SDK identity', () async {
        final result = await builder.build(
          eventName: r'$snapshot',
          appendSharedProps: false,
        );

        expect(result[r'$lib'], 'posthog-flutter');
        expect(result[r'$lib_version'], isNotNull);
      });

      // Backend replay eventlarida bu uchtasini kutadi.
      test('carries the replay routing keys', () async {
        final result = await builder.build(
          eventName: r'$snapshot',
          appendSharedProps: false,
        );

        expect(result[r'$session_id'], session.sessionId);
        expect(result[r'$window_id'], session.sessionId);
        expect(result['distinct_id'], identity.distinctId);
      });
    });
  });
}
