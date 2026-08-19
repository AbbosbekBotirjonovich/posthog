import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../posthog_preferences.dart';

PreferencesStore createPreferencesStore() => FilePreferencesStore();

/// SDK holatini JSON faylda saqlaydi — Windows, Linux, macOS, Android, iOS.
class FilePreferencesStore implements PreferencesStore {
  File? _file;

  @override
  Future<void> initialize({required String projectToken}) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/posthog/$projectToken');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _file = File('${dir.path}/state.json');
  }

  @override
  Future<String?> read() async {
    final file = _file;
    if (file == null) return null;
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String content) async {
    final file = _file;
    if (file == null) return;
    // Write to a temporary file, then rename: if the process dies mid-write
    // the previous state stays intact and the user's identifier is not lost.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }
}
