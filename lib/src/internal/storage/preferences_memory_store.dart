import 'package:web/web.dart' as web;

import '../posthog_preferences.dart';

PreferencesStore createPreferencesStore() => WebPreferencesStore();

/// Persists SDK state in `localStorage` on web.
///
/// Even though the queue (`queue_memory_store.dart`) stays in memory, state is
/// persisted here: it is small (a few kilobytes) and losing it would count the
/// user as a brand-new anonymous person on every page reload, which corrupts
/// the analytics.
///
/// When `localStorage` is unavailable (private mode, restrictions) it falls
/// back to memory: the SDK keeps working, only the state does not outlive the
/// session.
class WebPreferencesStore implements PreferencesStore {
  String _key = 'posthog_state';
  String? _fallback;

  @override
  Future<void> initialize({required String projectToken}) async {
    _key = 'posthog_state_$projectToken';
  }

  @override
  Future<String?> read() async {
    try {
      return web.window.localStorage.getItem(_key);
    } catch (_) {
      return _fallback;
    }
  }

  @override
  Future<void> write(String content) async {
    try {
      web.window.localStorage.setItem(_key, content);
    } catch (_) {
      _fallback = content;
    }
  }
}
