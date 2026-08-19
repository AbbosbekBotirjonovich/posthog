import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:posthog_dart/src/internal/replay/frame_encoder_web.dart'
    if (dart.library.io) 'package:posthog_dart/src/internal/replay/frame_encoder_io.dart';

Uint8List makePng(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, ((x + y) * 3) % 256);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('frame encoding', () {
    test('produces a base64 JPEG with the image dimensions', () async {
      final result = await encodeFrame(makePng(64, 48), 30);

      expect(result, isNotNull);
      expect(result!.width, 64);
      expect(result.height, 48);
      expect(result.base64, isNotEmpty);
    });

    test('returns null for bytes that are not an image', () async {
      final result = await encodeFrame(Uint8List.fromList([1, 2, 3, 4]), 30);

      expect(result, isNull);
    });

    test('a lower quality yields a smaller payload', () async {
      final png = makePng(200, 200);

      final high = await encodeFrame(png, 90);
      final low = await encodeFrame(png, 10);

      expect(low!.base64.length, lessThan(high!.base64.length));
    });

    // The whole point of moving the encode off the main isolate: the caller's
    // event loop must keep running while the frame is being compressed. If the
    // work ran inline, the timer below would not tick until encoding finished.
    test('leaves the calling isolate responsive while encoding', () async {
      var ticks = 0;
      final timer = Stream<void>.periodic(const Duration(milliseconds: 2))
          .listen((_) => ticks++);

      // Large enough that encoding takes far longer than a few timer ticks.
      await encodeFrame(makePng(1200, 900), 30);
      await timer.cancel();

      expect(
        ticks,
        greaterThan(3),
        reason: 'the event loop stalled, so encoding ran on this isolate',
      );
    });
  });
}
