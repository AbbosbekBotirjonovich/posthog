import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Result of re-encoding one captured frame.
class EncodedFrame {
  const EncodedFrame({
    required this.base64,
    required this.width,
    required this.height,
  });

  final String base64;
  final int width;
  final int height;
}

/// Converts PNG bytes into a base64 JPEG.
///
/// This is pure CPU work and the single most expensive step in the replay
/// pipeline: a 1920x1080 frame costs roughly 180 ms. Callers must therefore
/// run it off the UI thread — see `encodeFrame` in `frame_encoder_io.dart`,
/// which hands this function to an isolate.
///
/// Returns `null` when the bytes cannot be decoded. It never throws, so a
/// corrupt frame cannot bring down the caller's isolate.
EncodedFrame? encodeFrameSync(Uint8List pngBytes, int quality) {
  try {
    final decoded = img.decodeImage(pngBytes);
    if (decoded == null) return null;

    final jpeg = img.encodeJpg(decoded, quality: quality);
    return EncodedFrame(
      base64: base64Encode(jpeg),
      width: decoded.width,
      height: decoded.height,
    );
  } catch (_) {
    return null;
  }
}
