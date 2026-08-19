import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog/posthog.dart';
import 'package:posthog/src/posthog_flutter_platform_interface.dart';
import 'package:posthog/src/posthog_http.dart';

/// Offline holatda ma'lumot yo'qolmasligini tekshiradi.
///
/// Bu SDK'ning eng muhim kafolati: tarmoq yo'q bo'lganda eventlar diskda
/// kutadi, ilova qayta ishga tushsa ham saqlanadi va tarmoq qaytgach
/// yuboriladi.
class _Client extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];

  /// Tarmoq holati: `false` bo'lganda so'rovlar muvaffaqiyatsiz bo'ladi.
  bool online = true;

  /// Serverning javob kodi (`online` true bo'lganda).
  int statusCode = 200;

  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;

    if (!online) {
      throw const SocketException('tarmoq mavjud emas');
    }

    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(request.body);
        if (decoded is Map && decoded['batch'] is List && statusCode == 200) {
          for (final e in decoded['batch'] as List) {
            events.add(Map<String, dynamic>.from(e as Map));
          }
        }
      } catch (_) {
        // Tekshiruvlar qabul qilingan eventlarga qaraydi.
      }
    }

    return http.StreamedResponse(
      Stream.value(utf8.encode('{"status":1}')),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late _Client client;
  late Directory tempDir;

  /// Bir xil diskdan foydalanuvchi yangi SDK instansiyasi — ilovaning qayta
  /// ishga tushishini modellaydi.
  Future<void> launchSdk({int flushAt = 1}) async {
    client = _Client()..online = client.online;
    PosthogFlutterPlatformInterface.instance = PosthogHttp(client: client);
    await Posthog().setup(
      PostHogConfig('token')
        ..host = 'https://test.local'
        ..flushAt = flushAt
        ..preloadFeatureFlags = false
        ..surveys = false
        ..captureApplicationLifecycleEvents = false,
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Bir xil katalog — ilova qayta ishga tushganda navbat saqlanadi.
    tempDir = await Directory.systemTemp.createTemp('posthog_offline');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 't',
        'packageName': 'com.example.t',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );

    client = _Client();
  });

  tearDown(() async {
    await Posthog().close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  /// Retry backoff pauzasi tugashini kutadi.
  ///
  /// Muvaffaqiyatsizlikdan keyin navbat ~1s pauza qiladi (eksponensial
  /// backoff + jitter), shuning uchun tarmoq qaytgach darhol yuborilmaydi.
  Future<void> waitOutBackoff() =>
      Future<void>.delayed(const Duration(milliseconds: 1600));

  /// Berilgan event yetib borishini kutadi.
  Future<bool> waitForEvent(String name) async {
    for (var i = 0; i < 40; i++) {
      if (client.events.any((e) => e['event'] == name)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Posthog().flush();
    }
    return false;
  }

  test('an offline event is not lost', () async {
    await launchSdk();
    client.online = false;

    await Posthog().capture(eventName: 'offline_event');
    await Posthog().flush();
    await settle();

    expect(client.events, isEmpty, reason: 'offline: yetib bormasligi kerak');

    // Tarmoq qaytdi. Navbat backoff pauzasida, shuning uchun kutamiz.
    client.online = true;
    await waitOutBackoff();
    await Posthog().flush();
    await settle();

    expect(await waitForEvent('offline_event'), isTrue);
  });

  // Eng muhim holat: ilova offline'da yopilib, keyin qayta ochilganda
  // eventlar hali ham yuborilishi kerak.
  test('offline events survive an app restart', () async {
    await launchSdk();
    client.online = false;

    await Posthog().capture(eventName: 'restart_1');
    await Posthog().capture(eventName: 'restart_2');
    await Posthog().flush();
    await settle();

    // Ilova yopildi.
    await Posthog().close();

    // Ilova qayta ochildi, tarmoq bor.
    client.online = true;
    await launchSdk();
    await Posthog().flush();
    await settle();

    final names = client.events.map((e) => e['event']).toList();
    expect(names, containsAll(['restart_1', 'restart_2']));
  });

  test('restored events keep their original order', () async {
    await launchSdk(flushAt: 1000);
    client.online = false;

    for (var i = 0; i < 10; i++) {
      await Posthog().capture(eventName: 'e$i');
    }
    await Posthog().close();

    client.online = true;
    await launchSdk(flushAt: 1000);
    await Posthog().flush();
    await settle();

    final names = client.events
        .map((e) => e['event'] as String)
        .where((n) => n.startsWith('e'))
        .toList();
    expect(names, [for (var i = 0; i < 10; i++) 'e$i']);
  });

  test('restored events keep their properties', () async {
    await launchSdk(flushAt: 1000);
    client.online = false;

    await Posthog().capture(
      eventName: 'boy_event',
      properties: {
        'raqam': 42,
        'ichma_ich': {'a': 1},
        'royxat': [1, 2, 3],
      },
    );
    await Posthog().close();

    client.online = true;
    await launchSdk(flushAt: 1000);
    await Posthog().flush();
    await settle();

    final event =
        client.events.firstWhere((e) => e['event'] == 'boy_event');
    final properties = event['properties'] as Map;

    expect(properties['raqam'], 42);
    expect(properties['ichma_ich'], {'a': 1});
    expect(properties['royxat'], [1, 2, 3]);
    // Kontekst ham saqlangan bo'lishi kerak.
    expect(properties[r'$session_id'], isNotNull);
  });

  // Server xatosi vaqtinchalik — eventlar saqlanishi kerak.
  test('a 5xx response keeps events queued', () async {
    await launchSdk();
    client.statusCode = 503;

    await Posthog().capture(eventName: 'server_xatosi');
    await Posthog().flush();
    await settle();

    expect(client.events, isEmpty);

    client.statusCode = 200;
    await waitOutBackoff();
    await Posthog().flush();
    await settle();

    expect(await waitForEvent('server_xatosi'), isTrue);
  });

  // 4xx — so'rovning o'zi noto'g'ri. Qayta yuborish abadiy tsikl bo'lardi,
  // shuning uchun event tashlanadi.
  test('a 4xx response drops the batch instead of looping', () async {
    await launchSdk();
    client.statusCode = 400;

    await Posthog().capture(eventName: 'yaroqsiz');
    await Posthog().flush();
    await settle();

    final countAfterFirst = client.requestCount;

    await Posthog().flush();
    await settle();

    expect(
      client.requestCount,
      countAfterFirst,
      reason: 'qayta urinilmasligi kerak',
    );
  });

  test('the identity survives an app restart', () async {
    await launchSdk();
    await Posthog().identify(userId: 'barqaror-user');
    await Posthog().close();

    await launchSdk();

    expect(await Posthog().getDistinctId(), 'barqaror-user');
  });

  test('the anonymous id survives an app restart', () async {
    await launchSdk();
    final before = await Posthog().getDistinctId();
    await Posthog().close();

    await launchSdk();

    expect(await Posthog().getDistinctId(), before);
  });

  test('super properties survive an app restart', () async {
    await launchSdk();
    await Posthog().register('plan', 'pro');
    await Posthog().close();

    await launchSdk();
    await Posthog().capture(eventName: 'keyin');
    await Posthog().flush();
    await settle();

    final event = client.events.firstWhere((e) => e['event'] == 'keyin');
    expect((event['properties'] as Map)['plan'], 'pro');
  });
}
