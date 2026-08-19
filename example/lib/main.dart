import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:posthog_dart/posthog_dart.dart';

/// Loyiha tokeni. Haqiqiy token bilan almashtiring yoki `--dart-define` bilan
/// bering:
///
/// ```
/// flutter run -d windows --dart-define=POSTHOG_KEY=phc_xxx
/// ```
const _projectToken = String.fromEnvironment(
  'POSTHOG_KEY',
  defaultValue: '',
);

const _host = String.fromEnvironment(
  'POSTHOG_HOST',
  defaultValue: 'https://us.i.posthog.com',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_projectToken.isEmpty) {
    debugPrint(
      'POSTHOG_KEY berilmagan — SDK ishga tushmaydi. '
      'Ishga tushirish: flutter run --dart-define=POSTHOG_KEY=phc_xxx',
    );
  } else {
    final config = PostHogConfig(_projectToken)
      ..host = _host
      ..debug = true
      ..captureApplicationLifecycleEvents = true
      // Kichik qiymat — namunada eventlar darhol yuborilsin.
      ..flushAt = 1;

    await Posthog().setup(config);
  }

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Session replay uchun butun ilova PostHogWidget bilan o'raladi.
    return PostHogWidget(
      child: MaterialApp(
        title: 'PostHog example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        // Ekran ko'rishlarini avtomatik yig'adi.
        navigatorObservers: [PosthogObserver()],
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Tayyor';
  String _distinctId = '';
  String _sessionId = '';

  @override
  void initState() {
    super.initState();
    _refreshIdentity();
  }

  Future<void> _refreshIdentity() async {
    final distinctId = await Posthog().getDistinctId();
    final sessionId = await Posthog().getSessionId();
    if (!mounted) return;
    setState(() {
      _distinctId = distinctId;
      _sessionId = sessionId ?? '(yo\'q)';
    });
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      if (!mounted) return;
      setState(() => _status = '$label ✓');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$label ✗ $e');
    }
    await _refreshIdentity();
  }

  String get _platformName {
    if (kIsWeb) return 'Web';
    return Platform.operatingSystem;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('PostHog — $_platformName')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Holat: $_status'),
                  const SizedBox(height: 8),
                  Text('distinct_id: $_distinctId'),
                  Text('session_id: $_sessionId'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => _run(
              'capture',
              () => Posthog().capture(
                eventName: 'tugma_bosildi',
                properties: {'manba': 'example', 'platforma': _platformName},
              ),
            ),
            child: const Text('Event yuborish'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => _run(
              'identify',
              () => Posthog().identify(
                userId: 'example-user',
                userProperties: {'plan': 'pro'},
              ),
            ),
            child: const Text('Identify'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => _run(
              'screen',
              () => Posthog().screen(screenName: 'Sozlamalar'),
            ),
            child: const Text('Screen eventi'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => _run('exception', () async {
              try {
                throw StateError('Namuna uchun ataylab chiqarilgan xato');
              } catch (e, s) {
                await Posthog().captureException(error: e, stackTrace: s);
              }
            }),
            child: const Text('Xato yuborish'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => _run('feature flag', () async {
              final enabled = await Posthog().isFeatureEnabled('example-flag');
              if (!mounted) return;
              setState(() => _status = 'example-flag: $enabled');
            }),
            child: const Text('Feature flag tekshirish'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run('flush', () => Posthog().flush()),
            child: const Text('Flush (darhol yuborish)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _run('reset', () => Posthog().reset()),
            child: const Text('Reset'),
          ),
          const SizedBox(height: 24),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Maskalash namunasi',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text('Quyidagi matn session replay\'da qora bilan qoplanadi:'),
                  SizedBox(height: 8),
                  PostHogMaskWidget(
                    child: Text('Karta raqami: 4111 1111 1111 1111'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
