import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'package:url_launcher/url_launcher.dart';

import 'error_tracking/dart_exception_processor.dart';
import 'internal/replay/snapshot_sender.dart';
import 'internal/surveys/survey_branching.dart';
import 'internal/surveys/survey_targeting.dart';
import 'surveys/models/posthog_display_survey.dart' as models;
import 'surveys/models/posthog_display_survey_question.dart';
import 'surveys/models/survey_callbacks.dart';
import 'surveys/survey_service.dart';
import 'feature_flag_result.dart';
import 'internal/context/posthog_context.dart';
import 'internal/posthog_api.dart';
import 'internal/posthog_feature_flags.dart';
import 'internal/posthog_identity_manager.dart';
import 'internal/posthog_preferences.dart';
import 'internal/posthog_property_builder.dart';
import 'internal/posthog_queue.dart';
import 'internal/posthog_queue_storage.dart';
import 'internal/posthog_session_manager.dart';
import 'logs/posthog_log_severity.dart';
import 'posthog_config.dart';
import 'posthog_constants.dart';
import 'posthog_event.dart';
import 'posthog_flutter_platform_interface.dart';
import 'util/logging.dart';
import 'utils/before_send.dart';
import 'utils/capture_utils.dart';

/// Pure-Dart implementation of [PosthogFlutterPlatformInterface].
///
/// Differs from PostHog upstream: the official plugin's `PosthogFlutterIO`
/// delegated this work to the posthog-android / posthog-ios native SDKs over
/// `MethodChannel('posthog_flutter')`. This class fills that role in Dart and
/// talks to the PostHog HTTP API directly, which is why it works on Windows
/// and Linux without restrictions.
///
/// As in the official plugin, no method here **ever throws** — an analytics
/// SDK must not bring down its host app. Failures are recorded with
/// `printIfDebug` and a safe default is returned.
class PosthogHttp extends PosthogFlutterPlatformInterface {
  PosthogHttp({http.Client? client}) : _client = client;

  /// Caller-supplied HTTP client.
  ///
  /// Usually `null`, in which case the SDK creates its own. Supply one for
  /// tests, or when custom networking is required (a proxy, a private
  /// certificate).
  final http.Client? _client;

  PostHogConfig? _config;
  PostHogApi? _api;
  PostHogPreferences? _preferences;
  PostHogIdentityManager? _identity;
  PostHogSessionManager? _session;
  PostHogPropertyBuilder? _properties;
  PostHogFeatureFlags? _flags;
  PostHogQueue? _eventQueue;
  PostHogQueue? _snapshotQueue;

  /// When `disable()` has been called or `optOut` is enabled, nothing is sent.
  bool _optedOut = false;

  /// Lets methods called before `setup()` finishes await its completion.
  Completer<void>? _setupCompleter;

  bool get _ready => _config != null && _eventQueue != null;

  /// Buffer of exception steps.
  ///
  /// Differs from PostHog upstream: in the official plugin this buffer lived
  /// in the native SDK and survived a native crash. In Dart it dies with the
  /// process — documented in `posthog_config.dart`.
  final List<Map<String, Object>> _exceptionSteps = [];
  int _exceptionStepsBytes = 0;

  @override
  Future<void> setup(PostHogConfig config) async {
    final pending = _setupCompleter;
    if (pending != null) return pending.future;

    final completer = Completer<void>();
    _setupCompleter = completer;

    try {
      _config = config;
      config.bootstrap?.validate();

      final preferences = PostHogPreferences(projectToken: config.projectToken);
      await preferences.load();
      _preferences = preferences;

      final identity = PostHogIdentityManager(preferences);
      final bootstrap = config.bootstrap;
      if (bootstrap != null) {
        identity.applyBootstrap(
          distinctId: bootstrap.distinctId,
          isIdentifiedId: bootstrap.isIdentifiedId,
        );
      }
      _identity = identity;

      final session = PostHogSessionManager();
      session.startSession();
      _session = session;

      final context = PostHogContext();

      final properties = PostHogPropertyBuilder(
        context: context,
        identity: identity,
        session: session,
      );
      properties.superProperties.addAll(_loadSuperProperties(preferences));
      _properties = properties;

      final api = PostHogApi(
        host: config.host,
        projectToken: config.projectToken,
        client: _client,
      );
      _api = api;

      _eventQueue = PostHogQueue(
        name: 'events',
        sender: api.batch,
        storage: PostHogQueueStorage(
          projectToken: config.projectToken,
          queueName: 'events',
        ),
        flushAt: config.flushAt,
        maxQueueSize: config.maxQueueSize,
        maxBatchSize: config.maxBatchSize,
        flushInterval: config.flushInterval,
      );

      _snapshotQueue = PostHogQueue(
        name: 'replay',
        sender: api.snapshot,
        storage: PostHogQueueStorage(
          projectToken: config.projectToken,
          queueName: 'replay',
        ),
        flushAt: config.flushAt,
        maxQueueSize: config.maxQueueSize,
        maxBatchSize: config.maxBatchSize,
        flushInterval: config.flushInterval,
      );

      _flags = PostHogFeatureFlags(
        api: api,
        preferences: preferences,
        identity: identity,
        onFeatureFlagsLoaded: config.onFeatureFlags,
      );
      if (bootstrap != null) {
        _flags!.applyBootstrap(
          featureFlags: bootstrap.featureFlags,
          featureFlagPayloads: bootstrap.featureFlagPayloads,
        );
      }
      properties.featureFlags = _flags!.allFlags();

      _snapshotSender = SnapshotSender(enqueue: _enqueueSnapshot);

      if (config.surveys) {
        _surveys = SurveyTargeting(
          api: api,
          preferences: preferences,
          flags: _flags!,
        );
        // Non-blocking: the app keeps running until surveys arrive.
        unawaited(_surveys!.load());
      }

      // Sampling is decided once per session — otherwise a session's frames
      // would be recorded only partially and the replay would break up.
      final sampleRate = config.sessionReplayConfig.sampleRate;
      _replaySampled = sampleRate == null || Random().nextDouble() < sampleRate;
      if (!_replaySampled) {
        printIfDebug('[PostHog] this session was not sampled for replay');
      }

      _optedOut = config.optOut;

      await _eventQueue!.start();
      await _snapshotQueue!.start();

      if (config.preloadFeatureFlags && !_optedOut) {
        // Non-blocking: the app keeps running until the flags arrive.
        unawaited(_reloadFlags());
      }

      completer.complete();
    } catch (e, stack) {
      printIfDebug('[PostHog] setup failed: $e\n$stack');
      completer.complete();
    }
    return completer.future;
  }

  @override
  Future<void> identify({
    required String userId,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      final previousAnonymousId = _identity!.identify(userId);

      await _enqueue(
        eventName: '\$identify',
        properties: {
          if (previousAnonymousId != null) '\$anon_distinct_id': previousAnonymousId,
        },
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce,
      );

      // The identity changed, so the flags may resolve differently.
      unawaited(_reloadFlags());
    } catch (e) {
      printIfDebug('[PostHog] identify failed: $e');
    }
  }

  @override
  Future<void> setPersonProperties({
    Map<String, Object>? userPropertiesToSet,
    Map<String, Object>? userPropertiesToSetOnce,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      await _enqueue(
        eventName: '\$set',
        userProperties: userPropertiesToSet,
        userPropertiesSetOnce: userPropertiesToSetOnce,
      );
    } catch (e) {
      printIfDebug('[PostHog] setPersonProperties failed: $e');
    }
  }

  @override
  Future<void> capture({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      final extracted = CaptureUtils.extractUserProperties(
        properties: properties,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce,
      );

      await _enqueue(
        eventName: eventName,
        properties: extracted.properties,
        userProperties: extracted.userProperties,
        userPropertiesSetOnce: extracted.userPropertiesSetOnce,
      );

      // This event may activate a survey.
      _surveys?.onEvent(eventName);
      unawaited(_maybeShowSurvey());
    } catch (e) {
      printIfDebug('[PostHog] capture failed: $e');
    }
  }

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      // `$screen_name` is added by the property builder; drop it here so it
      // is not duplicated.
      final cleaned = properties == null
          ? null
          : (Map<String, Object>.from(properties)
            ..remove(PostHogPropertyName.screenName));

      await _enqueue(
        eventName: PostHogEventName.screen,
        properties: {
          ...?cleaned,
          PostHogPropertyName.screenName: screenName,
        },
      );
    } catch (e) {
      printIfDebug('[PostHog] screen failed: $e');
    }
  }

  @override
  Future<void> captureLog({
    required String body,
    PostHogLogSeverity level = PostHogLogSeverity.info,
    Map<String, Object>? attributes,
    String? traceId,
    String? spanId,
    int? traceFlags,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      // Differs from PostHog upstream: the official plugin handed logs to
      // the native SDK's OTLP builder. Here logs are sent as ordinary events;
      // a dedicated schema for the OTLP endpoint can follow in a later
      // version.
      await _enqueue(
        eventName: '\$log',
        properties: {
          '\$log_body': body,
          '\$log_severity': level.name,
          if (attributes != null && attributes.isNotEmpty)
            '\$log_attributes': attributes,
          if (traceId != null) '\$log_trace_id': traceId,
          if (spanId != null) '\$log_span_id': spanId,
          if (traceFlags != null) '\$log_trace_flags': traceFlags,
        },
      );
    } catch (e) {
      printIfDebug('[PostHog] captureLog failed: $e');
    }
  }

  @override
  Future<void> openUrl(String url) async {
    // Differs from PostHog upstream: the official plugin delegated this to
    // the native SDK. Here `url_launcher` is used, which supports Windows and
    // Linux as well.
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) {
        printIfDebug('[PostHog] invalid URL: $url');
        return;
      }
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        printIfDebug('[PostHog] could not open URL: $url');
      }
    } catch (e) {
      printIfDebug('[PostHog] openUrl failed: $e');
    }
  }

  @override
  Future<void> alias({required String alias}) async {
    if (!_ready || _optedOut) return;
    try {
      await _enqueue(
        eventName: '\$create_alias',
        properties: {
          'alias': alias,
          'distinct_id': _identity!.distinctId,
        },
      );
    } catch (e) {
      printIfDebug('[PostHog] alias failed: $e');
    }
  }

  @override
  Future<String> getDistinctId() async {
    if (!_ready) return '';
    return _identity!.distinctId;
  }

  @override
  Future<void> reset() async {
    if (!_ready) return;
    try {
      _identity!.reset();
      _session!.rotate();
      _flags!.clear();
      _properties!.featureFlags = {};
      _properties!.superProperties.clear();
      _properties!.groups.clear();
      _preferences!.remove(_superPropertiesKey);
      await _preferences!.flush();
      await _eventQueue!.clear();
      await _snapshotQueue!.clear();
    } catch (e) {
      printIfDebug('[PostHog] reset failed: $e');
    }
  }

  @override
  Future<void> disable() async {
    _optedOut = true;
  }

  @override
  Future<void> enable() async {
    _optedOut = false;
  }

  @override
  Future<bool> isOptOut() async => _optedOut;

  @override
  Future<void> debug(bool enabled) async {
    _config?.debug = enabled;
  }

  @override
  Future<void> register(String key, Object value) async {
    if (!_ready) return;
    try {
      _properties!.superProperties[key] = value;
      _persistSuperProperties();
    } catch (e) {
      printIfDebug('[PostHog] register failed: $e');
    }
  }

  @override
  Future<void> unregister(String key) async {
    if (!_ready) return;
    try {
      _properties!.superProperties.remove(key);
      _persistSuperProperties();
    } catch (e) {
      printIfDebug('[PostHog] unregister failed: $e');
    }
  }

  @override
  Future<bool> isFeatureEnabled(String key) async {
    if (!_ready) return false;
    final result = _flags!.getFeatureFlagResult(key);
    if (result == null) return false;
    unawaited(_sendFeatureFlagCalledEvent(key, result));
    return result.enabled;
  }

  @override
  Future<void> reloadFeatureFlags() => _reloadFlags();

  @override
  Future<void> setPersonPropertiesForFlags(
    Map<String, Object> userProperties,
  ) async {
    if (!_ready) return;
    _flags!.personProperties.addAll(userProperties);
  }

  @override
  Future<void> resetPersonPropertiesForFlags() async {
    if (!_ready) return;
    _flags!.personProperties.clear();
  }

  @override
  Future<void> setGroupPropertiesForFlags(
    String groupType,
    Map<String, Object> groupProperties,
  ) async {
    if (!_ready) return;
    _flags!.groupProperties
        .putIfAbsent(groupType, () => {})
        .addAll(groupProperties);
  }

  @override
  Future<void> resetGroupPropertiesForFlags({String? groupType}) async {
    if (!_ready) return;
    if (groupType == null) {
      _flags!.groupProperties.clear();
    } else {
      _flags!.groupProperties.remove(groupType);
    }
  }

  @override
  Future<void> showSurvey(Map<String, dynamic> survey) async {
    if (!_ready || _optedOut) return;
    try {
      await SurveyService().showSurvey(
        models.PostHogDisplaySurvey.fromDict(survey),
        onSurveyShown,
        onSurveyResponse,
        onSurveyClosed,
      );
    } catch (e) {
      printIfDebug('[PostHog] could not display the survey: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Surveys
  //
  // Differs from PostHog upstream: in the official plugin the native SDK
  // decided which survey to show, how to shape the responses and which events
  // to send (Dart only drew the UI). Here all of that logic lives in Dart.
  // ---------------------------------------------------------------------------

  SurveyTargeting? _surveys;

  /// The survey currently on screen, together with its collected answers.
  models.PostHogDisplaySurvey? _activeSurvey;
  final Map<int, Object?> _surveyResponses = {};

  /// Displays the next survey that is eligible to be shown, if any.
  Future<void> _maybeShowSurvey() async {
    if (!_ready || _optedOut) return;
    if (!(_config?.surveys ?? true)) return;
    if (_activeSurvey != null) return;

    final next = _surveys?.nextSurvey();
    if (next == null) return;

    await showSurvey(next);
  }

  /// Called once a survey has been shown.
  ///
  /// Visible for testing: these callbacks fire from inside the `SurveyService`
  /// modal, which is awaited until it closes, so they cannot be driven
  /// end-to-end from a widget test.
  @visibleForTesting
  void onSurveyShown(models.PostHogDisplaySurvey survey) {
    _activeSurvey = survey;
    _surveyResponses.clear();
    unawaited(_enqueue(
      eventName: 'survey shown',
      properties: _surveyBaseProperties(survey),
    ));
  }

  /// Called when the user answers a question.
  @visibleForTesting
  Future<PostHogSurveyNextQuestion> onSurveyResponse(
    models.PostHogDisplaySurvey survey,
    int questionIndex,
    Object? response,
  ) async {
    _surveyResponses[questionIndex] = response;

    final questions = survey.questions;
    final branching = questionIndex < questions.length
        ? _branchingOf(questions[questionIndex])
        : null;

    final next = SurveyBranching.nextQuestion(
      currentIndex: questionIndex,
      questionCount: questions.length,
      branching: branching,
      response: response,
    );

    if (next.isSurveyCompleted) {
      await _enqueue(
        eventName: 'survey sent',
        properties: {
          ..._surveyBaseProperties(survey),
          ..._surveyResponseProperties(survey),
        },
        userProperties: {
          _surveyInteractionKey('responded', survey): true,
        },
      );
      _surveys?.markSeen(survey.id);
      _activeSurvey = null;
    }

    return next;
  }

  /// Called when the survey is closed.
  @visibleForTesting
  void onSurveyClosed(models.PostHogDisplaySurvey survey) {
    // Do not repeat `survey sent` if it has already been sent.
    if (_activeSurvey == null) return;

    unawaited(_enqueue(
      eventName: 'survey dismissed',
      properties: {
        ..._surveyBaseProperties(survey),
        ..._surveyResponseProperties(survey),
        '\$survey_partially_completed': _surveyResponses.isNotEmpty,
      },
      userProperties: {
        _surveyInteractionKey('dismissed', survey): true,
      },
    ));
    _surveys?.markSeen(survey.id);
    _activeSurvey = null;
  }

  Map<String, Object> _surveyBaseProperties(
    models.PostHogDisplaySurvey survey,
  ) {
    return {
      '\$survey_id': survey.id,
      '\$survey_name': survey.name,
    };
  }

  /// Maps the answers onto the keys PostHog expects.
  ///
  /// Every answer is sent under **two** keys: by index (the legacy format) and
  /// by question id (the current one). The backend accepts both, but different
  /// reports read different ones.
  Map<String, Object> _surveyResponseProperties(
    models.PostHogDisplaySurvey survey,
  ) {
    final result = <String, Object>{};
    final questionsPayload = <Map<String, Object?>>[];

    for (var i = 0; i < survey.questions.length; i++) {
      final question = survey.questions[i];
      final response = _surveyResponses[i];

      questionsPayload.add({
        'id': question.id,
        'question': question.question,
        'response': response,
      });

      if (response == null) continue;

      final key = i == 0 ? '\$survey_response' : '\$survey_response_$i';
      result[key] = response;

      if (question.id.isNotEmpty) {
        result['\$survey_response_${question.id}'] = response;
      }
    }

    result['\$survey_questions'] = questionsPayload;
    return result;
  }

  static String _surveyInteractionKey(
    String property,
    models.PostHogDisplaySurvey survey,
  ) {
    return '\$survey_$property/${survey.id}';
  }

  static Map<String, dynamic>? _branchingOf(
    PostHogDisplaySurveyQuestion question,
  ) {
    return question.branching;
  }

  @override
  Future<void> group({
    required String groupType,
    required String groupKey,
    Map<String, Object>? groupProperties,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      _properties!.groups[groupType] = groupKey;
      _flags!.groups[groupType] = groupKey;

      await _enqueue(
        eventName: '\$groupidentify',
        properties: {
          '\$group_type': groupType,
          '\$group_key': groupKey,
          if (groupProperties != null) '\$group_set': groupProperties,
        },
      );

      unawaited(_reloadFlags());
    } catch (e) {
      printIfDebug('[PostHog] group failed: $e');
    }
  }

  @override
  Future<Object?> getFeatureFlag({required String key}) async {
    if (!_ready) return null;
    final result = _flags!.getFeatureFlagResult(key);
    if (result == null) return null;
    unawaited(_sendFeatureFlagCalledEvent(key, result));
    return result.variant ?? result.enabled;
  }

  @override
  Future<Object?> getFeatureFlagPayload({required String key}) async {
    if (!_ready) return null;
    return _flags!.getPayload(key);
  }

  @override
  Future<PostHogFeatureFlagResult?> getFeatureFlagResult({
    required String key,
    bool sendEvent = true,
  }) async {
    if (!_ready) return null;
    final result = _flags!.getFeatureFlagResult(key);
    if (result != null && sendEvent) {
      unawaited(_sendFeatureFlagCalledEvent(key, result));
    }
    return result;
  }

  @override
  Future<void> flush() async {
    if (!_ready) return;
    await _eventQueue!.flush();
    await _snapshotQueue!.flush();
  }

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object>? properties,
  }) async {
    if (!_ready || _optedOut) return;
    try {
      final processed = DartExceptionProcessor.processException(
        error: error,
        stackTrace: stackTrace,
        properties: properties,
        inAppIncludes: _config!.errorTrackingConfig.inAppIncludes,
        inAppExcludes: _config!.errorTrackingConfig.inAppExcludes,
        inAppByDefault: _config!.errorTrackingConfig.inAppByDefault,
      );

      await _enqueue(
        eventName: PostHogEventName.exception,
        properties: {
          for (final entry in processed.entries)
            if (entry.value != null) entry.key: entry.value as Object,
          if (_exceptionSteps.isNotEmpty)
            '\$exception_steps': List<Map<String, Object>>.from(
              _exceptionSteps,
            ),
        },
      );
    } catch (e) {
      printIfDebug('[PostHog] captureException failed: $e');
    }
  }

  @override
  Future<void> addExceptionStep(
    String message, {
    Map<String, Object>? properties,
  }) async {
    if (!_ready) return;
    final stepsConfig = _config!.errorTrackingConfig.exceptionSteps;
    if (!stepsConfig.enabled) return;

    try {
      final step = <String, Object>{
        'message': message,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        if (properties != null && properties.isNotEmpty)
          'properties': properties,
      };

      // Approximate size: computing the exact JSON length is expensive and
      // the buffer works off an approximate limit anyway.
      final size = message.length + (properties?.length ?? 0) * 32 + 64;
      if (size > stepsConfig.maxBytes) {
        printIfDebug('[PostHog] exception step too large, skipped');
        return;
      }

      _exceptionSteps.add(step);
      _exceptionStepsBytes += size;

      while (_exceptionStepsBytes > stepsConfig.maxBytes &&
          _exceptionSteps.isNotEmpty) {
        final removed = _exceptionSteps.removeAt(0);
        final removedMessage = removed['message'];
        final removedProperties = removed['properties'];
        _exceptionStepsBytes -= (removedMessage is String
                ? removedMessage.length
                : 0) +
            (removedProperties is Map ? removedProperties.length * 32 : 0) +
            64;
      }
      if (_exceptionSteps.isEmpty) _exceptionStepsBytes = 0;
    } catch (e) {
      printIfDebug('[PostHog] addExceptionStep failed: $e');
    }
  }

  @override
  Future<void> close() async {
    try {
      await _eventQueue?.close();
      await _snapshotQueue?.close();
      await _preferences?.flush();
      _api?.close();
    } catch (e) {
      printIfDebug('[PostHog] close failed: $e');
    } finally {
      _config = null;
      _api = null;
      _preferences = null;
      _identity = null;
      _session = null;
      _properties = null;
      _flags = null;
      _eventQueue = null;
      _snapshotQueue = null;
      _setupCompleter = null;
      _exceptionSteps.clear();
      _exceptionStepsBytes = 0;
    }
  }

  @override
  Future<String?> getSessionId() async {
    if (!_ready) return null;
    return _session!.sessionId;
  }

  @override
  Future<void> startSessionRecording({bool resumeCurrent = true}) async {
    if (!_ready) return;
    if (!resumeCurrent) {
      _session!.rotate();
    }
    _replayActive = true;
  }

  @override
  Future<void> stopSessionRecording() async {
    _replayActive = false;
  }

  @override
  Future<bool> isSessionReplayActive() async {
    if (!_ready || _optedOut) return false;
    if (!_config!.sessionReplay) return false;
    if (!_replayActive) return false;
    return _replaySampled;
  }

  // ---------------------------------------------------------------------------
  // Session replay
  //
  // Differs from PostHog upstream: the official plugin had the native SDK
  // build the `$snapshot` event. Here it is built in Dart and posted to the
  // `/s/` endpoint.
  // ---------------------------------------------------------------------------

  /// Whether replay recording is on (turned off by `stopSessionRecording()`).
  bool _replayActive = true;

  /// Whether this session was picked by `sampleRate`.
  ///
  /// Decided once at the start of the session: otherwise a session's frames
  /// would be recorded only partially and the replay would come out choppy.
  var _replaySampled = true;

  SnapshotSender? _snapshotSender;

  /// Sends the replay meta event.
  Future<void> sendReplayMetaEvent({
    required int width,
    required int height,
    required String? screen,
  }) async {
    if (!await isSessionReplayActive()) return;
    await _snapshotSender?.sendMetaEvent(
      width: width,
      height: height,
      screen: screen,
    );
  }

  /// Replay kadrini yuboradi.
  Future<void> sendReplayFullSnapshot(
    Uint8List imageBytes, {
    required int id,
    required int x,
    required int y,
  }) async {
    if (!await isSessionReplayActive()) return;
    await _snapshotSender?.sendFullSnapshot(imageBytes, id: id, x: x, y: y);
  }

  /// Builds the `$snapshot` event and puts it on the replay queue.
  Future<void> _enqueueSnapshot(Map<String, Object?> snapshotData) async {
    final session = _session?.sessionId;
    // The backend rejects a `$snapshot` without `$session_id`, so sending
    // one would be wasted traffic.
    if (session == null) return;

    final built = await _properties!.build(
      eventName: '\$snapshot',
      appendSharedProps: false,
    );

    await _snapshotQueue!.add({
      'event': '\$snapshot',
      'distinct_id': _identity!.distinctId,
      'properties': _normalizeForJson({
        ...built,
        '\$snapshot_source': 'mobile',
        '\$snapshot_data': [snapshotData],
      }),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ---------------------------------------------------------------------------
  // Ichki yordamchilar
  // ---------------------------------------------------------------------------

  static const _superPropertiesKey = 'posthog.superProperties';

  Map<String, Object> _loadSuperProperties(PostHogPreferences preferences) {
    final stored = preferences.getMap(_superPropertiesKey);
    if (stored == null) return {};
    final result = <String, Object>{};
    for (final entry in stored.entries) {
      final value = entry.value;
      if (value != null) result[entry.key] = value;
    }
    return result;
  }

  void _persistSuperProperties() {
    _preferences?.set(
      _superPropertiesKey,
      Map<String, Object>.from(_properties!.superProperties),
    );
  }

  /// Prepares an event and puts it on the queue.
  Future<void> _enqueue({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
    bool appendSharedProps = true,
  }) async {
    final config = _config;
    if (config == null) return;

    _session!.touchSession();

    final event = await _runBeforeSend(
      eventName,
      properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
    );
    if (event == null) return;

    final built = await _properties!.build(
      eventName: event.event,
      properties: event.properties,
      userProperties: event.userProperties,
      userPropertiesSetOnce: event.userPropertiesSetOnce,
      screenName: null,
      personProfiles: config.personProfiles,
      appendSharedProps: appendSharedProps,
      sendFeatureFlags: config.sendFeatureFlagEvents,
    );

    await _eventQueue!.add({
      'event': event.event,
      'distinct_id': _identity!.distinctId,
      'properties': _normalizeForJson(built),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Runs the `beforeSend` chain.
  ///
  /// Differs from PostHog upstream: in the official SDK, events emitted by the
  /// native side (`survey shown` and friends) bypassed `beforeSend`. Here every
  /// event takes the same path.
  Future<PostHogEvent?> _runBeforeSend(
    String eventName,
    Map<String, Object>? properties, {
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    var event = PostHogEvent(
      event: eventName,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
    );

    final callbacks = _config?.beforeSend ?? const [];
    if (callbacks.isEmpty) return event;

    for (final callback in callbacks) {
      try {
        final result = await runBeforeSend<PostHogEvent>(callback, event);
        if (result == null) return null;
        event = result;
      } catch (e) {
        // A throwing callback is skipped; the event is not lost.
        printIfDebug('[PostHog] a beforeSend callback threw: $e');
      }
    }
    return event;
  }

  Future<void> _reloadFlags() async {
    if (!_ready || _optedOut) return;
    try {
      await _flags!.reload();
      _properties!.featureFlags = _flags!.allFlags();
    } catch (e) {
      printIfDebug('[PostHog] could not load feature flags: $e');
    }
  }

  /// Sends the `$feature_flag_called` event (once per flag).
  Future<void> _sendFeatureFlagCalledEvent(
    String key,
    PostHogFeatureFlagResult result,
  ) async {
    if (!_ready || _optedOut) return;
    if (!(_config?.sendFeatureFlagEvents ?? true)) return;
    if (!_flags!.markFlagCalled(key)) return;

    await _enqueue(
      eventName: '\$feature_flag_called',
      properties: {
        '\$feature_flag': key,
        '\$feature_flag_response': result.variant ?? result.enabled,
      },
    );
  }

  /// Prepares values for JSON serialization.
  ///
  /// Differs from PostHog upstream: the official plugin used
  /// `PropertyNormalizer` for the MethodChannel codec, which supports
  /// `Uint8List`. JSON has no such type, so a separate normalization runs
  /// here.
  static Map<String, Object?> _normalizeForJson(Map<String, Object?> input) {
    final result = <String, Object?>{};
    for (final entry in input.entries) {
      final value = _normalizeValue(entry.value);
      if (value != null) result[entry.key] = value;
    }
    return result;
  }

  static Object? _normalizeValue(Object? value) {
    if (value == null) return null;
    if (value is bool || value is String || value is num) return value;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Iterable) {
      return value.map(_normalizeValue).where((e) => e != null).toList();
    }
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final normalized = _normalizeValue(entry.value);
        if (normalized != null) result[entry.key.toString()] = normalized;
      }
      return result;
    }
    return value.toString();
  }

  // ---------------------------------------------------------------------------
  // Push notification methods
  //
  // Differs from PostHog upstream: these rely on native push infrastructure
  // (FCM/APNs token registration, notification lifecycle hooks) and cannot be
  // implemented in pure Dart. They are kept as no-ops so API compatibility
  // holds — existing code still compiles, but nothing is sent. Documented
  // explicitly in the README.
  // ---------------------------------------------------------------------------

  @override
  Future<void> registerPushNotificationToken(
    String deviceToken, {
    String? appId,
  }) async {
    printIfDebug(
      '[PostHog] registerPushNotificationToken() is not supported in the pure-Dart '
      'implementation (it requires the native push SDK).',
    );
  }

  @override
  Future<void> unregisterPushNotificationToken() async {
    printIfDebug(
      '[PostHog] unregisterPushNotificationToken() sof Dart '
      'implementatsiyasida qo\'llab-quvvatlanmaydi.',
    );
  }

  @override
  Future<void> capturePushNotificationOpened({
    String? title,
    String? subtitle,
    String? body,
    Map<String, Object?>? payload,
    String? action,
  }) async {
    printIfDebug(
      '[PostHog] capturePushNotificationOpened() is not supported in the '
      'pure-Dart implementation.',
    );
  }
}
