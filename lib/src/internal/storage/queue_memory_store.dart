import '../posthog_queue_storage.dart';

QueueStore createQueueStore() => MemoryQueueStore();

/// In-memory queue for web.
///
/// Differs from PostHog upstream: the official plugin handed web to posthog-js,
/// which used `localStorage`. Here the queue lives in memory: unsent events are
/// lost when the page reloads.
///
/// This is a deliberate trade-off. `localStorage` is a synchronous API with a
/// small quota (typically 5 MB), and filling it up could corrupt the host app's
/// own data. On web `flushAt` usually triggers quickly, so the window of
/// exposure is short.
class MemoryQueueStore implements QueueStore {
  final Map<String, String> _entries = {};

  @override
  Future<void> initialize({
    required String projectToken,
    required String queueName,
  }) async {}

  @override
  Future<void> write(String id, String content) async {
    _entries[id] = content;
  }

  @override
  Future<String?> read(String id) async => _entries[id];

  @override
  Future<List<String>> listIds() async => _entries.keys.toList();

  @override
  Future<void> delete(String id) async {
    _entries.remove(id);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}
