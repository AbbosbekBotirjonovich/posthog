import 'dart:typed_data';

import '../../util/logging.dart';
import 'frame_encoder_web.dart'
    if (dart.library.io) 'frame_encoder_io.dart';
import 'rrweb_models.dart';

/// Builds `$snapshot` events and hands them to the queue.
///
/// Differs from PostHog upstream: this was done on the native side
/// (`SnapshotSender.kt` / `PosthogFlutterPlugin.swift`). Pure Dart builds the
/// very same JSON structure here.
class SnapshotSender {
  SnapshotSender({
    required Future<void> Function(Map<String, Object?> event) enqueue,
    this.jpegQuality = 30,
  }) : _enqueue = enqueue;

  final Future<void> Function(Map<String, Object?> event) _enqueue;

  /// JPEG compression quality.
  ///
  /// Flutter produces PNG (lossless, very large). The native SDK re-encoded it
  /// as JPEG, cutting traffic by 5-10x. Low quality is good enough for replay:
  /// frames are displayed at a small size.
  final int jpegQuality;

  /// Sends the meta event.
  ///
  /// Must be called **before** a full snapshot.
  Future<void> sendMetaEvent({
    required int width,
    required int height,
    required String? screen,
  }) async {
    try {
      await _enqueue(
        RRWebEventBuilder.meta(
          width: width,
          height: height,
          screen: screen,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      printIfDebug('[PostHog] meta event was not sent: $e');
    }
  }

  /// Sends a full frame.
  Future<void> sendFullSnapshot(
    Uint8List imageBytes, {
    required int id,
    required int x,
    required int y,
  }) async {
    try {
      // Encoding runs on a separate isolate: it is heavy CPU work and would
      // otherwise stall the UI thread for the duration of the frame.
      final encoded = await encodeFrame(imageBytes, jpegQuality);
      if (encoded == null) {
        printIfDebug('[PostHog] could not encode the frame');
        return;
      }

      await _enqueue(
        RRWebEventBuilder.fullSnapshot(
          wireframe: RRWireframe(
            id: id,
            x: x,
            y: y,
            width: encoded.width,
            height: encoded.height,
            base64: encoded.base64,
          ),
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      printIfDebug('[PostHog] full snapshot was not sent: $e');
    }
  }
}
