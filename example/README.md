# posthog_dart example

A demo app for the [`posthog_dart`](https://pub.dev/packages/posthog_dart)
package. It runs on Windows, Linux, macOS, Android, iOS and Web, and exercises
event capture, identify, screen views, feature flags, exception capture and
session replay masking.

## Running

The app needs a PostHog project API key, passed via `--dart-define`:

```bash
flutter run -d windows --dart-define=POSTHOG_KEY=phc_xxx
```

Replace `-d windows` with your target device. For the EU region or a
self-hosted instance, also pass the host:

```bash
flutter run --dart-define=POSTHOG_KEY=phc_xxx \
            --dart-define=POSTHOG_HOST=https://eu.i.posthog.com
```

Without `POSTHOG_KEY` the app still starts, but the SDK is not initialised and
nothing is sent.

## What to look for

Each button sends something to PostHog; the card at the top shows the current
`distinct_id` and `session_id`. Events should appear in your project's activity
feed within a few seconds.

The bottom card demonstrates `PostHogMaskWidget`: the card number inside it is
blacked out in session replay recordings.
