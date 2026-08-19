import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/src/internal/posthog_api.dart';
import 'package:posthog_dart/src/internal/posthog_queue.dart';
import 'package:posthog_dart/src/internal/posthog_queue_storage.dart';

/// Yuborilgan so'rovlarni yozib oluvchi soxta HTTP klient.
class _RecordingClient extends http.BaseClient {
  final List<_RecordedRequest> requests = [];

  /// Response keyed by URL; `null` yields a 200.
  Map<String, String> responses = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    requests.add(_RecordedRequest(url: request.url.toString(), body: body));

    for (final entry in responses.entries) {
      if (request.url.toString().contains(entry.key)) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(entry.value)),
          200,
        );
      }
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

class _RecordedRequest {
  _RecordedRequest({required this.url, required this.body});

  final String url;
  final String body;

  Map<String, dynamic> get json =>
      jsonDecode(body) as Map<String, dynamic>;

  /// `/batch` so'rovidagi eventlar.
  List<Map<String, dynamic>> get batch =>
      (json['batch'] as List).cast<Map<String, dynamic>>();
}

/// In-memory queue store.
class _MemoryQueueStore implements QueueStore {
  final Map<String, String> entries = {};

  @override
  Future<void> initialize({
    required String projectToken,
    required String queueName,
  }) async {}

  @override
  Future<void> write(String id, String content) async {
    entries[id] = content;
  }

  @override
  Future<String?> read(String id) async => entries[id];

  @override
  Future<List<String>> listIds() async => entries.keys.toList();

  @override
  Future<void> delete(String id) async => entries.remove(id);

  @override
  Future<void> clear() async => entries.clear();
}

void main() {
  late _RecordingClient client;

  setUp(() {
    client = _RecordingClient();
  });

  /// Building a full `PosthogHttp` requires an intricate dependency graph, so
  /// the transport chain is exercised directly here: API -> queue -> HTTP.
  PostHogQueue buildQueue(PostHogApi api) {
    return PostHogQueue(
      name: 'events',
      sender: api.batch,
      storage: PostHogQueueStorage(
        projectToken: 'test_token',
        queueName: 'events',
        store: _MemoryQueueStore(),
      ),
      flushAt: 1000,
      flushInterval: const Duration(hours: 1),
    );
  }

  group('PostHogApi', () {
    test('posts events to /batch with the project token', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );

      await api.batch([
        {'event': 'order completed', 'distinct_id': 'user-1'},
      ]);

      final request = client.requests.single;
      expect(request.url, 'https://us.i.posthog.com/batch');
      expect(request.json['api_key'], 'test_token');
      expect(request.batch.single['event'], 'order completed');
    });

    test('posts snapshots to /s/', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );

      await api.snapshot([
        {'event': '\$snapshot'},
      ]);

      expect(client.requests.single.url, 'https://us.i.posthog.com/s/');
    });

    test('requests flags from /flags/?v=2', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );

      await api.flags(distinctId: 'user-1');

      final request = client.requests.single;
      expect(request.url, 'https://us.i.posthog.com/flags/?v=2');
      expect(request.json['distinct_id'], 'user-1');
      expect(request.json['api_key'], 'test_token');
    });

    test('omits empty flag targeting fields', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );

      await api.flags(
        distinctId: 'user-1',
        groups: {},
        personProperties: {},
      );

      final json = client.requests.single.json;
      expect(json.containsKey('groups'), isFalse);
      expect(json.containsKey('person_properties'), isFalse);
    });

    test('strips a trailing slash from the host', () async {
      final api = PostHogApi(
        host: 'https://eu.i.posthog.com/',
        projectToken: 'test_token',
        client: client,
      );

      await api.batch([]);

      expect(client.requests.single.url, 'https://eu.i.posthog.com/batch');
    });

    group('assets host', () {
      test('maps the US cloud host', () {
        final api = PostHogApi(
          host: 'https://us.i.posthog.com',
          projectToken: 't',
          client: client,
        );

        expect(api.assetsHost, 'https://us-assets.i.posthog.com');
      });

      test('maps the EU cloud host', () {
        final api = PostHogApi(
          host: 'https://eu.i.posthog.com',
          projectToken: 't',
          client: client,
        );

        expect(api.assetsHost, 'https://eu-assets.i.posthog.com');
      });

      // A self-hosted instance has no separate assets host.
      test('leaves a self-hosted host untouched', () {
        final api = PostHogApi(
          host: 'https://analytics.example.com',
          projectToken: 't',
          client: client,
        );

        expect(api.assetsHost, 'https://analytics.example.com');
      });
    });

    group('result classification', () {
      test('treats 2xx as success', () {
        const result = PostHogApiResult(success: true, statusCode: 200);
        expect(result.success, isTrue);
      });

      test('marks a network failure retriable', () {
        const result = PostHogApiResult(success: false);
        expect(result.isRetriable, isTrue);
      });

      test('marks 5xx retriable', () {
        const result = PostHogApiResult(success: false, statusCode: 503);
        expect(result.isRetriable, isTrue);
      });

      // Rate limits and timeouts are transient, so they must be retried.
      test('marks 429 and 408 retriable', () {
        expect(
          const PostHogApiResult(success: false, statusCode: 429).isRetriable,
          isTrue,
        );
        expect(
          const PostHogApiResult(success: false, statusCode: 408).isRetriable,
          isTrue,
        );
      });

      // Other 4xx: the request itself is wrong, so resending is pointless.
      test('marks other 4xx non-retriable', () {
        expect(
          const PostHogApiResult(success: false, statusCode: 400).isRetriable,
          isFalse,
        );
        expect(
          const PostHogApiResult(success: false, statusCode: 401).isRetriable,
          isFalse,
        );
      });
    });
  });

  group('event payload shape', () {
    test('sends the fields PostHog requires for every event', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );
      final queue = buildQueue(api);

      await queue.add({
        'event': 'order completed',
        'distinct_id': 'user-1',
        'properties': {'total': 42.5},
        'timestamp': '2026-03-01T12:30:00.000Z',
      });
      await queue.flush();

      final event = client.requests.single.batch.single;

      // The trio PostHog requires for `/batch`.
      expect(event['event'], 'order completed');
      expect(event['distinct_id'], 'user-1');
      expect(event['properties'], isA<Map>());
      expect(event['timestamp'], '2026-03-01T12:30:00.000Z');
    });

    test('preserves nested property structures through JSON', () async {
      final api = PostHogApi(
        host: 'https://us.i.posthog.com',
        projectToken: 'test_token',
        client: client,
      );
      final queue = buildQueue(api);

      await queue.add({
        'event': 'order completed',
        'distinct_id': 'user-1',
        'properties': {
          'items': [
            {'sku': 'sku_1', 'quantity': 2},
          ],
          'route': {'source': 'email'},
        },
      });
      await queue.flush();

      final properties =
          client.requests.single.batch.single['properties'] as Map;
      expect((properties['items'] as List).single, {
        'sku': 'sku_1',
        'quantity': 2,
      });
      expect(properties['route'], {'source': 'email'});
    });
  });
}
