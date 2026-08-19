import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/posthog_api.dart';
import 'package:posthog_dart/src/internal/posthog_queue.dart';
import 'package:posthog_dart/src/internal/posthog_queue_storage.dart';
import 'package:posthog_dart/src/internal/posthog_retry_policy.dart';

/// In-memory fake store, for exercising the queue logic without disk I/O.
class _FakeStore implements QueueStore {
  final Map<String, String> entries = {};
  bool failWrites = false;

  @override
  Future<void> initialize({
    required String projectToken,
    required String queueName,
  }) async {}

  @override
  Future<void> write(String id, String content) async {
    if (failWrites) throw StateError('disk to\'la');
    entries[id] = content;
  }

  @override
  Future<String?> read(String id) async => entries[id];

  @override
  Future<List<String>> listIds() async => entries.keys.toList();

  @override
  Future<void> delete(String id) async {
    entries.remove(id);
  }

  @override
  Future<void> clear() async {
    entries.clear();
  }
}

void main() {
  late _FakeStore store;
  late PostHogQueueStorage storage;
  late List<List<Map<String, Object?>>> sentBatches;

  setUp(() {
    store = _FakeStore();
    storage = PostHogQueueStorage(
      projectToken: 'test_token',
      queueName: 'events',
      store: store,
    );
    sentBatches = [];
  });

  PostHogQueue buildQueue({
    required BatchSender sender,
    int flushAt = 20,
    int maxQueueSize = 1000,
    int maxBatchSize = 50,
    Duration flushInterval = const Duration(hours: 1),
  }) {
    return PostHogQueue(
      name: 'events',
      sender: sender,
      storage: storage,
      flushAt: flushAt,
      maxQueueSize: maxQueueSize,
      maxBatchSize: maxBatchSize,
      flushInterval: flushInterval,
      retryPolicy: PostHogRetryPolicy(),
    );
  }

  BatchSender succeedingSender() => (events) async {
        sentBatches.add(events);
        return const PostHogApiResult(success: true, statusCode: 200);
      };

  BatchSender failingSender({int? statusCode}) => (events) async {
        sentBatches.add(events);
        return PostHogApiResult(success: false, statusCode: statusCode);
      };

  group('PostHogQueue', () {
    test('persists every event it accepts', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);

      await queue.add({'event': 'a'});
      await queue.add({'event': 'b'});

      expect(queue.length, 2);
      expect(store.entries.length, 2);
    });

    test('flushes automatically once flushAt is reached', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 3);

      await queue.add({'event': 'a'});
      await queue.add({'event': 'b'});
      expect(sentBatches, isEmpty);

      await queue.add({'event': 'c'});
      await Future<void>.delayed(Duration.zero);

      expect(sentBatches.single.length, 3);
      expect(queue.length, 0);
    });

    test('clears persisted copies after a successful send', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);

      await queue.add({'event': 'a'});
      await queue.add({'event': 'b'});
      await queue.flush();

      expect(queue.length, 0);
      expect(store.entries, isEmpty);
    });

    test('splits a large backlog into maxBatchSize chunks', () async {
      final queue = buildQueue(
        sender: succeedingSender(),
        flushAt: 1000,
        maxBatchSize: 10,
      );

      for (var i = 0; i < 25; i++) {
        await queue.add({'event': 'e$i'});
      }
      await queue.flush();

      expect(sentBatches.map((b) => b.length), [10, 10, 5]);
      expect(queue.length, 0);
    });

    // Ma'lumot yo'qolishining oldini olish — eng muhim xatti-harakat.
    test('keeps events queued when the network fails', () async {
      final queue = buildQueue(sender: failingSender(), flushAt: 100);

      await queue.add({'event': 'a'});
      await queue.add({'event': 'b'});
      await queue.flush();

      expect(queue.length, 2, reason: 'events must stay queued');
      expect(store.entries.length, 2, reason: 'the on-disk copy must be kept');
    });

    test('retries a previously failed batch on the next flush', () async {
      var shouldFail = true;
      final queue = buildQueue(
        sender: (events) async {
          sentBatches.add(events);
          if (shouldFail) {
            return const PostHogApiResult(success: false);
          }
          return const PostHogApiResult(success: true, statusCode: 200);
        },
        flushAt: 100,
      );

      await queue.add({'event': 'a'});
      await queue.flush();
      expect(queue.length, 1);

      shouldFail = false;
      // Wait out the backoff pause (~1s after the first failure).
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await queue.flush();

      expect(queue.length, 0);
      expect(store.entries, isEmpty);
    });

    // 4xx means the request itself is wrong; resending would loop forever.
    test('drops a batch rejected with 4xx instead of looping forever',
        () async {
      final queue = buildQueue(
        sender: failingSender(statusCode: 400),
        flushAt: 100,
      );

      await queue.add({'event': 'a'});
      await queue.flush();

      expect(queue.length, 0);
      expect(store.entries, isEmpty);
      expect(sentBatches.length, 1, reason: 'must not be retried');
    });

    test('retries a 429 rate-limit response', () async {
      final queue = buildQueue(
        sender: failingSender(statusCode: 429),
        flushAt: 100,
      );

      await queue.add({'event': 'a'});
      await queue.flush();

      expect(queue.length, 1, reason: '429 is transient, so it must be retained');
    });

    test('retries a 5xx server error', () async {
      final queue = buildQueue(
        sender: failingSender(statusCode: 503),
        flushAt: 100,
      );

      await queue.add({'event': 'a'});
      await queue.flush();

      expect(queue.length, 1);
    });

    test('drops the oldest events once maxQueueSize is exceeded', () async {
      final queue = buildQueue(
        sender: succeedingSender(),
        flushAt: 1000,
        maxQueueSize: 3,
      );

      for (var i = 0; i < 5; i++) {
        await queue.add({'event': 'e$i'});
      }

      expect(queue.length, 3);
      expect(store.entries.length, 3);

      await queue.flush();

      // Eng eski ikkitasi (e0, e1) tashlangan.
      expect(
        sentBatches.single.map((e) => e['event']),
        ['e2', 'e3', 'e4'],
      );
    });

    test('restores persisted events on start, oldest first', () async {
      final first = buildQueue(sender: failingSender(), flushAt: 100);
      await first.add({'event': 'a'});
      await first.add({'event': 'b'});
      await first.add({'event': 'c'});

      // A fresh queue, as if the app had restarted.
      sentBatches = [];
      final second = buildQueue(sender: succeedingSender(), flushAt: 1000);
      await second.start();

      expect(second.length, 3);

      await second.flush();

      expect(
        sentBatches.single.map((e) => e['event']),
        ['a', 'b', 'c'],
        reason: 'ordering must be preserved',
      );

      await second.close();
    });

    test('keeps the event in memory when the disk write fails', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);
      store.failWrites = true;

      await queue.add({'event': 'a'});

      // The write to disk failed, but the event was not lost.
      expect(queue.length, 1);
      expect(store.entries, isEmpty);

      await queue.flush();
      expect(sentBatches.single.length, 1);
    });

    test('clear() empties both memory and disk', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);

      await queue.add({'event': 'a'});
      await queue.clear();

      expect(queue.length, 0);
      expect(store.entries, isEmpty);
    });

    test('close() flushes what is still queued', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);

      await queue.add({'event': 'a'});
      await queue.close();

      expect(sentBatches.single.length, 1);
      expect(queue.length, 0);
    });

    test('ignores events added after close()', () async {
      final queue = buildQueue(sender: succeedingSender(), flushAt: 100);
      await queue.close();

      await queue.add({'event': 'a'});

      expect(queue.length, 0);
    });

    test('does not send concurrent flushes', () async {
      final completer = Completer<PostHogApiResult>();
      var callCount = 0;
      final queue = buildQueue(
        sender: (events) {
          callCount++;
          return completer.future;
        },
        flushAt: 1000,
      );

      await queue.add({'event': 'a'});

      final firstFlush = queue.flush();
      await queue.flush(); // the first has not finished, so this is skipped

      expect(callCount, 1);

      completer.complete(const PostHogApiResult(success: true, statusCode: 200));
      await firstFlush;
    });

    test('does nothing when the queue is empty', () async {
      final queue = buildQueue(sender: succeedingSender());

      await queue.flush();

      expect(sentBatches, isEmpty);
    });
  });

  group('PostHogQueueStorage', () {
    test('round-trips an event through the store', () async {
      await storage.persist('id-1', {'event': 'a', 'properties': {'x': 1}});

      final loaded = await storage.loadAll();

      expect(loaded.single.id, 'id-1');
      expect(loaded.single.event['event'], 'a');
    });

    test('returns events sorted by id', () async {
      await storage.persist('id-3', {'event': 'c'});
      await storage.persist('id-1', {'event': 'a'});
      await storage.persist('id-2', {'event': 'b'});

      final loaded = await storage.loadAll();

      expect(loaded.map((e) => e.event['event']), ['a', 'b', 'c']);
    });

    // A partially written file must not occupy the queue forever.
    test('discards corrupted entries instead of failing the whole load',
        () async {
      await storage.persist('id-1', {'event': 'a'});
      store.entries['id-2'] = '{"event": "truncated';
      await storage.persist('id-3', {'event': 'c'});

      final loaded = await storage.loadAll();

      expect(loaded.map((e) => e.event['event']), ['a', 'c']);
      expect(store.entries.containsKey('id-2'), isFalse);
    });

    test('removes the requested ids', () async {
      await storage.persist('id-1', {'event': 'a'});
      await storage.persist('id-2', {'event': 'b'});

      await storage.remove(['id-1']);

      final loaded = await storage.loadAll();
      expect(loaded.single.event['event'], 'b');
    });

    test('reports a failed persist without throwing', () async {
      store.failWrites = true;

      final result = await storage.persist('id-1', {'event': 'a'});

      expect(result, isNull);
    });
  });
}
