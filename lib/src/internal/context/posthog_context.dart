import 'dart:ui' as ui;

import 'package:package_info_plus/package_info_plus.dart';

import '../../util/logging.dart';
import '../../util/platform_io_stub.dart'
    if (dart.library.io) '../../util/platform_io_real.dart';
import '../../posthog_flutter_version.dart';

/// Collects the context properties attached to every event.
///
/// Differs from PostHog upstream: mirrors `PostHogAndroidContext`
/// (`getStaticContext()` / `getDynamicContext()`) in `posthog-android`. The
/// Windows and Linux values are filled in here for the first time — the
/// official plugin did not support those platforms at all.
class PostHogContext {
  PostHogContext();

  Map<String, Object>? _staticContext;

  /// Properties computed once and cached.
  ///
  /// The app version and device model do not change while the app runs, so
  /// recomputing them for every event would be wasted work.
  Future<Map<String, Object>> staticContext() async {
    final cached = _staticContext;
    if (cached != null) return cached;

    final context = <String, Object>{};

    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) context['\$app_version'] = info.version;
      if (info.packageName.isNotEmpty) {
        context['\$app_namespace'] = info.packageName;
      }
      if (info.buildNumber.isNotEmpty) context['\$app_build'] = info.buildNumber;
      if (info.appName.isNotEmpty) context['\$app_name'] = info.appName;
    } catch (e) {
      // Send the rest of the context even when app info is unavailable.
      printIfDebug('[PostHog] could not read package info: $e');
    }

    context['\$os_name'] = platformOsName;
    final osVersion = platformOsVersion;
    if (osVersion.isNotEmpty) context['\$os_version'] = osVersion;
    context['\$device_type'] = platformDeviceType;

    final view = _primaryView();
    if (view != null) {
      final ratio = view.devicePixelRatio;
      context['\$screen_density'] = ratio;
      if (ratio > 0) {
        // Logical pixels — that is the PostHog convention.
        context['\$screen_width'] = (view.physicalSize.width / ratio).round();
        context['\$screen_height'] = (view.physicalSize.height / ratio).round();
      }
    }

    _staticContext = context;
    return context;
  }

  /// Properties recomputed for every event.
  Map<String, Object> dynamicContext() {
    final context = <String, Object>{};

    final locale = platformLocale;
    if (locale.isNotEmpty) context['\$locale'] = locale;

    try {
      context['\$timezone'] = DateTime.now().timeZoneName;
    } catch (_) {
      // Unavailable on some platforms — skipped.
    }

    return context;
  }

  /// SDK identity, present on every event including `$snapshot`.
  Map<String, Object> sdkInfo() {
    return {
      '\$lib': postHogFlutterSdkName,
      '\$lib_version': postHogFlutterVersion,
    };
  }

  /// Clears the cache, e.g. when the screen dimensions change.
  void invalidate() {
    _staticContext = null;
  }

  static ui.FlutterView? _primaryView() {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isEmpty) return null;
      return views.first;
    } catch (_) {
      return null;
    }
  }
}
