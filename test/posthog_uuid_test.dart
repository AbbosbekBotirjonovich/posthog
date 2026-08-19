import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/posthog_uuid.dart';

void main() {
  group('PostHogUuid', () {
    test('generates a well-formed v7 UUID', () {
      final uuid = PostHogUuid.generate();

      expect(
        uuid,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('never repeats', () {
      final ids = List.generate(10000, (_) => PostHogUuid.generate());

      expect(ids.toSet().length, ids.length);
    });

    // Decisive for the queue's correctness: files are sorted by name, so ids
    // must increase over time.
    test('sorts lexicographically in generation order', () {
      final ids = List.generate(5000, (_) => PostHogUuid.generate());
      final sorted = [...ids]..sort();

      expect(ids, equals(sorted));
    });

    test('stays ordered across a millisecond boundary', () async {
      final before = List.generate(100, (_) => PostHogUuid.generate());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final after = List.generate(100, (_) => PostHogUuid.generate());

      final all = [...before, ...after];
      final sorted = [...all]..sort();

      expect(all, equals(sorted));
    });

    test('embeds the creation timestamp', () {
      final before = DateTime.now();
      final uuid = PostHogUuid.generate();
      final after = DateTime.now();

      final timestamp = PostHogUuid.timestampOf(uuid);

      expect(timestamp, isNotNull);
      // Millisecond precision, so the bounds are widened.
      expect(
        timestamp!.millisecondsSinceEpoch,
        greaterThanOrEqualTo(before.millisecondsSinceEpoch - 1),
      );
      expect(
        timestamp.millisecondsSinceEpoch,
        lessThanOrEqualTo(after.millisecondsSinceEpoch + 1),
      );
    });

    test('returns null for a non-v7 identifier', () {
      // v4 UUID
      expect(
        PostHogUuid.timestampOf('f47ac10b-58cc-4372-a567-0e02b2c3d479'),
        isNull,
      );
      expect(PostHogUuid.timestampOf('not-a-uuid'), isNull);
      expect(PostHogUuid.timestampOf(''), isNull);
    });
  });
}
