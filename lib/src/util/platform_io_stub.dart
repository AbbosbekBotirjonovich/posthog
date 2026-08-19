import 'package:flutter/foundation.dart';

// Differs from PostHog upstream: on web the official plugin returned `kIsWeb`
// here, so support hinged on a native channel being present. With a pure-Dart
// transport, web behaves like every other platform.
bool isSupportedPlatform() {
  return true;
}

bool isMacOS() {
  return false;
}

/// Device type, for the `$device_type` property.
String get platformDeviceType => 'Web';

/// The `$os_name` property. The exact OS is unknown on web.
String get platformOsName => 'Web';

/// The `$os_version` property. Unavailable on web.
String get platformOsVersion => '';

/// The `$locale` property, read through `dart:ui` on web.
String get platformLocale =>
    PlatformDispatcher.instance.locale.toLanguageTag();
