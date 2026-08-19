import 'package:flutter/foundation.dart';

import 'package:posthog/src/posthog_flutter_platform_interface.dart';
import 'package:posthog/src/posthog_http.dart';
import 'package:posthog/src/util/logging.dart';

/// Connects the replay pipeline to the transport.
///
/// Differs from PostHog upstream: in the official plugin this class called
/// into the native SDK over `MethodChannel('posthog_flutter')`, which built
/// the rrweb event there. In this implementation the calls are routed to
/// [PosthogHttp] and the `$snapshot` event is built in Dart.
///
/// The class name and method signatures are deliberately unchanged — the rest
/// of the replay pipeline was copied from the official plugin as-is.
class NativeCommunicator {
  const NativeCommunicator();

  PosthogHttp? get _http {
    final instance = PosthogFlutterPlatformInterface.instance;
    return instance is PosthogHttp ? instance : null;
  }

  Future<void> sendFullSnapshot(
    Uint8List imageBytes, {
    required int id,
    required int x,
    required int y,
  }) async {
    try {
      await _http?.sendReplayFullSnapshot(imageBytes, id: id, x: x, y: y);
    } catch (e) {
      printIfDebug('Error sending full snapshot: $e');
    }
  }

  Future<void> sendMetaEvent({
    required int width,
    required int height,
    required String? screen,
  }) async {
    try {
      await _http?.sendReplayMetaEvent(
        width: width,
        height: height,
        screen: screen,
      );
    } catch (e) {
      printIfDebug('Error sending meta event: $e');
    }
  }

  Future<bool> isSessionReplayActive() async {
    try {
      return await PosthogFlutterPlatformInterface.instance
          .isSessionReplayActive();
    } catch (e) {
      printIfDebug('Error checking session replay status: $e');
      return false;
    }
  }

  /// Differs from PostHog upstream: capturing native platform views requires
  /// the native SDK and is impossible in pure Dart. Always returns `null` —
  /// the calling code already handles that case by covering the view with a
  /// black mask.
  Future<List<Uint8List?>> captureNativeScreenshots(
    List<Map<String, int>> views,
  ) async {
    return List.filled(views.length, null);
  }

  /// Differs from PostHog upstream: the native occlusion bridge does not work
  /// without the native SDK. Always `false` — the calling code falls back to a
  /// black placeholder frame, which guarantees occluded screen content never
  /// reaches the replay.
  Future<bool> enableNativeBridge({required int episode}) async => false;
}
