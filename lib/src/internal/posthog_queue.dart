import 'dart:async';
import 'dart:collection';

import '../util/logging.dart';
import 'posthog_api.dart';
import 'posthog_queue_storage.dart';
import 'posthog_retry_policy.dart';
import 'posthog_uuid.dart';

/// A single entry in the queue.
class _QueueEntry {
  _QueueEntry({required this.id, required this.event});

  final String id;
  final Map<String, Object?> event;
}

/// Batch yuborishni bajaruvchi funksiya.
typedef BatchSender = Future<PostHogApiResult> Function(
  List<Map<String, Object?>> events,
);

/// Queue that accumulates events, persists them to disk and sends them in
/// batches.
///
/// Differs from PostHog upstream: the pure-Dart equivalent of `PostHogQueue`
/// in `posthog-android`. One instance is created per endpoint (events, replay,
/// logs), since each has a different size and throughput profile.
class PostHogQueue {
  PostHogQueue({
    required this.name,
    required BatchSender sender,
    required PostHogQueueStorage storage,
    this.flushAt = 20,
    this.maxQueueSize = 1000,
    this.maxBatchSize = 50,
    this.flushInterval = const Duration(seconds: 30),
    PostHogRetryPolicy? retryPolicy,
  })  : _sender = sender,
        _storage = storage,
        _retryPolicy = retryPolicy ?? PostHogRetryPolicy();

  /// Queue name, used in log messages.
  final String name;

  final BatchSender _sender;
  final PostHogQueueStorage _storage;
  final PostHogRetryPolicy _retryPolicy;

  /// Shu miqdorga yetganda avtomatik flush boshlanadi.
  final int flushAt;

  /// Navbatning maksimal hajmi. Oshsa eng eski eventlar tashlanadi.
  final int maxQueueSize;

  /// Maximum number of events per request.
  final int maxBatchSize;

  /// Davriy flush oralig'i.
  final Duration flushInterval;

  final Queue<_QueueEntry> _queue = Queue<_QueueEntry>();

  Timer? _timer;
  bool _flushing = false;
  bool _closed = false;

  /// Navbatdagi eventlar soni.
  int get length => _queue.length;

  /// Starts the queue and restores events from disk.
  Future<void> start() async {
    if (_closed) return;

    // Events left over from a previous session go to the front of the queue,
    // because they must be sent before any new ones.
    final persisted = await _storage.loadAll();
    if (persisted.isNotEmpty) {
      final restored = persisted
          .map((e) => _QueueEntry(id: e.id, event: e.event))
          .toList();
      // Teskari tartibda `addFirst` — natijada asl tartib saqlanadi.
      for (final entry in restored.reversed) {
        _queue.addFirst(entry);
      }
      printIfDebug(
        '[PostHog] $name queue: restored ${restored.length} event(s) from disk',
      );
    }

    _timer?.cancel();
    _timer = Timer.periodic(flushInterval, (_) => flush());

    if (_queue.length >= flushAt) {
      unawaited(flush());
    }
  }

  /// Adds an event to the queue.
  Future<void> add(Map<String, Object?> event) async {
    if (_closed) return;

    final id = PostHogUuid.generate();
    _queue.add(_QueueEntry(id: id, event: event));
    await _storage.persist(id, event);

    // The queue is full, so the oldest entries are dropped. Newer events are
    // usually more valuable, because they reflect the current state.
    if (_queue.length > maxQueueSize) {
      final dropped = <String>[];
      while (_queue.length > maxQueueSize) {
        dropped.add(_queue.removeFirst().id);
      }
      await _storage.remove(dropped);
      printIfDebug(
        '[PostHog] $name queue is full, dropped ${dropped.length} '
        'old event(s)',
      );
    }

    if (_queue.length >= flushAt) {
      unawaited(flush());
    }
  }

  /// Sends the queued events.
  ///
  /// Never throws. On failure the events stay in the queue and are retried on
  /// the next attempt.
  Future<void> flush() async {
    if (_closed || _flushing || _queue.isEmpty) return;
    if (!_retryPolicy.canAttempt()) {
      printIfDebug(
        '[PostHog] $name queue is paused, '
        '${_retryPolicy.remainingDelay().inSeconds}s remaining',
      );
      return;
    }

    _flushing = true;
    try {
      // Send consecutive batches until the queue drains, but stop on any
      // failure — otherwise an offline run would pointlessly cycle through
      // the entire queue.
      while (_queue.isNotEmpty && _retryPolicy.canAttempt()) {
        final batchSize =
            _queue.length < maxBatchSize ? _queue.length : maxBatchSize;
        final batch = _queue.take(batchSize).toList();

        final result = await _sender(batch.map((e) => e.event).toList());

        if (result.success) {
          _retryPolicy.onSuccess();
          for (var i = 0; i < batch.length; i++) {
            _queue.removeFirst();
          }
          await _storage.remove(batch.map((e) => e.id));
        } else if (result.isRetriable) {
          final delay = _retryPolicy.onFailure(
            retryAfterSeconds: result.retryAfterSeconds,
          );
          printIfDebug(
            '[PostHog] $name queue: send failed, '
            'retrying in ${delay.inMilliseconds}ms',
          );
          break;
        } else {
          // 4xx: the request itself is at fault. Resending would loop
          // forever, so this batch is dropped.
          printIfDebug(
            '[PostHog] $name queue: HTTP ${result.statusCode} — '
            'dropped ${batch.length} event(s) (not retriable)',
          );
          for (var i = 0; i < batch.length; i++) {
            _queue.removeFirst();
          }
          await _storage.remove(batch.map((e) => e.id));
          _retryPolicy.onSuccess();
        }
      }
    } catch (e) {
      printIfDebug('[PostHog] unexpected error flushing $name queue: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Clears the queue entirely, including its on-disk copy.
  Future<void> clear() async {
    _queue.clear();
    await _storage.clear();
    _retryPolicy.reset();
  }

  /// Navbatni to'xtatadi va qolgan eventlarni yuborishga urinadi.
  Future<void> close() async {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    await flush();
    _closed = true;
  }
}
