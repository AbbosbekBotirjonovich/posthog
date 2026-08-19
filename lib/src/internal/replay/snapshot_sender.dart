import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../util/logging.dart';
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

  /// To'liq kadrni yuboradi.
  Future<void> sendFullSnapshot(
    Uint8List imageBytes, {
    required int id,
    required int x,
    required int y,
  }) async {
    try {
      final encoded = _encode(imageBytes);
      if (encoded == null) return;

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

  /// PNG baytlarini JPEG base64 ga aylantiradi.
  _EncodedImage? _encode(Uint8List pngBytes) {
    try {
      final decoded = img.decodeImage(pngBytes);
      if (decoded == null) {
        printIfDebug('[PostHog] could not decode the frame');
        return null;
      }

      final jpeg = img.encodeJpg(decoded, quality: jpegQuality);
      return _EncodedImage(
        base64: base64Encode(jpeg),
        width: decoded.width,
        height: decoded.height,
      );
    } catch (e) {
      printIfDebug('[PostHog] error encoding the frame: $e');
      return null;
    }
  }
}

class _EncodedImage {
  const _EncodedImage({
    required this.base64,
    required this.width,
    required this.height,
  });

  final String base64;
  final int width;
  final int height;
}
