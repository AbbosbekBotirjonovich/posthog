import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:posthog_dart/src/internal/replay/rrweb_models.dart';
import 'package:posthog_dart/src/internal/replay/snapshot_sender.dart';

/// Kichik haqiqiy PNG yasaydi — dekodlash yo'lini sinash uchun.
Uint8List makePng(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(120, 60, 200));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('rrweb event shakli', () {
    // Bu qiymatlar backend kutgani bilan aynan mos bo'lishi shart.
    test('uses the documented rrweb type numbers', () {
      expect(RREventType.fullSnapshot, 2);
      expect(RREventType.incrementalSnapshot, 3);
      expect(RREventType.meta, 4);
      expect(RREventType.custom, 5);
    });

    test('meta events describe the viewport', () {
      final event = RRWebEventBuilder.meta(
        width: 390,
        height: 844,
        screen: 'Checkout',
        timestampMs: 1700000000000,
      );

      expect(event['type'], RREventType.meta);
      expect(event['timestamp'], 1700000000000);

      final data = event['data'] as Map<String, Object?>;
      expect(data['width'], 390);
      expect(data['height'], 844);
      expect(data['href'], 'Checkout');
    });

    test('meta events fall back to an empty href', () {
      final event = RRWebEventBuilder.meta(
        width: 1,
        height: 1,
        screen: null,
        timestampMs: 0,
      );

      expect((event['data'] as Map)['href'], '');
    });

    test('full snapshots wrap a single wireframe', () {
      final event = RRWebEventBuilder.fullSnapshot(
        wireframe: const RRWireframe(
          id: 7,
          x: 1,
          y: 2,
          width: 100,
          height: 200,
          base64: 'AAAA',
        ),
        timestampMs: 1700000000000,
      );

      expect(event['type'], RREventType.fullSnapshot);

      final data = event['data'] as Map<String, Object?>;
      final wireframes = data['wireframes'] as List;
      expect(wireframes.length, 1);

      final wireframe = wireframes.single as Map<String, Object?>;
      expect(wireframe['id'], 7);
      expect(wireframe['x'], 1);
      expect(wireframe['y'], 2);
      expect(wireframe['width'], 100);
      expect(wireframe['height'], 200);
      expect(wireframe['base64'], 'AAAA');
      expect(wireframe['type'], 'screenshot');
      // Native SDK bo'sh style obyektini yuborardi; backend uni kutadi.
      expect(wireframe['style'], isA<Map>());
    });

    test('full snapshots carry an initial offset', () {
      final event = RRWebEventBuilder.fullSnapshot(
        wireframe: const RRWireframe(
          id: 1,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          base64: '',
        ),
        timestampMs: 0,
      );

      expect((event['data'] as Map)['initialOffset'], {'top': 0, 'left': 0});
    });

    test('every event survives JSON encoding', () {
      final meta = RRWebEventBuilder.meta(
        width: 10,
        height: 20,
        screen: 'S',
        timestampMs: 1,
      );
      final snapshot = RRWebEventBuilder.fullSnapshot(
        wireframe: const RRWireframe(
          id: 1,
          x: 0,
          y: 0,
          width: 10,
          height: 20,
          base64: 'QUJD',
        ),
        timestampMs: 2,
      );

      expect(() => jsonEncode([meta, snapshot]), returnsNormally);
    });
  });

  group('SnapshotSender', () {
    late List<Map<String, Object?>> sent;
    late SnapshotSender sender;

    setUp(() {
      sent = [];
      sender = SnapshotSender(enqueue: (event) async => sent.add(event));
    });

    test('emits a meta event', () async {
      await sender.sendMetaEvent(width: 390, height: 844, screen: 'Home');

      expect(sent.single['type'], RREventType.meta);
      expect((sent.single['data'] as Map)['width'], 390);
    });

    test('emits a full snapshot from PNG bytes', () async {
      await sender.sendFullSnapshot(makePng(40, 30), id: 5, x: 0, y: 0);

      final event = sent.single;
      expect(event['type'], RREventType.fullSnapshot);

      final wireframe =
          ((event['data'] as Map)['wireframes'] as List).single as Map;
      expect(wireframe['id'], 5);
      // O'lchamlar rasmdan olinadi, chaqiruvchidan emas.
      expect(wireframe['width'], 40);
      expect(wireframe['height'], 30);
    });

    // Flutter PNG chiqaradi (lossless, katta). Native SDK uni JPEG'ga
    // qayta kodlardi — trafikni bir necha barobar kamaytiradi.
    test('re-encodes the frame as JPEG', () async {
      await sender.sendFullSnapshot(makePng(40, 30), id: 1, x: 0, y: 0);

      final wireframe =
          ((sent.single['data'] as Map)['wireframes'] as List).single as Map;
      final bytes = base64Decode(wireframe['base64'] as String);

      // JPEG sehrli baytlari: FF D8 FF
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
      expect(bytes[2], 0xFF);
    });

    test('honors the wireframe position', () async {
      await sender.sendFullSnapshot(makePng(10, 10), id: 1, x: 15, y: 25);

      final wireframe =
          ((sent.single['data'] as Map)['wireframes'] as List).single as Map;
      expect(wireframe['x'], 15);
      expect(wireframe['y'], 25);
    });

    // Buzuq kadr SDK'ni yiqitmasligi kerak.
    test('drops an undecodable frame without throwing', () async {
      await sender.sendFullSnapshot(
        Uint8List.fromList([1, 2, 3, 4]),
        id: 1,
        x: 0,
        y: 0,
      );

      expect(sent, isEmpty);
    });

    test('produces a JSON-encodable payload', () async {
      await sender.sendFullSnapshot(makePng(20, 20), id: 1, x: 0, y: 0);

      expect(() => jsonEncode(sent.single), returnsNormally);
    });
  });
}
