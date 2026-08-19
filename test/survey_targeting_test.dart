import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/src/internal/posthog_api.dart';
import 'package:posthog_dart/src/internal/posthog_feature_flags.dart';
import 'package:posthog_dart/src/internal/posthog_identity_manager.dart';
import 'package:posthog_dart/src/internal/posthog_preferences.dart';
import 'package:posthog_dart/src/internal/surveys/survey_targeting.dart';
import 'package:posthog_dart/src/util/platform_io_stub.dart'
    if (dart.library.io) 'package:posthog_dart/src/util/platform_io_real.dart';

/// Remote config javobini boshqarish imkonini beruvchi klient.
class _FakeClient extends http.BaseClient {
  List<Map<String, dynamic>> surveys = [];
  bool failRequests = false;
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    if (failRequests) {
      return http.StreamedResponse(Stream.value(utf8.encode('')), 500);
    }
    final body = jsonEncode({'surveys': surveys});
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }
}

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
  late _FakeClient client;
  late PostHogPreferences preferences;
  late _FakeStore store;
  late PostHogFeatureFlags flags;
  late PostHogApi api;

  setUp(() async {
    client = _FakeClient();
    store = _FakeStore();
    preferences = PostHogPreferences(projectToken: 't', store: store);
    await preferences.load();

    api = PostHogApi(host: 'https://x.test', projectToken: 't', client: client);
    flags = PostHogFeatureFlags(
      api: api,
      preferences: preferences,
      identity: PostHogIdentityManager(preferences),
    );
  });

  SurveyTargeting buildTargeting() =>
      SurveyTargeting(api: api, preferences: preferences, flags: flags);

  /// Ko'rsatishga tayyor minimal so'rovnoma.
  Map<String, dynamic> activeSurvey(
    String id, {
    Map<String, dynamic>? conditions,
    String? linkedFlagKey,
    String? internalTargetingFlagKey,
    String? schedule,
  }) =>
      {
        'id': id,
        'name': 'Survey $id',
        'startDate': 1700000000000,
        'endDate': null,
        'questions': <Map<String, dynamic>>[],
        if (conditions != null) 'conditions': conditions,
        if (linkedFlagKey != null) 'linkedFlagKey': linkedFlagKey,
        if (internalTargetingFlagKey != null) 'internalTargetingFlagKey': internalTargetingFlagKey,
        if (schedule != null) 'schedule': schedule,
      };

  group('yuklash', () {
    test('loads surveys from remote config', () async {
      client.surveys = [activeSurvey('s1')];
      final targeting = buildTargeting();

      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('caches surveys for the next launch', () async {
      client.surveys = [activeSurvey('s1')];
      await buildTargeting().load();
      await preferences.flush();

      // No network, so the cache must be used.
      client.failRequests = true;
      final reloaded = buildTargeting();
      await reloaded.load();

      expect(reloaded.nextSurvey()?['id'], 's1');
    });

    test('survives a malformed remote config', () async {
      final targeting = buildTargeting();
      client.failRequests = true;

      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });
  });

  group('aktivlik shartlari', () {
    test('skips a survey that never started', () async {
      client.surveys = [
        {...activeSurvey('s1'), 'startDate': null},
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });

    test('skips a survey that already ended', () async {
      client.surveys = [
        {...activeSurvey('s1'), 'endDate': 1700000000000},
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });

    test('returns the first eligible survey', () async {
      client.surveys = [
        {...activeSurvey('s1'), 'startDate': null},
        activeSurvey('s2'),
        activeSurvey('s3'),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's2');
    });
  });

  group('ko\'rilganini eslab qolish', () {
    test('does not show a survey twice', () async {
      client.surveys = [activeSurvey('s1')];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's1');
      targeting.markSeen('s1');

      expect(targeting.nextSurvey(), isNull);
      expect(targeting.hasSeen('s1'), isTrue);
    });

    // A survey with `schedule: always` must be shown again.
    test('repeats a survey scheduled as always', () async {
      client.surveys = [activeSurvey('s1', schedule: 'always')];
      final targeting = buildTargeting();
      await targeting.load();

      targeting.markSeen('s1');

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('honors the wait period between surveys', () async {
      final now = DateTime(2026, 3, 1);
      client.surveys = [
        activeSurvey('s1'),
        activeSurvey('s2', conditions: {'seenSurveyWaitPeriodInDays': 7}),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      targeting.markSeen('s1', now: now);

      // 3 kun o'tdi — hali erta.
      expect(
        targeting.nextSurvey(now: now.add(const Duration(days: 3))),
        isNull,
      );
      // 8 kun o'tdi — ko'rsatish mumkin.
      expect(
        targeting.nextSurvey(now: now.add(const Duration(days: 8)))?['id'],
        's2',
      );
    });
  });

  group('feature flag shartlari', () {
    test('skips a survey whose linked flag is unknown', () async {
      client.surveys = [activeSurvey('s1', linkedFlagKey: 'missing-flag')];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });

    test('shows a survey whose linked flag is enabled', () async {
      flags.applyBootstrap(featureFlags: {'my-flag': true});
      client.surveys = [activeSurvey('s1', linkedFlagKey: 'my-flag')];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('skips a survey whose linked flag is disabled', () async {
      flags.applyBootstrap(featureFlags: {'my-flag': false});
      client.surveys = [activeSurvey('s1', linkedFlagKey: 'my-flag')];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });

    // The internal targeting flag must not block a repeatable survey
    // — it is turned off after the first display.
    test('ignores the internal targeting flag for repeating surveys', () async {
      client.surveys = [
        activeSurvey(
          's1',
          schedule: 'always',
          internalTargetingFlagKey: 'internal-flag',
        ),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('honors the internal targeting flag for one-shot surveys', () async {
      client.surveys = [
        activeSurvey('s1', internalTargetingFlagKey: 'internal-flag'),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });
  });

  group('activation by event', () {
    Map<String, dynamic> eventActivated(String id, String eventName) =>
        activeSurvey(id, conditions: {
          'events': {
            'values': [
              {'name': eventName},
            ],
          },
        });

    test('hides an event-gated survey until the event fires', () async {
      client.surveys = [eventActivated('s1', 'checkout_completed')];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);

      targeting.onEvent('checkout_completed');

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('ignores an unrelated event', () async {
      client.surveys = [eventActivated('s1', 'checkout_completed')];
      final targeting = buildTargeting();
      await targeting.load();

      targeting.onEvent('something_else');

      expect(targeting.nextSurvey(), isNull);
    });

    test('deactivates after the survey is shown', () async {
      client.surveys = [eventActivated('s1', 'checkout_completed')];
      final targeting = buildTargeting();
      await targeting.load();

      targeting.onEvent('checkout_completed');
      targeting.markSeen('s1');

      expect(targeting.nextSurvey(), isNull);
    });
  });

  group('device type condition', () {
    test('shows a survey matching the current device type', () async {
      client.surveys = [
        activeSurvey('s1', conditions: {
          'deviceTypes': [platformDeviceType],
          'deviceTypesMatchType': 'exact',
        }),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey()?['id'], 's1');
    });

    test('skips a survey targeting a different device type', () async {
      client.surveys = [
        activeSurvey('s1', conditions: {
          'deviceTypes': ['SomeOtherDevice'],
          'deviceTypesMatchType': 'exact',
        }),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });

    test('honors an is_not match type', () async {
      client.surveys = [
        activeSurvey('s1', conditions: {
          'deviceTypes': [platformDeviceType],
          'deviceTypesMatchType': 'is_not',
        }),
      ];
      final targeting = buildTargeting();
      await targeting.load();

      expect(targeting.nextSurvey(), isNull);
    });
  });

  test('clear() drops everything', () async {
    client.surveys = [activeSurvey('s1')];
    final targeting = buildTargeting();
    await targeting.load();

    targeting.clear();

    expect(targeting.nextSurvey(), isNull);
  });
}
