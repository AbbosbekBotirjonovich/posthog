import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';

import 'posthog_flutter_platform_interface_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Posthog logs', () {
    late PosthogFlutterPlatformFake fake;

    setUp(() async {
      fake = PosthogFlutterPlatformFake();
      PosthogFlutterPlatformInterface.instance = fake;
      await Posthog().close();
    });

    Future<void> setupWith(PostHogConfig config) async {
      await Posthog().setup(config);
    }

    group('Public capture API', () {
      test('captureLog with explicit level forwards body and level', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(
          body: 'checkout failed',
          level: PostHogLogSeverity.error,
        );

        expect(fake.capturedLogs, hasLength(1));
        expect(fake.capturedLogs.single.body, 'checkout failed');
        expect(fake.capturedLogs.single.level, PostHogLogSeverity.error);
      });

      test('logger helper delegates to captureLog', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().logger.info('ready', {'region': 'us'});

        expect(fake.capturedLogs, hasLength(1));
        final call = fake.capturedLogs.single;
        expect(call.body, 'ready');
        expect(call.level, PostHogLogSeverity.info);
        expect(call.attributes, {'region': 'us'});
      });

      test('missing level defaults to info', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(body: 'hello');

        expect(fake.capturedLogs.single.level, PostHogLogSeverity.info);
      });

      final loggerByLevel =
          <PostHogLogSeverity, Future<void> Function(PostHogLogger)>{
        PostHogLogSeverity.trace: (l) => l.trace('m'),
        PostHogLogSeverity.debug: (l) => l.debug('m'),
        PostHogLogSeverity.info: (l) => l.info('m'),
        PostHogLogSeverity.warn: (l) => l.warn('m'),
        PostHogLogSeverity.error: (l) => l.error('m'),
        PostHogLogSeverity.fatal: (l) => l.fatal('m'),
      };
      loggerByLevel.forEach((level, call) {
        test('logger.${level.name} captures at ${level.name}', () async {
          await setupWith(PostHogConfig('test_token'));

          await call(Posthog().logger);

          expect(fake.capturedLogs.single.level, level);
        });
      });
    });

    group('Trace correlation fields', () {
      test('forwards traceId, spanId, and traceFlags', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(
          body: 'request finished',
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
          traceFlags: 1,
        );

        final call = fake.capturedLogs.single;
        expect(call.traceId, '4bf92f3577b34da6a3ce929d0e0e4736');
        expect(call.spanId, '00f067aa0ba902b7');
        expect(call.traceFlags, 1);
      });

      test('forwards an explicit traceFlags of 0 (sampled-false)', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(body: 'x', traceFlags: 0);

        expect(fake.capturedLogs.single.traceFlags, 0);
      });

      test('trace fields are null when not provided', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(body: 'x');

        final call = fake.capturedLogs.single;
        expect(call.traceId, isNull);
        expect(call.spanId, isNull);
        expect(call.traceFlags, isNull);
      });

      test('logger facade does not carry trace fields', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().logger.info('x');

        final call = fake.capturedLogs.single;
        expect(call.traceId, isNull);
        expect(call.spanId, isNull);
        expect(call.traceFlags, isNull);
      });
    });

    group('Capture-time gating', () {
      test('whitespace-only body is dropped', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(body: '   ');

        expect(fake.capturedLogs, isEmpty);
      });

      test('empty body is dropped', () async {
        await setupWith(PostHogConfig('test_token'));

        await Posthog().captureLog(body: '');

        expect(fake.capturedLogs, isEmpty);
      });
    });

    group('beforeSend hook', () {
      test('hook returning null drops the record', () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [(record) => null];
        await setupWith(config);

        await Posthog().captureLog(body: 'secret');

        expect(fake.capturedLogs, isEmpty);
      });

      test('hook can mutate body and attributes', () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [
          (record) {
            record.body = 'redacted';
            record.attributes = {'safe': true};
            return record;
          },
        ];
        await setupWith(config);

        await Posthog().captureLog(
          body: 'original',
          attributes: {'password': 'hunter2'},
        );

        expect(fake.capturedLogs.single.body, 'redacted');
        expect(fake.capturedLogs.single.attributes, {'safe': true});
      });

      test('hook blanking the body drops the record', () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [
          (record) {
            record.body = '   ';
            return record;
          },
        ];
        await setupWith(config);

        await Posthog().captureLog(body: 'original');

        expect(fake.capturedLogs, isEmpty);
      });

      test('throwing hook is contained and drops the log', () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [
          (record) => throw Exception('boom'),
        ];
        await setupWith(config);

        await Posthog().captureLog(body: 'dropped on throw');

        expect(fake.capturedLogs, isEmpty);
      });

      test('callbacks run left-to-right, feeding each output to the next',
          () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [
          (record) {
            record.body = '${record.body}-1';
            return record;
          },
          (record) {
            record.body = '${record.body}-2';
            return record;
          },
        ];
        await setupWith(config);

        await Posthog().captureLog(body: 'x');

        expect(fake.capturedLogs.single.body, 'x-1-2');
      });

      test('async hook is awaited', () async {
        final config = PostHogConfig('test_token');
        config.logsConfig.beforeSend = [
          (record) async {
            await Future<void>.delayed(Duration.zero);
            record.body = 'async';
            return record;
          },
        ];
        await setupWith(config);

        await Posthog().captureLog(body: 'x');

        expect(fake.capturedLogs.single.body, 'async');
      });
    });

    // PostHog upstream'dan farq: bu guruh `PostHogLogsConfig.toMap()`
    // serializatsiyasini tekshirardi. `toMap()` MethodChannel uchun edi va
    // olib tashlangan, shu sababli tekshiruvlar config maydonlarining o'ziga
    // qaratildi. Sub-soniyali `Duration`ni 1s ga yaxlitlash ham yo'q: u native
    // API butun sonli soniyalarni kutgani uchun kerak edi.
    group('PostHogLogsConfig', () {
      test('leaves identity fields unset and attributes empty by default', () {
        final config = PostHogConfig('test_token');

        expect(config.logsConfig.serviceName, isNull);
        expect(config.logsConfig.serviceVersion, isNull);
        expect(config.logsConfig.environment, isNull);
        expect(config.logsConfig.resourceAttributes, isEmpty);
      });

      test('holds set identity fields and attributes', () {
        final config = PostHogConfig('test_token');
        config.logsConfig
          ..serviceName = 'checkout'
          ..serviceVersion = '1.2.3'
          ..environment = 'production'
          ..resourceAttributes = {'region': 'us'};

        expect(config.logsConfig.serviceName, 'checkout');
        expect(config.logsConfig.serviceVersion, '1.2.3');
        expect(config.logsConfig.environment, 'production');
        expect(config.logsConfig.resourceAttributes, {'region': 'us'});
      });

      test('holds tuning knobs, keeping durations exact', () {
        final config = PostHogConfig('test_token');
        config.logsConfig
          ..flushInterval = const Duration(seconds: 15)
          ..flushAt = 5
          ..maxBatchSize = 25
          ..maxBufferSize = 200
          ..rateCapMaxLogs = 1000
          ..rateCapWindow = const Duration(seconds: 20);

        expect(config.logsConfig.flushInterval, const Duration(seconds: 15));
        expect(config.logsConfig.flushAt, 5);
        expect(config.logsConfig.maxBatchSize, 25);
        expect(config.logsConfig.maxBufferSize, 200);
        expect(config.logsConfig.rateCapMaxLogs, 1000);
        expect(config.logsConfig.rateCapWindow, const Duration(seconds: 20));
      });

      test('keeps sub-second flush/rate-cap durations intact', () {
        final config = PostHogConfig('test_token');
        config.logsConfig
          ..flushInterval = const Duration(milliseconds: 500)
          ..rateCapWindow = const Duration(milliseconds: 1);

        // Sof Dart taymerlari sub-soniyali oraliqni qo'llab-quvvatlaydi, shu
        // sababli qiymat 1s ga ko'tarilmaydi.
        expect(
          config.logsConfig.flushInterval,
          const Duration(milliseconds: 500),
        );
        expect(
          config.logsConfig.rateCapWindow,
          const Duration(milliseconds: 1),
        );
      });

      test('leaves the tuning knobs that were never set as null', () {
        final config = PostHogConfig('test_token');
        config.logsConfig
          ..flushAt = 5
          ..rateCapWindow = const Duration(seconds: 20);

        expect(config.logsConfig.flushAt, 5);
        expect(config.logsConfig.rateCapWindow, const Duration(seconds: 20));
        expect(config.logsConfig.flushInterval, isNull);
        expect(config.logsConfig.maxBatchSize, isNull);
        expect(config.logsConfig.maxBufferSize, isNull);
        expect(config.logsConfig.rateCapMaxLogs, isNull);
      });
    });
  });
}
