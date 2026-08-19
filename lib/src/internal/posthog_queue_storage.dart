import 'dart:async';
import 'dart:convert';

import '../util/logging.dart';
import 'storage/queue_file_store.dart'
    if (dart.library.js_interop) 'storage/queue_memory_store.dart';

/// On-disk persistence for the queue.
///
/// Differs from PostHog upstream: this was the native SDK's job
/// (`cacheDir/posthog-disk-queue` in `posthog-android`). Pure Dart reproduces
/// the same scheme: **one file = one event**, named with a UUIDv7.
///
/// One file per event is deliberate. With a single large file, a process death
/// mid-write (a crash, the user closing the app) would corrupt the entire
/// queue. With separate files only the last, partially written one is lost.
///
/// Because the file name is a UUIDv7, lexicographic sorting equals
/// chronological sorting, so events are read back off disk in the right
/// order.
class PostHogQueueStorage {
  PostHogQueueStorage({
    required this.projectToken,
    required this.queueName,
    QueueStore? store,
  }) : _store = store ?? createQueueStore();

  /// Project token, which keeps queues for different projects apart.
  final String projectToken;

  /// Navbat nomi: `events`, `replay`, `logs`.
  final String queueName;

  final QueueStore _store;

  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _store.initialize(projectToken: projectToken, queueName: queueName);
    _initialized = true;
  }

  /// Writes the event to disk and returns its identifier.
  ///
  /// Returns `null` on failure — the event stays in the in-memory queue but is
  /// not restored across an app restart. For analytics that is preferable to
  /// throwing.
  Future<String?> persist(String id, Map<String, Object?> event) async {
    try {
      await _ensureInitialized();
      await _store.write(id, jsonEncode(event));
      return id;
    } catch (e) {
      printIfDebug('[PostHog] could not write event to disk: $e');
      return null;
    }
  }

  /// Reads the persisted events back in chronological order.
  ///
  /// Corrupt files (partially written JSON) are deleted silently — they can
  /// never be sent and must not occupy the queue forever.
  Future<List<PersistedEvent>> loadAll() async {
    try {
      await _ensureInitialized();
      final ids = await _store.listIds();
      ids.sort(); // UUIDv7 => leksikografik tartib = xronologik tartib

      final result = <PersistedEvent>[];
      for (final id in ids) {
        try {
          final content = await _store.read(id);
          if (content == null) continue;
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            result.add(PersistedEvent(id: id, event: decoded));
          } else {
            await _store.delete(id);
          }
        } catch (e) {
          printIfDebug('[PostHog] deleted corrupt queue file ($id): $e');
          await _store.delete(id);
        }
      }
      return result;
    } catch (e) {
      printIfDebug('[PostHog] could not read the queue from disk: $e');
      return const [];
    }
  }

  /// Yuborilgan yoki tashlab yuborilgan eventlarni o'chiradi.
  Future<void> remove(Iterable<String> ids) async {
    try {
      await _ensureInitialized();
      for (final id in ids) {
        await _store.delete(id);
      }
    } catch (e) {
      printIfDebug('[PostHog] could not delete queue files: $e');
    }
  }

  /// Butun navbatni tozalaydi (`reset()` chaqirilganda).
  Future<void> clear() async {
    try {
      await _ensureInitialized();
      await _store.clear();
    } catch (e) {
      printIfDebug('[PostHog] could not clear the queue: $e');
    }
  }
}

/// Diskdan o'qilgan event.
class PersistedEvent {
  const PersistedEvent({required this.id, required this.event});

  final String id;
  final Map<String, dynamic> event;
}

/// Platformaga xos saqlash mexanizmi.
///
/// IO platformalarida (Windows, Linux, macOS, Android, iOS) fayl tizimi,
/// web'da xotira ishlatiladi.
abstract class QueueStore {
  Future<void> initialize({
    required String projectToken,
    required String queueName,
  });

  Future<void> write(String id, String content);

  Future<String?> read(String id);

  Future<List<String>> listIds();

  Future<void> delete(String id);

  Future<void> clear();
}
