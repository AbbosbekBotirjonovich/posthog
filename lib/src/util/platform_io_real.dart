import 'dart:io';

// Differs from PostHog upstream: the official plugin returned `false` here on
// Linux and Windows, because it depended on the posthog-android/posthog-ios
// native SDKs, which do not exist for those platforms. The whole SDK silently
// became a no-op as a result. This implementation uses a pure-Dart HTTP
// transport, so there is no platform restriction.
bool isSupportedPlatform() {
  return true;
}

bool isMacOS() {
  // Tests run on a macOS host but should not take macOS-specific branches.
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return false;
  }
  return Platform.isMacOS;
}

/// Device type, for the `$device_type` property.
///
/// PostHog convention: "Mobile" | "Tablet" | "Desktop" | "TV" | "Web".
String get platformDeviceType {
  if (Platform.isAndroid || Platform.isIOS) {
    return 'Mobile';
  }
  return 'Desktop';
}

/// The `$os_name` property. The PostHog backend expects these exact names.
String get platformOsName {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return Platform.operatingSystem;
}

/// `$os_version` propertysi.
String get platformOsVersion => Platform.operatingSystemVersion;

/// `$locale` propertysi, `{language}-{COUNTRY}` formatida.
String get platformLocale => Platform.localeName.replaceAll('_', '-');
