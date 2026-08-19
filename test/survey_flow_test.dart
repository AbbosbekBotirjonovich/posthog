import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog_dart/posthog_dart.dart';
import 'package:posthog_dart/src/posthog_flutter_platform_interface.dart';
import 'package:posthog_dart/src/posthog_http.dart';
import 'package:posthog_dart/src/surveys/models/posthog_display_survey.dart';

/// Exercises the survey response flow: collecting answers, picking the next
/// question through branching, and emitting `survey shown` / `survey sent` /
/// `survey dismissed` with the right keys.
///
/// The callbacks are invoked directly rather than through the modal UI:
/// `SurveyService.showSurvey()` awaits until the modal closes, so driving it
/// end-to-end from a widget test would block. The modal itself is covered
/// separately in `surveys_test.dart`.
class _CapturingClient extends http.BaseClient {
  final List<Map<String, dynamic>> events = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request && request.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(request.body);
        if (decoded is Map && decoded['batch'] is List) {
          for (final e in decoded['batch'] as List) {
            events.add(Map<String, dynamic>.from(e as Map));
          }
        }
      } catch (_) {
        // Tekshiruvlar qabul qilingan eventlarga qaraydi.
      }
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"status":1}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late _CapturingClient client;
  late PosthogHttp sdk;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final tempDir = await Directory.systemTemp.createTemp('posthog_survey');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 't',
        'packageName': 'com.example.t',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );

    client = _CapturingClient();
    sdk = PosthogHttp(client: client);
    PosthogFlutterPlatformInterface.instance = sdk;

    await Posthog().setup(
      PostHogConfig('token')
        ..host = 'https://test.local'
        ..flushAt = 1
        ..preloadFeatureFlags = false
        ..surveys = false
        ..captureApplicationLifecycleEvents = false,
    );
  });

  tearDown(() async {
    await Posthog().close();
  });

  /// A survey of open questions, with optional branching.
  PostHogDisplaySurvey buildSurvey({
    required int questionCount,
    Map<int, Map<String, dynamic>> branching = const {},
  }) =>
      PostHogDisplaySurvey.fromDict({
        'id': 'survey-1',
        'name': 'Feedback',
        'startDate': 1700000000000,
        'questions': [
          for (var i = 0; i < questionCount; i++)
            {
              'id': 'q$i',
              'type': 'open',
              'question': 'Question $i',
              'isOptional': false,
              if (branching.containsKey(i)) 'branching': branching[i],
            },
        ],
      });

  Future<Map<String, dynamic>?> eventNamed(String name) async {
    for (var i = 0; i < 40; i++) {
      final match = client.events.where((e) => e['event'] == name);
      if (match.isNotEmpty) return match.first;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return null;
  }

  Future<Map<String, dynamic>> propertiesOf(String eventName) async {
    final event = await eventNamed(eventName);
    expect(event, isNotNull, reason: '"$eventName" eventi yuborilmadi');
    return event!['properties'] as Map<String, dynamic>;
  }

  group('survey shown', () {
    test('emits survey shown with the survey identity', () async {
      sdk.onSurveyShown(buildSurvey(questionCount: 1));
      await Posthog().flush();

      final properties = await propertiesOf('survey shown');
      expect(properties[r'$survey_id'], 'survey-1');
      expect(properties[r'$survey_name'], 'Feedback');
    });
  });

  group('survey sent', () {
    test('emits survey sent after the last question', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);

      final next = await sdk.onSurveyResponse(survey, 0, 'Zo\'r');
      await Posthog().flush();

      expect(next.isSurveyCompleted, isTrue);
      expect(await eventNamed('survey sent'), isNotNull);
    });

    test('does not send until the last question is answered', () async {
      final survey = buildSurvey(questionCount: 3);
      sdk.onSurveyShown(survey);

      final next = await sdk.onSurveyResponse(survey, 0, 'A');
      await Posthog().flush();

      expect(next.isSurveyCompleted, isFalse);
      expect(await eventNamed('survey sent'), isNull);
    });

    // The first answer uses `$survey_response`, the rest use indexed keys —
    // PostHog backend shu konvensiyani kutadi.
    test('keys the first answer without an index', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'First answer');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 'First answer');
    });

    test('keys later answers by index', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Answer A');
      await sdk.onSurveyResponse(survey, 1, 'Answer B');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 'Answer A');
      expect(properties[r'$survey_response_1'], 'Answer B');
    });

    // A key by question id is sent as well: different reports
    // turlichasini kutadi.
    test('also keys answers by question id', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Answer A');
      await sdk.onSurveyResponse(survey, 1, 'Answer B');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response_q0'], 'Answer A');
      expect(properties[r'$survey_response_q1'], 'Answer B');
    });

    test('includes the question manifest', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'A');
      await sdk.onSurveyResponse(survey, 1, 'B');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      final questions = properties[r'$survey_questions'] as List;

      expect(questions.length, 2);
      expect((questions.first as Map)['id'], 'q0');
      expect((questions.first as Map)['question'], 'Question 0');
      expect((questions.first as Map)['response'], 'A');
    });

    test('marks the person as having responded', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Answer');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      final personProperties = properties[r'$set'] as Map<String, dynamic>;
      expect(personProperties[r'$survey_responded/survey-1'], isTrue);
    });

    test('supports non-string answers', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 5);
      await sdk.onSurveyResponse(survey, 1, ['a', 'b']);
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 5);
      expect(properties[r'$survey_response_1'], ['a', 'b']);
    });
  });

  group('branching', () {
    // This test fails if the branching chain is broken: the survey moved to
    // the second question instead of ending after the first.
    test('an end condition completes after the first answer', () async {
      final survey = buildSurvey(
        questionCount: 3,
        branching: {
          0: {'type': 'end'},
        },
      );
      sdk.onSurveyShown(survey);

      final next = await sdk.onSurveyResponse(survey, 0, 'Yakun');
      await Posthog().flush();

      expect(next.isSurveyCompleted, isTrue);

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 'Yakun');
      expect(properties.containsKey(r'$survey_response_1'), isFalse);
    });

    test('a specific_question condition skips a question', () async {
      final survey = buildSurvey(
        questionCount: 3,
        branching: {
          0: {'type': 'specific_question', 'index': 2},
        },
      );
      sdk.onSurveyShown(survey);

      final next = await sdk.onSurveyResponse(survey, 0, 'First');

      expect(next.questionIndex, 2);
      expect(next.isSurveyCompleted, isFalse);
    });

    test('a response_based condition routes on the answer', () async {
      final survey = buildSurvey(
        questionCount: 3,
        branching: {
          0: {
            'type': 'response_based',
            'responseValues': {'ha': 2, 'yoq': 1},
          },
        },
      );
      sdk.onSurveyShown(survey);

      expect((await sdk.onSurveyResponse(survey, 0, 'ha')).questionIndex, 2);
      expect((await sdk.onSurveyResponse(survey, 0, 'yoq')).questionIndex, 1);
    });

    test('a question without branching advances sequentially', () async {
      final survey = buildSurvey(questionCount: 3);
      sdk.onSurveyShown(survey);

      final next = await sdk.onSurveyResponse(survey, 0, 'A');

      expect(next.questionIndex, 1);
      expect(next.isSurveyCompleted, isFalse);
    });
  });

  group('survey dismissed', () {
    test('emits survey dismissed when closed early', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      final properties = await propertiesOf('survey dismissed');
      expect(properties[r'$survey_id'], 'survey-1');
      expect(properties[r'$survey_partially_completed'], isFalse);
    });

    test('marks a partially completed dismissal', () async {
      final survey = buildSurvey(questionCount: 3);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Partial answer');

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      final properties = await propertiesOf('survey dismissed');
      expect(properties[r'$survey_partially_completed'], isTrue);
      expect(properties[r'$survey_response'], 'Partial answer');
    });

    test('marks the person as having dismissed', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      final properties = await propertiesOf('survey dismissed');
      final personProperties = properties[r'$set'] as Map<String, dynamic>;
      expect(personProperties[r'$survey_dismissed/survey-1'], isTrue);
    });

    // Closing after `survey sent` must not also emit `survey dismissed` —
    // otherwise a single survey would be counted twice.
    test('does not emit dismissed after the survey was sent', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Answer');

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      expect(await eventNamed('survey sent'), isNotNull);
      expect(await eventNamed('survey dismissed'), isNull);
    });
  });
}
