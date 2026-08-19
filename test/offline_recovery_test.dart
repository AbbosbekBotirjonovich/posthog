import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';

/// Verifies that no data is lost while offline.
///
/// This is the SDK's most important guarantee: with no network, events wait on
/// disk, survive an app restart, and are sent once connectivity returns.
class _Client extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];

  /// Network state: requests fail while this is `false`.
  bool online = true;

  /// The server's response code (while `online` is true).
  int statusCode = 200;

  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;

    if (!online) {
      throw const SocketException('network unavailable');
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

  /// A new SDK instance sharing the same disk — simulates the app being
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

    // The same directory, so the queue survives an app restart.
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

  /// Waits out the retry backoff pause.
  ///
  /// After a failure the queue pauses for ~1s (exponential backoff plus
  /// jitter), so nothing is sent the instant the network returns.
  Future<void> waitOutBackoff() =>
      Future<void>.delayed(const Duration(milliseconds: 1600));

  /// Waits for the given event to arrive.
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

    expect(client.events, isEmpty, reason: 'offline: must not arrive');

    // The network is back. The queue is in its backoff pause, so wait.
    client.online = true;
    await waitOutBackoff();
    await Posthog().flush();
    await settle();

    expect(await waitForEvent('offline_event'), isTrue);
  });

  // The most important case: the app is closed while offline and reopened,
  // and the events must still be delivered.
  test('offline events survive an app restart', () async {
    await launchSdk();
    client.online = false;

    await Posthog().capture(eventName: 'restart_1');
    await Posthog().capture(eventName: 'restart_2');
    await Posthog().flush();
    await settle();

    // The app was closed.
    await Posthog().close();

    // The app reopened, with a network.
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
    // The context must be preserved too.
    expect(properties[r'$session_id'], isNotNull);
  });

  // A server error is transient, so events must be retained.
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

  // 4xx means the request itself is wrong. Resending would loop forever, so
  // the event is dropped.
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
      reason: 'must not be retried',
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
    await Posthog().capture(eventName: 'after_restart');
    await Posthog().flush();
    await settle();

    final event = client.events.firstWhere((e) => e['event'] == 'after_restart');
    expect((event['properties'] as Map)['plan'], 'pro');
  });
}
