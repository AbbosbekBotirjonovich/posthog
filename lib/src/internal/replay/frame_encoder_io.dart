import 'dart:isolate';
import 'dart:typed_data';

import 'frame_encoder.dart';

/// Re-encodes a frame on a separate isolate.
///
/// Encoding a full-HD frame takes roughly 180 ms of pure CPU time. Running it
/// on the UI thread would drop about eleven frames every time a snapshot is
/// captured, so the work is moved off the main isolate entirely. The cost is
/// copying the byte buffers between isolates, which is negligible next to the
/// encode itself.
Future<EncodedFrame?> encodeFrame(Uint8List pngBytes, int quality) {
  return Isolate.run(() => encodeFrameSync(pngBytes, quality));
}
