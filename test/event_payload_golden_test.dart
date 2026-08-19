import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';

/// Checks against the official plugin's golden reference.
///
/// `test/snapshots/event_channel_shapes.json` records WHICH fields the official
/// SDK passed to the native side for each call. The same input is fed in here
/// and the HTTP payload is checked for that data, which empirically confirms
/// the pure-Dart implementation drops no property.
///
/// The comparison is field-by-field, not byte-by-byte: because the transport
/// moved from MethodChannel to HTTP the envelope differs (`arguments` ->
/// `properties`), but the data itself must be identical.
class _CapturingClient extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
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
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"status":1}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late _CapturingClient client;
  late List<Map<String, dynamic>> golden;

  setUpAll(() {
    final file = File('test/snapshots/event_channel_shapes.json');
    golden = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final tempDir = await Directory.systemTemp.createTemp('posthog_golden');
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

    final config = PostHogConfig('snapshot_project_token')
      ..host = 'https://test.posthog.local'
      ..flushAt = 1
      ..preloadFeatureFlags = false
      ..surveys = false
      ..captureApplicationLifecycleEvents = false;
    await Posthog().setup(config);
  });

  tearDown(() async {
    await Posthog().close();
  });

  Map<String, dynamic> goldenFor(String method) =>
      golden.firstWhere((e) => e['method'] == method)['arguments']
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> waitForEvent(String name) async {
    for (var i = 0; i < 60; i++) {
      final match = client.events.where((e) => e['event'] == name);
      if (match.isNotEmpty) return match.first;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('"$name" eventi yuborilmadi');
  }

  group('golden referens', () {
    test('capture carries every property the official SDK sends', () async {
      final expected = goldenFor('capture');
      final expectedProperties =
          expected['properties'] as Map<String, dynamic>;

      await Posthog().screen(screenName: 'Checkout');
      await Posthog().capture(
        eventName: expected['eventName'] as String,
        properties: {
          'order_id': expectedProperties['order_id'] as Object,
          'total': expectedProperties['total'] as Object,
          'items': expectedProperties['items'] as Object,
          'placed_at': expectedProperties['placed_at'] as Object,
        },
        userProperties:
            (expected['userProperties'] as Map).cast<String, Object>(),
        userPropertiesSetOnce:
            (expected['userPropertiesSetOnce'] as Map).cast<String, Object>(),
      );
      await Posthog().flush();

      final event = await waitForEvent('order completed');
      final properties = event['properties'] as Map<String, dynamic>;

      // Every caller-supplied property must arrive.
      expect(properties['order_id'], expectedProperties['order_id']);
      expect(properties['total'], expectedProperties['total']);
      expect(properties['items'], expectedProperties['items']);
      expect(properties['placed_at'], expectedProperties['placed_at']);

      // `$set` / `$set_once` — PostHog kutgan kalitlar.
      expect(properties[r'$set'], expected['userProperties']);
      expect(properties[r'$set_once'], expected['userPropertiesSetOnce']);
    });

    test('screen carries the golden properties', () async {
      final expected = goldenFor('screen');
      final expectedProperties =
          expected['properties'] as Map<String, dynamic>;

      await Posthog().screen(
        screenName: expected['screenName'] as String,
        properties: {
          'cart_size': expectedProperties['cart_size'] as Object,
          'route': expectedProperties['route'] as Object,
        },
      );
      await Posthog().flush();

      final event = await waitForEvent(r'$screen');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(properties[r'$screen_name'], expected['screenName']);
      expect(properties['cart_size'], expectedProperties['cart_size']);
      expect(properties['route'], expectedProperties['route']);
    });

    test('identify carries the golden person properties', () async {
      final expected = goldenFor('identify');

      await Posthog().identify(
        userId: expected['userId'] as String,
        userProperties:
            (expected['userProperties'] as Map).cast<String, Object>(),
        userPropertiesSetOnce:
            (expected['userPropertiesSetOnce'] as Map).cast<String, Object>(),
      );
      await Posthog().flush();

      final event = await waitForEvent(r'$identify');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(event['distinct_id'], expected['userId']);
      expect(properties[r'$set'], expected['userProperties']);
      expect(properties[r'$set_once'], expected['userPropertiesSetOnce']);
    });

    test('setPersonProperties carries the golden properties', () async {
      final expected = goldenFor('setPersonProperties');

      await Posthog().setPersonProperties(
        userPropertiesToSet:
            (expected['userPropertiesToSet'] as Map).cast<String, Object>(),
        userPropertiesToSetOnce:
            (expected['userPropertiesToSetOnce'] as Map).cast<String, Object>(),
      );
      await Posthog().flush();

      final event = await waitForEvent(r'$set');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(properties[r'$set'], expected['userPropertiesToSet']);
      expect(properties[r'$set_once'], expected['userPropertiesToSetOnce']);
    });

    test('alias carries the golden alias', () async {
      final expected = goldenFor('alias');

      await Posthog().alias(alias: expected['alias'] as String);
      await Posthog().flush();

      final event = await waitForEvent(r'$create_alias');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(properties['alias'], expected['alias']);
      expect(properties['distinct_id'], isNotEmpty);
    });

    test('group carries the golden group properties', () async {
      final expected = goldenFor('group');

      await Posthog().group(
        groupType: expected['groupType'] as String,
        groupKey: expected['groupKey'] as String,
        groupProperties:
            (expected['groupProperties'] as Map).cast<String, Object>(),
      );
      await Posthog().flush();

      final event = await waitForEvent(r'$groupidentify');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(properties[r'$group_type'], expected['groupType']);
      expect(properties[r'$group_key'], expected['groupKey']);
      expect(properties[r'$group_set'], expected['groupProperties']);
    });

    // Once a group is set, subsequent events must carry it.
    test('groups ride along on later events', () async {
      final expected = goldenFor('group');

      await Posthog().group(
        groupType: expected['groupType'] as String,
        groupKey: expected['groupKey'] as String,
      );
      await Posthog().capture(eventName: 'later_event');
      await Posthog().flush();

      final event = await waitForEvent('later_event');
      final properties = event['properties'] as Map<String, dynamic>;

      expect(properties[r'$groups'], {
        expected['groupType']: expected['groupKey'],
      });
    });
  });
}
