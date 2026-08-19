# posthog_dart

[![pub package](https://img.shields.io/pub/v/posthog_dart.svg)](https://pub.dev/packages/posthog_dart)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A pure-Dart SDK for [PostHog](https://posthog.com) that works identically on
**Windows, Linux, Android, iOS, macOS and Web**.

The official [`posthog_flutter`](https://pub.dev/packages/posthog_flutter)
plugin is a wrapper around the `posthog-android` and `posthog-ios` native SDKs.
No native SDK exists for Windows or Linux, so on those platforms the plugin
**silently becomes a no-op**: the app runs without errors, but no analytics are
collected at all. This package does the same job in pure Dart, talking directly
to the PostHog HTTP API — with no native dependency.

The API matches the official plugin exactly, so **migrating is a matter of
changing one import line**.

## Platforms

| Feature | Android | iOS | macOS | Web | **Windows** | **Linux** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Event capture, identify, groups | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Feature flags | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Error tracking (Dart) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Session replay | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Surveys | ✅ | ✅ | ✅ | —¹ | ✅ | ✅ |
| Offline queue (on disk) | ✅ | ✅ | ✅ | —² | ✅ | ✅ |

¹ Use the PostHog JS SDK on web — the `surveys` setting is ignored there.
² On web the queue lives in memory; see [below](#data-storage).

Compared to the official plugin:

| | `posthog_flutter` | `posthog_dart` |
|---|---|---|
| Windows / Linux | ❌ silent no-op | ✅ full support |
| Native crashes (fatal) | ✅ | ❌ |
| Push notifications | ✅ | ❌ |

Unsupported features are kept as no-ops so API compatibility holds. See
[Limitations](#limitations).

## Installation

```yaml
dependencies:
  posthog_dart: ^0.1.0
```

## Getting started

```dart
import 'package:flutter/material.dart';
import 'package:posthog_dart/posthog_dart.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = PostHogConfig('<project_api_key>')
    ..host = 'https://us.i.posthog.com'
    ..captureApplicationLifecycleEvents = true;

  await Posthog().setup(config);

  runApp(const MyApp());
}
```

Find your API key in PostHog under **Project settings → Project API key**. For
the EU region set `host` to `https://eu.i.posthog.com`; for a self-hosted
instance, use your own domain.

To capture screen views automatically, install `PosthogObserver` (surveys
require it too):

```dart
MaterialApp(
  navigatorObservers: [PosthogObserver()],
  home: const HomePage(),
);
```

For session replay, wrap the app in `PostHogWidget`:

```dart
PostHogWidget(
  child: MaterialApp(...),
);
```

## Usage

### Events

```dart
await Posthog().capture(
  eventName: 'order_completed',
  properties: {'amount': 42.5, 'currency': 'USD'},
);

await Posthog().screen(screenName: 'Cart');
```

### Identity

```dart
await Posthog().identify(
  userId: 'user-123',
  userProperties: {'plan': 'pro'},
);

await Posthog().group(groupType: 'company', groupKey: 'acme');

// On sign-out — subsequent events attach to a fresh anonymous person.
await Posthog().reset();
```

### Feature flags

```dart
if (await Posthog().isFeatureEnabled('new_design')) {
  // ...
}

final variant = await Posthog().getFeatureFlag('button_colour');
final result = await Posthog().getFeatureFlagResult('new_design');

await Posthog().reloadFeatureFlags();
```

Flags are cached on disk, so the last known values are returned while offline.

### Errors and logs

```dart
try {
  await riskyOperation();
} catch (e, s) {
  await Posthog().captureException(error: e, stackTrace: s);
}

Posthog().logger.info('user signed in', {'method': 'google'});
Posthog().logger.error('payment failed', {'code': 'E001'});
```

To capture uncaught Dart errors automatically:

```dart
final config = PostHogConfig('<key>')
  ..errorTrackingConfig.captureFlutterErrors = true
  ..errorTrackingConfig.capturePlatformDispatcherErrors = true
  ..errorTrackingConfig.captureIsolateErrors = true;
```

### Super properties

```dart
await Posthog().register('app_stage', 'beta'); // added to every event
await Posthog().unregister('app_stage');
```

### Privacy

```dart
await Posthog().disable();  // stop collecting
await Posthog().enable();
```

To opt out from the start, set `config.optOut = true`.

To hide sensitive fields in session replay:

```dart
PostHogMaskWidget(
  child: Text('Card number: 4111 1111 1111 1111'),
);
```

## Configuration

```dart
final config = PostHogConfig('<key>')
  ..host = 'https://us.i.posthog.com'
  ..flushAt = 20
  ..flushInterval = const Duration(seconds: 30)
  ..sessionReplay = true
  ..debug = true;
```

| Setting | Default | Description |
|---|---|---|
| `host` | `https://us.i.posthog.com` | API endpoint (EU or self-hosted) |
| `flushAt` | `20` | Send once this many events are queued |
| `flushInterval` | `30s` | Time-based send interval |
| `maxQueueSize` | `1000` | Queue limit; the oldest events are dropped past it |
| `maxBatchSize` | `50` | Maximum events per request |
| `captureApplicationLifecycleEvents` | `true` | `Application Opened` and friends |
| `preloadFeatureFlags` | `true` | Load flags during `setup()` |
| `sendFeatureFlagEvents` | `true` | Emit `$feature_flag_called` |
| `sessionReplay` | `false` | Session replay |
| `surveys` | `true` | Surveys (ignored on web) |
| `personProfiles` | `identifiedOnly` | Whether anonymous events create profiles |
| `optOut` | `false` | Disable collection from the start |
| `debug` | `false` | Verbose console logging |

To rewrite or drop an event before it is sent:

```dart
config.beforeSend = [
  (event) => event.event == '\$screen' ? null : event, // dropped
];
```

## Migrating from the official plugin

Method names, parameter names and default values are **identical**. Change the
import:

```dart
// before
import 'package:posthog_flutter/posthog_flutter.dart';

// after
import 'package:posthog_dart/posthog_dart.dart';
```

And in `pubspec.yaml`:

```yaml
dependencies:
  # posthog_flutter: ^5.36.2
  posthog_dart: ^0.1.0
```

Nothing else changes. Native-side setup (Android `AndroidManifest.xml`, iOS
`Info.plist`) is no longer needed and can be removed.

Note: this package keeps its own `distinct_id` and queue. After migrating,
existing users are assigned a new anonymous id; if you need continuity, supply
the previous value through `config.bootstrap`.

## Limitations

The following require the native SDK and cannot be implemented in pure Dart.
They are kept as **no-ops** so API compatibility holds — existing code still
compiles, but nothing is sent:

- `registerPushNotificationToken()`, `unregisterPushNotificationToken()`,
  `capturePushNotificationOpened()` — FCM/APNs token registration
- `PostHogConfig.pushIdentityProvider`
- `PostHogSessionReplayConfig.captureNativeScreens` — capturing a native screen
  that covers the Flutter UI
- `PostHogErrorTrackingConfig.captureNativeExceptions` — native fatal crashes

Additionally:

- The **exception steps** buffer lives in Dart, so it does not survive a native
  fatal crash (in the official plugin it lived in the native SDK).
- **On web the queue is in memory**: unsent events are lost when the page
  reloads. User identity is still persisted, in `localStorage`.
- **Native platform views** are covered with a black mask in replay (capturing
  them requires the native SDK).

## Differences from the official plugin

Beyond Windows and Linux support:

- `beforeSend` applies to **every** event. In the official SDK, events emitted
  by the native side (`survey shown` and friends) bypassed it.
- Retry backoff has **jitter** added, so many devices coming back online at
  once do not surge the server.
- The queue is **never dropped** during a long offline stretch. The official SDK
  erased the entire queue after three consecutive failures.
- A survey model **bug is fixed**: a question's `id` was mistakenly read from
  `type`, which corrupted the response keys.
- Survey **branching** (`end`, `specific_question`, `response_based`) now works.
  In the official plugin the native SDK made that decision, and on web it was
  not supported at all.
- Parsing a survey payload **no longer crashes**: incomplete data falls back to
  defaults.
- `Duration` settings keep sub-second precision (they were rounded up because
  the native API expected whole seconds).

Every deliberate deviation is marked in the code with a
`// Differs from PostHog upstream:` comment.

## Data storage

| Platform | Queue | Identity and settings |
|---|---|---|
| Windows | `%APPDATA%/posthog/` | `%APPDATA%/posthog/state.json` |
| Linux / macOS | application support directory | `state.json` in that directory |
| Android / iOS | application support directory | `state.json` in that directory |
| Web | memory | `localStorage` |

The queue stores one file per event, named with a UUIDv7. That guarantees
ordering, and if the process dies mid-write only the last, partially written
event is lost.

Failed sends back off exponentially (1s → 30s, with jitter) and honour the
`Retry-After` header. 4xx responses are not retried; network errors and 5xx are.

## Example

The `example/` directory contains a full app that runs on Windows, Linux,
macOS, Android, iOS and Web:

```bash
cd example
flutter run -d windows --dart-define=POSTHOG_KEY=phc_xxx
```

## License

MIT. This package is based on the Dart code of the official
[`posthog-flutter`](https://github.com/PostHog/posthog-flutter) plugin
(MIT, © PostHog). Full attribution is in [LICENSE](LICENSE).

This is a community package and is not officially affiliated with PostHog Inc.
