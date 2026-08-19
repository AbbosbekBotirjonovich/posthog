/// rrweb event types.
///
/// Differs from PostHog upstream: in the official plugin these types lived in
/// the native SDK (`RREventType` in `posthog-android`). In pure Dart they are
/// reproduced here — the values must match exactly what the backend expects.
class RREventType {
  RREventType._();

  static const domContentLoaded = 0;
  static const load = 1;
  static const fullSnapshot = 2;
  static const incrementalSnapshot = 3;
  static const meta = 4;
  static const custom = 5;
  static const plugin = 6;
}

/// Wireframe describing one screen frame.
///
/// In mobile replay the whole screen is sent as a single wireframe of type
/// `screenshot`, not as a DOM tree.
class RRWireframe {
  const RRWireframe({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.base64,
    this.type = 'screenshot',
  });

  final int id;
  final int x;
  final int y;
  final int width;
  final int height;

  /// Rasm — `data:` prefiksisiz base64.
  final String base64;

  final String type;

  Map<String, Object?> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'type': type,
        'base64': base64,
        // Native SDK bo'sh `RRStyle()` yuborardi; backend uni kutadi.
        'style': const <String, Object?>{},
      };
}

/// rrweb eventini quruvchi.
class RRWebEventBuilder {
  RRWebEventBuilder._();

  /// Meta event (`type: 4`).
  ///
  /// Declares the screen dimensions and must **always** be sent before a full
  /// snapshot — otherwise the player does not know what size to render the
  /// frame at.
  static Map<String, Object?> meta({
    required int width,
    required int height,
    required String? screen,
    required int timestampMs,
  }) {
    return {
      'type': RREventType.meta,
      'timestamp': timestampMs,
      'data': {
        'href': screen ?? '',
        'width': width,
        'height': height,
      },
    };
  }

  /// Full snapshot (`type: 2`).
  static Map<String, Object?> fullSnapshot({
    required RRWireframe wireframe,
    required int timestampMs,
  }) {
    return {
      'type': RREventType.fullSnapshot,
      'timestamp': timestampMs,
      'data': {
        'wireframes': [wireframe.toJson()],
        'initialOffset': const {'top': 0, 'left': 0},
      },
    };
  }
}
