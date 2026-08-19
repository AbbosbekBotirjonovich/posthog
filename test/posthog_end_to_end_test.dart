import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';

/// So'rovlarni ushlab qoluvchi klient.
///
/// `TestWidgetsFlutterBinding` haqiqiy soketlarni bloklaydi (barcha so'rovga
/// 400 qaytaradi), shuning uchun bu yerda tarmoq emas, **SDK zanjirining
/// o'zi** sinovdan o'tkaziladi: `Posthog()` fasadidan boshlab yakuniy JSON
/// payload'gacha. Tarmoq qatlami `posthog_http_test.dart` da alohida
/// tekshiriladi.
class _CapturingClient extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];
  final List<String> paths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);

    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(request.body);
        if (decoded is Map && decoded['batch'] is List) {
          for (final event in decoded['batch'] as List) {
            events.add(Map<String, dynamic>.from(event as Map));
          }
        }
      } catch (_) {
        // Tekshiruvlar qabul qilingan eventlarga qaraydi.
      }
    }

    final body = request.url.path.contains('/array/')
        ? '{"surveys":[]}'
        : '{"status":1}';
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

/// SDK'ni haqiqiy HTTP serverga qarshi uchidan-uchiga sinovdan o'tkazadi.
///
/// Bu birlik testlaridan farq qiladi: bu yerda `Posthog()` fasadidan boshlab
/// haqiqiy soket orqali yuborilgan JSON'gacha butun zanjir ishlaydi. Faqat
/// shu daraja `setup()` da bir necha bog'liqlikni noto'g'ri ulashdek xatolarni
/// ushlaydi.
void main() {
  late _CapturingClient client;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Test muhitida platforma plaginlari yo'q. SDK ularsiz ham ishlaydi
    // (xatolar yutiladi), lekin ularni mock qilish diskda saqlash yo'lini
    // ham sinovdan o'tkazadi.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    final tempDir = await Directory.systemTemp.createTemp('posthog_test');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'posthog_test',
        'packageName': 'com.example.posthog_test',
        'version': '1.2.3',
        'buildNumber': '42',
      },
    );

    client = _CapturingClient();
    PosthogFlutterPlatformInterface.instance = PosthogHttp(client: client);
  });

  tearDown(() async {
    await Posthog().close();
  });

  Future<void> setupSdk({void Function(PostHogConfig)? configure}) async {
    final config = PostHogConfig('test_project_token')
      ..host = 'https://test.posthog.local'
      ..flushAt = 1
      ..preloadFeatureFlags = false
      ..surveys = false
      ..captureApplicationLifecycleEvents = false;
    configure?.call(config);
    await Posthog().setup(config);
  }

  /// Eventlar navbat orqali asinxron yuboriladi.
  Future<void> waitForEvents(int count) async {
    for (var i = 0; i < 60; i++) {
      if (client.events.length >= count) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  group('uchidan-uchiga', () {
    test('sends a captured event to /batch', () async {
      await setupSdk();

      await Posthog().capture(
        eventName: 'buyurtma_yakunlandi',
        properties: {'summa': 42.5},
      );
      await Posthog().flush();
      await waitForEvents(1);

      expect(client.paths, contains('/batch'));

      final event = client.events.firstWhere(
        (e) => e['event'] == 'buyurtma_yakunlandi',
      );
      expect(event['distinct_id'], isNotEmpty);
      expect(event['timestamp'], isNotNull);
      expect((event['properties'] as Map)['summa'], 42.5);
    });

    // Windows'da bu qiymatlar birinchi marta to'ldirildi — rasmiy plaginda
    // platforma umuman qo'llab-quvvatlanmagani uchun ular yo'q edi.
    test('attaches platform context to every event', () async {
      await setupSdk();

      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await waitForEvents(1);

      final properties =
          client.events.first['properties'] as Map<String, dynamic>;

      expect(properties['\$os_name'], isNotNull);
      expect(properties['\$device_type'], isNotNull);
      expect(properties['\$lib'], 'posthog-flutter');
      expect(properties['\$lib_version'], isNotNull);
      expect(properties['\$session_id'], isNotNull);
      expect(properties['\$device_id'], isNotNull);
    });

    test('identify carries the anonymous id for merging', () async {
      await setupSdk();

      final anonymousId = await Posthog().getDistinctId();
      await Posthog().identify(userId: 'user-123');
      await Posthog().flush();
      await waitForEvents(1);

      final event = client.events.firstWhere(
        (e) => e['event'] == '\$identify',
      );
      expect(event['distinct_id'], 'user-123');
      expect(
        (event['properties'] as Map)['\$anon_distinct_id'],
        anonymousId,
      );
    });

    test('screen events carry the screen name', () async {
      await setupSdk();

      await Posthog().screen(screenName: 'Savat');
      await Posthog().flush();
      await waitForEvents(1);

      final event = client.events.firstWhere((e) => e['event'] == '\$screen');
      expect((event['properties'] as Map)['\$screen_name'], 'Savat');
    });

    test('registered super properties ride along', () async {
      await setupSdk();

      await Posthog().register('plan', 'pro');
      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await waitForEvents(1);

      expect((client.events.first['properties'] as Map)['plan'], 'pro');
    });

    test('unregister removes a super property', () async {
      await setupSdk();

      await Posthog().register('plan', 'pro');
      await Posthog().unregister('plan');
      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await waitForEvents(1);

      expect(
        (client.events.first['properties'] as Map).containsKey('plan'),
        isFalse,
      );
    });

    test('captured exceptions reach the backend', () async {
      await setupSdk();

      try {
        throw StateError('sinov xatosi');
      } catch (e, s) {
        await Posthog().captureException(error: e, stackTrace: s);
      }
      await Posthog().flush();
      await waitForEvents(1);

      final event = client.events.firstWhere(
        (e) => e['event'] == '\$exception',
      );
      final properties = event['properties'] as Map;
      expect(properties['\$exception_list'], isNotNull);
    });

    test('beforeSend can drop an event', () async {
      await setupSdk(configure: (config) {
        config.beforeSend = [
          (event) => event.event == 'tashlanadi' ? null : event,
        ];
      });

      await Posthog().capture(eventName: 'tashlanadi');
      await Posthog().capture(eventName: 'saqlanadi');
      await Posthog().flush();
      await waitForEvents(1);

      final names = client.events.map((e) => e['event']).toList();
      expect(names, contains('saqlanadi'));
      expect(names, isNot(contains('tashlanadi')));
    });

    test('beforeSend can rewrite properties', () async {
      await setupSdk(configure: (config) {
        config.beforeSend = [
          (event) {
            event.properties = {...?event.properties, 'qoshildi': true};
            return event;
          },
        ];
      });

      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await waitForEvents(1);

      expect((client.events.first['properties'] as Map)['qoshildi'], isTrue);
    });

    test('opting out suppresses delivery', () async {
      await setupSdk(configure: (config) => config.optOut = true);

      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(client.events, isEmpty);
    });

    test('enable() resumes delivery after disable()', () async {
      await setupSdk();

      await Posthog().disable();
      await Posthog().capture(eventName: 'yuborilmaydi');
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(client.events, isEmpty);

      await Posthog().enable();
      await Posthog().capture(eventName: 'yuboriladi');
      await Posthog().flush();
      await waitForEvents(1);

      expect(client.events.single['event'], 'yuboriladi');
    });

    test('groups are attached after group()', () async {
      await setupSdk();

      await Posthog().group(groupType: 'company', groupKey: 'acme');
      await Posthog().capture(eventName: 'test');
      await Posthog().flush();
      await waitForEvents(2);

      final event = client.events.firstWhere((e) => e['event'] == 'test');
      expect(
        (event['properties'] as Map)['\$groups'],
        {'company': 'acme'},
      );
    });

    test('every event in a session shares one session id', () async {
      await setupSdk();

      await Posthog().capture(eventName: 'birinchi');
      await Posthog().capture(eventName: 'ikkinchi');
      await Posthog().flush();
      await waitForEvents(2);

      final ids = client.events
          .map((e) => (e['properties'] as Map)['\$session_id'])
          .toSet();
      expect(ids.length, 1);
    });
  });
}
