import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../posthog_queue_storage.dart';

QueueStore createQueueStore() => FileQueueStore();

/// Filesystem-backed queue for Windows, Linux, macOS, Android and iOS.
///
/// On Windows `path_provider` returns `%APPDATA%`; elsewhere the matching
/// application support directory. The support directory is used rather than the
/// cache directory: the OS may clear the cache at any time, which would lose
/// events that have not been sent yet.
class FileQueueStore implements QueueStore {
  Directory? _directory;

  @override
  Future<void> initialize({
    required String projectToken,
    required String queueName,
  }) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/posthog/$projectToken/$queueName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _directory = dir;
  }

  @override
  Future<void> write(String id, String content) async {
    final dir = _directory;
    if (dir == null) return;
    // Write to a temporary file first, then rename: a partially written file
    // never appears with the `.event` extension, so reads never encounter
    // corrupt JSON.
    final temp = File('${dir.path}/$id.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename('${dir.path}/$id.event');
  }

  @override
  Future<String?> read(String id) async {
    final dir = _directory;
    if (dir == null) return null;
    final file = File('${dir.path}/$id.event');
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<List<String>> listIds() async {
    final dir = _directory;
    if (dir == null) return const [];
    if (!await dir.exists()) return const [];

    final ids = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.event')) {
        ids.add(name.substring(0, name.length - '.event'.length));
      } else if (name.endsWith('.tmp')) {
        // Oldingi ishga tushishdan qolgan chala fayl — yuborilmaydi.
        await entity.delete().catchError((_) => entity);
      }
    }
    return ids;
  }

  @override
  Future<void> delete(String id) async {
    final dir = _directory;
    if (dir == null) return;
    final file = File('${dir.path}/$id.event');
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> clear() async {
    final dir = _directory;
    if (dir == null) return;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}
