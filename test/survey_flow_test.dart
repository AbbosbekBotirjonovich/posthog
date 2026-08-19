import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:posthog/posthog.dart';
import 'package:posthog/src/posthog_flutter_platform_interface.dart';
import 'package:posthog/src/posthog_http.dart';
import 'package:posthog/src/surveys/models/posthog_display_survey.dart';

/// So'rovnoma javob oqimini tekshiradi: javoblarni to'plash, branching orqali
/// keyingi savolni tanlash, `survey shown` / `survey sent` / `survey dismissed`
/// eventlarini to'g'ri kalitlar bilan yuborish.
///
/// Callback'lar to'g'ridan-to'g'ri chaqiriladi, modal UI orqali emas:
/// `SurveyService.showSurvey()` modal yopilgunicha `await` qiladi, shuning
/// uchun uni widget testida uchidan-uchiga haydash testni bloklaydi. Modal
/// oynaning o'zi `surveys_test.dart` da alohida qoplangan.
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

  /// Ochiq savollardan iborat so'rovnoma; ixtiyoriy branching bilan.
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
              'question': 'Savol $i',
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

    // Birinchi javob `$survey_response`, qolganlari indeksli kalit oladi —
    // PostHog backend shu konvensiyani kutadi.
    test('keys the first answer without an index', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Birinchi javob');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 'Birinchi javob');
    });

    test('keys later answers by index', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Javob A');
      await sdk.onSurveyResponse(survey, 1, 'Javob B');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response'], 'Javob A');
      expect(properties[r'$survey_response_1'], 'Javob B');
    });

    // Savol id'si bo'yicha kalit ham yuboriladi: turli hisobotlar
    // turlichasini kutadi.
    test('also keys answers by question id', () async {
      final survey = buildSurvey(questionCount: 2);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Javob A');
      await sdk.onSurveyResponse(survey, 1, 'Javob B');
      await Posthog().flush();

      final properties = await propertiesOf('survey sent');
      expect(properties[r'$survey_response_q0'], 'Javob A');
      expect(properties[r'$survey_response_q1'], 'Javob B');
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
      expect((questions.first as Map)['question'], 'Savol 0');
      expect((questions.first as Map)['response'], 'A');
    });

    test('marks the person as having responded', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Javob');
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
    // Branching zanjiri uzilgan bo'lsa bu test tushadi: so'rovnoma birinchi
    // savoldan keyin tugashi o'rniga ikkinchisiga o'tardi.
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

      final next = await sdk.onSurveyResponse(survey, 0, 'Birinchi');

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
      await sdk.onSurveyResponse(survey, 0, 'Yarim javob');

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      final properties = await propertiesOf('survey dismissed');
      expect(properties[r'$survey_partially_completed'], isTrue);
      expect(properties[r'$survey_response'], 'Yarim javob');
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

    // `survey sent` yuborilgandan keyin yopilish `survey dismissed`
    // yubormasligi kerak — aks holda bitta so'rovnoma ikki marta hisoblanardi.
    test('does not emit dismissed after the survey was sent', () async {
      final survey = buildSurvey(questionCount: 1);
      sdk.onSurveyShown(survey);
      await sdk.onSurveyResponse(survey, 0, 'Javob');

      sdk.onSurveyClosed(survey);
      await Posthog().flush();

      expect(await eventNamed('survey sent'), isNotNull);
      expect(await eventNamed('survey dismissed'), isNull);
    });
  });
}
