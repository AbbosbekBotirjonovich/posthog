import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';
import 'package:posthog_dart/src/replay/native_communicator.dart';

/// Replay pipeline'ini transportga ulovchi qatlamni tekshiradi.
///
/// In the official plugin this class called into the native SDK over the
/// qilardi; bu yerda u `PosthogHttp` ga yo'naltiriladi va `$snapshot` eventi
/// Dart'da quriladi.
class _Client extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];
  final List<String> paths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(request.body);
        if (decoded is Map && decoded['batch'] is List) {
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
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Uint8List makePng(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 200, 90));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late _Client client;
  const communicator = NativeCommunicator();

  Future<void> setupSdk({bool sessionReplay = true}) async {
    await Posthog().setup(
      PostHogConfig('token')
        ..host = 'https://test.local'
        ..flushAt = 1
        ..preloadFeatureFlags = false
        ..surveys = false
        ..captureApplicationLifecycleEvents = false
        ..sessionReplay = sessionReplay,
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final tempDir = await Directory.systemTemp.createTemp('posthog_replay');
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
    PosthogFlutterPlatformInterface.instance = PosthogHttp(client: client);
  });

  tearDown(() async {
    await Posthog().close();
  });

  Future<List<Map<String, dynamic>>> snapshots() async {
    for (var i = 0; i < 40; i++) {
      final match =
          client.events.where((e) => e['event'] == r'$snapshot').toList();
      if (match.isNotEmpty) return match;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return const [];
  }

  group('replay eventlarini yuborish', () {
    test('sends a meta event through the replay queue', () async {
      await setupSdk();

      await communicator.sendMetaEvent(
        width: 390,
        height: 844,
        screen: 'Checkout',
      );
      await Posthog().flush();

      final snapshot = (await snapshots()).single;
      final data = (snapshot['properties'] as Map)[r'$snapshot_data'] as List;
      final event = data.single as Map;

      expect(event['type'], 4, reason: 'rrweb meta type');
      expect((event['data'] as Map)['width'], 390);
      expect((event['data'] as Map)['href'], 'Checkout');
    });

    test('sends a full snapshot through the replay queue', () async {
      await setupSdk();

      await communicator.sendFullSnapshot(
        makePng(50, 40),
        id: 3,
        x: 0,
        y: 0,
      );
      await Posthog().flush();

      final snapshot = (await snapshots()).single;
      final data = (snapshot['properties'] as Map)[r'$snapshot_data'] as List;
      final event = data.single as Map;

      expect(event['type'], 2, reason: 'rrweb full snapshot type');

      final wireframe =
          ((event['data'] as Map)['wireframes'] as List).single as Map;
      expect(wireframe['id'], 3);
      expect(wireframe['width'], 50);
      expect(wireframe['height'], 40);
    });

    // Backend `$snapshot` ni shu marshrutlash kalitlarisiz qabul qilmaydi.
    test('snapshots carry the replay routing keys', () async {
      await setupSdk();

      await communicator.sendMetaEvent(width: 1, height: 1, screen: null);
      await Posthog().flush();

      final properties = (await snapshots()).single['properties'] as Map;

      expect(properties[r'$session_id'], isNotNull);
      expect(properties[r'$window_id'], properties[r'$session_id']);
      expect(properties[r'$snapshot_source'], 'mobile');
      expect(properties['distinct_id'], isNotEmpty);
    });

    test('snapshots go to the /s/ endpoint', () async {
      await setupSdk();

      await communicator.sendMetaEvent(width: 1, height: 1, screen: null);
      await Posthog().flush();
      await snapshots();

      expect(client.paths, contains('/s/'));
    });

    // Nothing may be sent while replay is off — otherwise
    // foydalanuvchi so'ramagan trafik ketardi.
    test('sends nothing when session replay is off', () async {
      await setupSdk(sessionReplay: false);

      await communicator.sendMetaEvent(width: 1, height: 1, screen: null);
      await communicator.sendFullSnapshot(makePng(10, 10), id: 1, x: 0, y: 0);
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        client.events.where((e) => e['event'] == r'$snapshot'),
        isEmpty,
      );
    });

    test('sends nothing after stopSessionRecording', () async {
      await setupSdk();
      await Posthog().stopSessionRecording();

      await communicator.sendMetaEvent(width: 1, height: 1, screen: null);
      await Posthog().flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        client.events.where((e) => e['event'] == r'$snapshot'),
        isEmpty,
      );
    });

    test('reports the replay state', () async {
      await setupSdk();

      expect(await communicator.isSessionReplayActive(), isTrue);

      await Posthog().stopSessionRecording();

      expect(await communicator.isSessionReplayActive(), isFalse);
    });
  });

  // These two capabilities require the native SDK. The calling code handles
  // their "unavailable" answer: the platform view is covered with a black mask
  // qoplanadi, occlusion esa placeholder kadrga tushadi.
  group('native capabilities are unavailable', () {
    test('native screenshots return null placeholders', () async {
      final result = await communicator.captureNativeScreenshots([
        {'x': 0, 'y': 0, 'width': 10, 'height': 10},
        {'x': 5, 'y': 5, 'width': 20, 'height': 20},
      ]);

      expect(result.length, 2);
      expect(result.every((e) => e == null), isTrue);
    });

    test('an empty view list returns an empty result', () async {
      expect(await communicator.captureNativeScreenshots([]), isEmpty);
    });

    test('the native bridge is declined', () async {
      expect(await communicator.enableNativeBridge(episode: 1), isFalse);
    });
  });
}
