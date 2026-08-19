import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/surveys/survey_branching.dart';
import 'package:posthog_dart/src/surveys/models/posthog_display_survey.dart';
import 'package:posthog_dart/src/surveys/models/survey_callbacks.dart';

/// Branching payload'dan modelgacha va undan `SurveyBranching` gacha
/// yetib borishini tekshiradi.
///
/// This chain used to be broken: `SurveyBranching` was fully written, but
/// modelda `branching` maydoni yo'qligi sababli unga hech qachon haqiqiy
/// shart yetib bormasdi va barcha so'rovnomalar ketma-ket o'tardi.
void main() {
  Map<String, dynamic> surveyWith(List<Map<String, dynamic>> questions) => {
        'id': 'survey-1',
        'name': 'Test survey',
        'questions': questions,
      };

  Map<String, dynamic> question(
    String id, {
    Map<String, dynamic>? branching,
  }) =>
      {
        'id': id,
        'type': 'open',
        'question': '$id?',
        'isOptional': false,
        if (branching != null) 'branching': branching,
      };

  group('branching payload dan modelgacha', () {
    test('parses an end condition', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {'type': 'end'}),
        ]),
      );

      expect(survey.questions.single.branching, {'type': 'end'});
    });

    test('parses a specific_question condition', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {'type': 'specific_question', 'index': 3}),
        ]),
      );

      expect(survey.questions.single.branching, {
        'type': 'specific_question',
        'index': 3,
      });
    });

    test('parses a response_based condition', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {
            'type': 'response_based',
            'responseValues': {'yes': 2, 'no': 'end'},
          }),
        ]),
      );

      final branching = survey.questions.single.branching!;
      expect(branching['type'], 'response_based');
      expect(branching['responseValues'], {'yes': 2, 'no': 'end'});
    });

    test('leaves branching null when absent', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([question('q1')]),
      );

      expect(survey.questions.single.branching, isNull);
    });

    test('ignores a malformed branching value', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q1',
            'type': 'open',
            'question': 'A?',
            'isOptional': false,
            'branching': 'not-a-map',
          },
        ]),
      );

      expect(survey.questions.single.branching, isNull);
    });

    test('carries branching on every question type', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q_link',
            'type': 'link',
            'question': 'Visit?',
            'isOptional': false,
            'link': 'https://example.com',
            'branching': {'type': 'end'},
          },
          {
            'id': 'q_rating',
            'type': 'rating',
            'question': 'Rate?',
            'isOptional': false,
            'branching': {'type': 'end'},
          },
          {
            'id': 'q_choice',
            'type': 'single_choice',
            'question': 'Pick?',
            'isOptional': false,
            'choices': ['a'],
            'branching': {'type': 'end'},
          },
          {
            'id': 'q_open',
            'type': 'open',
            'question': 'Why?',
            'isOptional': false,
            'branching': {'type': 'end'},
          },
        ]),
      );

      for (final q in survey.questions) {
        expect(q.branching, {'type': 'end'}, reason: 'for ${q.id}');
      }
    });
  });

  group('model dan SurveyBranching gacha', () {
    /// `PosthogHttp._onSurveyResponse` bajaradigan ishni takrorlaydi.
    PostHogSurveyNextQuestion resolve(
      PostHogDisplaySurvey survey,
      int index,
      Object? response,
    ) {
      return SurveyBranching.nextQuestion(
        currentIndex: index,
        questionCount: survey.questions.length,
        branching: survey.questions[index].branching,
        response: response,
      );
    }

    test('an end condition completes the survey early', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {'type': 'end'}),
          question('q2'),
          question('q3'),
        ]),
      );

      final next = resolve(survey, 0, 'answer');

      expect(next.isSurveyCompleted, isTrue,
          reason: 'an end rule must finish the survey');
    });

    test('a specific_question condition skips ahead', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {'type': 'specific_question', 'index': 2}),
          question('q2'),
          question('q3'),
        ]),
      );

      final next = resolve(survey, 0, 'answer');

      expect(next.questionIndex, 2, reason: 'q2 must be skipped');
      expect(next.isSurveyCompleted, isFalse);
    });

    test('a response_based condition routes on the answer', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          question('q1', branching: {
            'type': 'response_based',
            'responseValues': {'ha': 2, 'yoq': 1},
          }),
          question('q2'),
          question('q3'),
        ]),
      );

      expect(resolve(survey, 0, 'ha').questionIndex, 2);
      expect(resolve(survey, 0, 'yoq').questionIndex, 1);
    });

    test('a question without branching advances sequentially', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([question('q1'), question('q2')]),
      );

      final next = resolve(survey, 0, 'answer');

      expect(next.questionIndex, 1);
      expect(next.isSurveyCompleted, isFalse);
    });
  });
}
