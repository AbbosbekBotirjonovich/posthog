/// Public Flutter API for the PostHog SDK.
///
/// This package is API-compatible with the official `posthog_flutter` plugin,
/// but uses a pure-Dart HTTP transport instead of the native SDKs. As a result
/// it works fully on Windows and Linux, just as it does on Android/iOS/Web.
library posthog;

export 'src/feature_flag_result.dart';
export 'src/logs/posthog_log_record.dart';
export 'src/logs/posthog_log_severity.dart';
export 'src/logs/posthog_logger.dart' hide CaptureLog;
export 'src/posthog.dart';
export 'src/posthog_config.dart';
export 'src/posthog_event.dart';
export 'src/posthog_observer.dart';
export 'src/posthog_widget.dart';
export 'src/replay/mask/posthog_mask_widget.dart';
export 'src/replay/mask/posthog_platform_view.dart';
