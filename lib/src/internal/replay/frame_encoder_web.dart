import 'dart:typed_data';

import 'frame_encoder.dart';

/// Re-encodes a frame on the current isolate.
///
/// Web has no isolates, so the work stays on the main thread. Session replay
/// is not supported on web anyway (`sessionReplay` is ignored there), so this
/// path exists only to keep the code compiling.
Future<EncodedFrame?> encodeFrame(Uint8List pngBytes, int quality) async {
  return encodeFrameSync(pngBytes, quality);
}
