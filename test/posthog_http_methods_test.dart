import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';

/// Exercises the individual `PosthogHttp` methods: the exception steps buffer,
/// logs, reset, feature flag evaluation and the shape of the flags request.
class _Client extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];
  final List<String> paths = [];
  final List<Map<String, dynamic>> flagRequests = [];

  /// Response returned for `/flags`.
  Map<String, dynamic> flagsResponse = {'flags': <String, dynamic>{}};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);

    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        if (decoded['batch'] is List) {
          for (final e in decoded['batch'] as List) {
            events.add(Map<String, dynamic>.from(e as Map));
          }
        }
        if (request.url.path.contains('flags')) {
          flagRequests.add(decoded);
        }
      } catch (_) {
        // Tekshiruvlar qabul qilingan eventlarga qaraydi.
      }
    }

    final body = request.url.path.contains('flags')
        ? jsonEncode(flagsResponse)
        : request.url.path.contains('/array/')
            ? '{"surveys":[]}'
            : '{"status":1}';
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late _Client client;
  late PosthogHttp sdk;

  Future<void> setupSdk({void Function(PostHogConfig)? configure}) async {
    final config = PostHogConfig('token')
      ..host = 'https://test.local'
      ..flushAt = 1
      ..preloadFeatureFlags = false
      ..surveys = false
      ..captureApplicationLifecycleEvents = false;
    configure?.call(config);
    await Posthog().setup(config);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final tempDir = await Directory.systemTemp.createTemp('posthog_methods');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 't',
        'packageName': 'com.example.t',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );

    client = _Client();
    sdk = PosthogHttp(client: client);
    PosthogFlutterPlatformInterface.instance = sdk;
  });

  tearDown(() async {
    await Posthog().close();
  });

  Future<Map<String, dynamic>?> eventNamed(String name) async {
    for (var i = 0; i < 40; i++) {
      final match = client.events.where((e) => e['event'] == name);
      if (match.isNotEmpty) return match.first;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return null;
  }

  group('addExceptionStep', () {
    test('attaches buffered steps to a later exception', () async {
      await setupSdk();

      await Posthog().addExceptionStep('savatga qo\'shildi');
      await Posthog().addExceptionStep('to\'lovga o\'tildi');
      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      final steps = properties[r'$exception_steps'] as List;

      expect(steps.length, 2);
      expect((steps.first as Map)['message'], 'savatga qo\'shildi');
      expect((steps.first as Map)['timestamp'], isNotNull);
    });

    test('stores step properties', () async {
      await setupSdk();

      await Posthog().addExceptionStep('bosildi', properties: {'tugma': 'ok'});
      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      final step = (properties[r'$exception_steps'] as List).single as Map;

      expect(step['properties'], {'tugma': 'ok'});
    });

    test('omits the key when no steps were recorded', () async {
      await setupSdk();

      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      expect(properties.containsKey(r'$exception_steps'), isFalse);
    });

    test('records nothing when steps are disabled', () async {
      await setupSdk(
        configure: (c) => c.errorTrackingConfig.exceptionSteps.enabled = false,
      );

      await Posthog().addExceptionStep('e\'tiborsiz');
      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      expect(properties.containsKey(r'$exception_steps'), isFalse);
    });

    // When the buffer limit is exceeded the oldest steps are dropped, not the
    // newest — the steps closest to the error are the valuable ones.
    test('drops the oldest steps once the budget is exceeded', () async {
      await setupSdk(
        configure: (c) => c.errorTrackingConfig.exceptionSteps.maxBytes = 200,
      );

      for (var i = 0; i < 10; i++) {
        await Posthog().addExceptionStep('step-$i');
      }
      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      final steps = properties[r'$exception_steps'] as List;
      final messages = steps.map((s) => (s as Map)['message']).toList();

      expect(steps.length, lessThan(10));
      expect(messages.last, 'step-9', reason: 'the last step must be kept');
      expect(messages, isNot(contains('step-0')));
    });

    test('skips a step larger than the whole budget', () async {
      await setupSdk(
        configure: (c) => c.errorTrackingConfig.exceptionSteps.maxBytes = 50,
      );

      await Posthog().addExceptionStep('x' * 500);
      await Posthog().captureException(error: Exception('boom'));
      await Posthog().flush();

      final properties =
          (await eventNamed(r'$exception'))!['properties'] as Map;
      expect(properties.containsKey(r'$exception_steps'), isFalse);
    });
  });

  group('captureLog', () {
    test('sends a log event with body and severity', () async {
      await setupSdk();

      await Posthog().captureLog(
        body: 'nimadir yuz berdi',
        level: PostHogLogSeverity.warn,
      );
      await Posthog().flush();

      final properties = (await eventNamed(r'$log'))!['properties'] as Map;
      expect(properties[r'$log_body'], 'nimadir yuz berdi');
      expect(properties[r'$log_severity'], 'warn');
    });

    test('carries attributes and trace identifiers', () async {
      await setupSdk();

      await Posthog().captureLog(
        body: 'so\'rov tugadi',
        attributes: {'duration_ms': 42},
        traceId: 'trace-1',
        spanId: 'span-1',
        traceFlags: 1,
      );
      await Posthog().flush();

      final properties = (await eventNamed(r'$log'))!['properties'] as Map;
      expect(properties[r'$log_attributes'], {'duration_ms': 42});
      expect(properties[r'$log_trace_id'], 'trace-1');
      expect(properties[r'$log_span_id'], 'span-1');
      expect(properties[r'$log_trace_flags'], 1);
    });

    test('drops an empty log body', () async {
      await setupSdk();

      await Posthog().captureLog(body: '');
      await Posthog().flush();

      expect(await eventNamed(r'$log'), isNull);
    });

    test('logger delegates to captureLog', () async {
      await setupSdk();

      Posthog().logger.error('ishlamadi');
      await Posthog().flush();

      final properties = (await eventNamed(r'$log'))!['properties'] as Map;
      expect(properties[r'$log_body'], 'ishlamadi');
      expect(properties[r'$log_severity'], 'error');
    });
  });

  group('reset', () {
    test('issues a new anonymous identity', () async {
      await setupSdk();

      await Posthog().identify(userId: 'user-1');
      final before = await Posthog().getDistinctId();

      await Posthog().reset();
      final after = await Posthog().getDistinctId();

      expect(after, isNot(before));
      expect(after, isNot('user-1'));
    });

    test('clears registered super properties', () async {
      await setupSdk();

      await Posthog().register('plan', 'pro');
      await Posthog().reset();
      await Posthog().capture(eventName: 'later');
      await Posthog().flush();

      final properties = (await eventNamed('later'))!['properties'] as Map;
      expect(properties.containsKey('plan'), isFalse);
    });

    test('clears groups', () async {
      await setupSdk();

      await Posthog().group(groupType: 'company', groupKey: 'acme');
      await Posthog().reset();
      await Posthog().capture(eventName: 'later');
      await Posthog().flush();

      final properties = (await eventNamed('later'))!['properties'] as Map;
      expect(properties.containsKey(r'$groups'), isFalse);
    });

    test('starts a new session', () async {
      await setupSdk();

      final before = await Posthog().getSessionId();
      await Posthog().reset();
      final after = await Posthog().getSessionId();

      expect(after, isNotNull);
      expect(after, isNot(before));
    });
  });

  group('feature flags', () {
    test('reports an enabled boolean flag', () async {
      client.flagsResponse = {
        'flags': {
          'beta': {'enabled': true},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      expect(await Posthog().isFeatureEnabled('beta'), isTrue);
      expect(await Posthog().getFeatureFlag('beta'), isTrue);
    });

    test('reports a disabled flag', () async {
      client.flagsResponse = {
        'flags': {
          'beta': {'enabled': false},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      expect(await Posthog().isFeatureEnabled('beta'), isFalse);
    });

    test('returns the variant for a multivariate flag', () async {
      client.flagsResponse = {
        'flags': {
          'theme': {'enabled': true, 'variant': 'dark'},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      expect(await Posthog().getFeatureFlag('theme'), 'dark');
      expect(await Posthog().isFeatureEnabled('theme'), isTrue);
    });

    test('returns a flag payload', () async {
      client.flagsResponse = {
        'flags': {
          'config': {
            'enabled': true,
            'metadata': {
              'payload': '{"color":"blue"}',
            },
          },
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      final result = await Posthog().getFeatureFlagResult('config');
      expect(result!.payload, {'color': 'blue'});
    });

    test('treats an unknown flag as disabled', () async {
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      expect(await Posthog().isFeatureEnabled('yoq'), isFalse);
      expect(await Posthog().getFeatureFlag('yoq'), isNull);
      expect(await Posthog().getFeatureFlagResult('missing'), isNull);
    });

    // A frequently checked flag must not generate thousands of pointless
    // events.
    test('sends the called event only once per flag', () async {
      client.flagsResponse = {
        'flags': {
          'beta': {'enabled': true},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      await Posthog().isFeatureEnabled('beta');
      await Posthog().isFeatureEnabled('beta');
      await Posthog().isFeatureEnabled('beta');
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final called =
          client.events.where((e) => e['event'] == r'$feature_flag_called');
      expect(called.length, 1);
    });

    test('skips the called event when sendEvent is false', () async {
      client.flagsResponse = {
        'flags': {
          'beta': {'enabled': true},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();

      await Posthog().getFeatureFlagResult('beta', sendEvent: false);
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        client.events.where((e) => e['event'] == r'$feature_flag_called'),
        isEmpty,
      );
    });

    test('forwards person properties to the flags endpoint', () async {
      await setupSdk();

      await Posthog().setPersonPropertiesForFlags(
        {'plan': 'enterprise'},
        reloadFeatureFlags: false,
      );
      await Posthog().reloadFeatureFlags();

      expect(
        client.flagRequests.last['person_properties'],
        {'plan': 'enterprise'},
      );
    });

    test('forwards group properties to the flags endpoint', () async {
      await setupSdk();

      await Posthog().setGroupPropertiesForFlags(
        'company',
        {'region': 'eu'},
        reloadFeatureFlags: false,
      );
      await Posthog().reloadFeatureFlags();

      expect(
        client.flagRequests.last['group_properties'],
        {
          'company': {'region': 'eu'},
        },
      );
    });

    test('resetting person properties clears them from the request', () async {
      await setupSdk();

      await Posthog().setPersonPropertiesForFlags(
        {'plan': 'enterprise'},
        reloadFeatureFlags: false,
      );
      await Posthog().resetPersonPropertiesForFlags(reloadFeatureFlags: false);
      await Posthog().reloadFeatureFlags();

      expect(
        client.flagRequests.last.containsKey('person_properties'),
        isFalse,
      );
    });

    test('resetting one group type leaves the others', () async {
      await setupSdk();

      await Posthog().setGroupPropertiesForFlags(
        'company',
        {'region': 'eu'},
        reloadFeatureFlags: false,
      );
      await Posthog().setGroupPropertiesForFlags(
        'team',
        {'size': 5},
        reloadFeatureFlags: false,
      );
      await Posthog().resetGroupPropertiesForFlags(
        groupType: 'company',
        reloadFeatureFlags: false,
      );
      await Posthog().reloadFeatureFlags();

      final groupProperties =
          client.flagRequests.last['group_properties'] as Map;
      expect(groupProperties.containsKey('company'), isFalse);
      expect(groupProperties.containsKey('team'), isTrue);
    });

    // When the quota runs out the last known values must be retained.
    test('keeps cached flags when the quota is exhausted', () async {
      client.flagsResponse = {
        'flags': {
          'beta': {'enabled': true},
        },
      };
      await setupSdk();
      await Posthog().reloadFeatureFlags();
      expect(await Posthog().isFeatureEnabled('beta'), isTrue);

      client.flagsResponse = {'quotaLimited': true};
      await Posthog().reloadFeatureFlags();

      expect(await Posthog().isFeatureEnabled('beta'), isTrue);
    });
  });

  group('session replay state', () {
    test('is inactive when session replay is off', () async {
      await setupSdk(configure: (c) => c.sessionReplay = false);

      expect(await Posthog().isSessionReplayActive(), isFalse);
    });

    test('is active when session replay is on', () async {
      await setupSdk(configure: (c) => c.sessionReplay = true);

      expect(await Posthog().isSessionReplayActive(), isTrue);
    });

    test('stopSessionRecording deactivates it', () async {
      await setupSdk(configure: (c) => c.sessionReplay = true);

      await Posthog().stopSessionRecording();

      expect(await Posthog().isSessionReplayActive(), isFalse);
    });

    test('startSessionRecording reactivates it', () async {
      await setupSdk(configure: (c) => c.sessionReplay = true);

      await Posthog().stopSessionRecording();
      await Posthog().startSessionRecording();

      expect(await Posthog().isSessionReplayActive(), isTrue);
    });

    // `sampleRate: 0` bu sessiyani yozuvdan chiqaradi.
    test('a zero sample rate excludes the session', () async {
      await setupSdk(configure: (c) {
        c.sessionReplay = true;
        c.sessionReplayConfig.sampleRate = 0.0;
      });

      expect(await Posthog().isSessionReplayActive(), isFalse);
    });

    test('resumeCurrent false starts a new session', () async {
      await setupSdk(configure: (c) => c.sessionReplay = true);

      final before = await Posthog().getSessionId();
      await Posthog().startSessionRecording(resumeCurrent: false);
      final after = await Posthog().getSessionId();

      expect(after, isNot(before));
    });
  });
}
