import 'dart:math';

/// UUIDv7 generatori (RFC 9562).
///
/// Differs from PostHog upstream: in the official plugin this lived in the
/// native SDK (`TimeBasedEpochGenerator` in posthog-android). The pure-Dart
/// implementation provides the same guarantees here.
///
/// UUIDv7 is chosen for two reasons, both load-bearing for the SDK:
///
/// 1. **Monotonicity** — queue files are sorted by name, so ids must increase
///    over time. Otherwise events would be read off disk out of order and
///    reach PostHog in a scrambled sequence.
/// 2. **Embedded timestamp** — a session's creation time can be recovered from
///    the id itself.
///
/// Calls within the same millisecond bump a counter, so ordering holds even
/// under rapid back-to-back generation.
class PostHogUuid {
  PostHogUuid._();

  static final Random _random = Random.secure();

  /// Last millisecond used.
  static int _lastMillis = 0;

  /// Counter within one millisecond (12 bits, in the `rand_a` field).
  static int _counter = 0;

  /// Returns a new UUIDv7 in `8-4-4-4-12` form.
  static String generate() {
    var millis = DateTime.now().millisecondsSinceEpoch;

    if (millis == _lastMillis) {
      _counter++;
      // When the 12 bits are exhausted, move to the next millisecond. This
      // preserves monotonicity and keeps ids unique even if the clock steps
      // backwards.
      if (_counter > 0xFFF) {
        millis++;
        _lastMillis = millis;
        _counter = 0;
      }
    } else if (millis > _lastMillis) {
      _lastMillis = millis;
      _counter = 0;
    } else {
      // The clock stepped backwards (an NTP correction, or the user changing
      // the time). Continue from the last known time, otherwise a new id would
      // sort below an older one and break the queue's ordering.
      millis = _lastMillis;
      _counter++;
      if (_counter > 0xFFF) {
        _lastMillis = millis + 1;
        millis = _lastMillis;
        _counter = 0;
      }
    }

    final bytes = List<int>.filled(16, 0);

    // 48 bit: Unix epoch millisekundlari (big-endian).
    bytes[0] = (millis >> 40) & 0xFF;
    bytes[1] = (millis >> 32) & 0xFF;
    bytes[2] = (millis >> 24) & 0xFF;
    bytes[3] = (millis >> 16) & 0xFF;
    bytes[4] = (millis >> 8) & 0xFF;
    bytes[5] = millis & 0xFF;

    // 4 bit versiya (7) + 12 bit hisoblagich.
    bytes[6] = 0x70 | ((_counter >> 8) & 0x0F);
    bytes[7] = _counter & 0xFF;

    // 2 bit variant (0b10) + 62 bit tasodifiy.
    bytes[8] = 0x80 | (_random.nextInt(256) & 0x3F);
    for (var i = 9; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }

    return _format(bytes);
  }

  /// Extracts the creation time from a UUIDv7.
  ///
  /// Returns `null` for a value that is not a UUIDv7.
  static DateTime? timestampOf(String uuid) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) return null;
    final version = int.tryParse(hex.substring(12, 13), radix: 16);
    if (version != 7) return null;
    final millis = int.tryParse(hex.substring(0, 12), radix: 16);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static String _format(List<int> bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        buffer.write('-');
      }
      buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
