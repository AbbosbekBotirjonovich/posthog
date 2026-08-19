import 'package:flutter/widgets.dart';

// Differs from PostHog upstream: on web the official plugin forwarded masking
// to posthog-js's `maskRegionsFn` API — it computed the Flutter mask rects and
// handed them to the browser's `window.posthog` object, because posthog-js
// drove the recording on web (`WebCanvasMaskProvider`).
//
// Here web uses the same pure-Dart screenshot pipeline as every other
// platform: `PostHogMaskWidget` masks are painted straight onto the canvas by
// `ScreenshotCapturer`. No separate web registration mechanism is needed, so
// this file is a no-op just like its IO counterpart.
void notifyMaskWidgetMounted(BuildContext context) {}

void notifyMaskWidgetUnmounted(BuildContext context) {}
