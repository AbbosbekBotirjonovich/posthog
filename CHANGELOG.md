# Changelog

## 0.1.1

### Fixed

- **Session replay no longer stalls the UI.** Re-encoding a captured frame as
  JPEG is pure CPU work and ran on the UI thread: a 1920x1080 frame measured at
  ~183 ms, dropping roughly eleven frames every time a snapshot was taken. The
  encode now runs on a separate isolate through `Isolate.run`, leaving the
  calling isolate responsive. On web, where isolates do not exist, the previous
  behaviour is kept — session replay is not supported there anyway.

### Changed

- Translated all documentation and code comments to English: README, CHANGELOG,
  the package description, dartdoc comments across the public API, and the
  debug messages printed when `debug: true` is set.
- Rewrote the example app's README, which still carried the `flutter create`
  template, and translated the example's UI strings.

## 0.1.0

A pure-Dart reimplementation of the official `posthog_flutter` plugin
(v5.36.2). The primary goal is **Windows and Linux support**: because the
official plugin depends on the native SDKs, it silently degraded to a no-op on
those platforms.

### Added

- Pure-Dart HTTP transport: `/batch`, `/s/`, `/flags/?v=2`, remote config.
- On-disk queue: one file per event, ordering guaranteed by UUIDv7 naming.
  Events are persisted while offline and sent once the network returns.
- Exponential retry backoff (1s -> 30s) with jitter, honouring the
  `Retry-After` header.
- Identity management: anonymous id, `distinct_id`, merging through
  `$anon_distinct_id`, and bootstrap.
- Session management: 30-minute inactivity and 24-hour maximum duration rules;
  the session is cleared rather than rotated while in the background.
- Platform-specific context properties, **including Windows and Linux**
  (`$os_name`, `$device_type`, screen dimensions).
- Feature flags: loading, on-disk caching, last-known values while offline, and
  `$feature_flag_called` deduplication.
- Session replay: the rrweb `$snapshot` event is built in Dart, PNG frames are
  re-encoded as JPEG, and sampling is decided once per session.
- Surveys: loaded from remote config, targeting conditions evaluated in Dart,
  branching (`end`, `specific_question`, `response_based`), and the
  `survey shown` / `survey sent` / `survey dismissed` events.

### Fixed

- A survey question's `id` field was mistakenly read from `type`, which
  corrupted the `$survey_response_<id>` keys and let questions of the same type
  overwrite one another.
- Survey branching (`end`, `specific_question`, `response_based`) is now
  supported. In the official plugin this decision was made by the native SDK
  (a `surveyAction` MethodChannel call), and on web it did not work at all.
- Non-null casts while parsing the survey payload crashed on incomplete data;
  they now fall back to defaults.
- The package name was hardcoded in the stack-trace filter (`posthog_flutter`),
  so the SDK failed to recognise its own frames.

### Changed (differences from the official plugin)

- `beforeSend` now applies to **every** event. In the official SDK, events
  emitted by the native side bypassed it.
- The queue is never dropped during a long offline stretch. The official SDK
  called `dropAllRecords()` after three consecutive failures, erasing the
  entire queue.
- `Duration` settings keep sub-second precision (they used to be rounded up to
  1s because the native API expected whole seconds).

### Not supported

Features that require the native SDK are kept as no-ops for API compatibility:
the push notification methods, `pushIdentityProvider`, `captureNativeScreens`
and `captureNativeExceptions`. See the README for details.
