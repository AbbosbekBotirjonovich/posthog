import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/surveys/models/posthog_display_choice_question.dart';
import 'package:posthog_dart/src/surveys/models/posthog_display_rating_question.dart';
import 'package:posthog_dart/src/surveys/models/posthog_display_survey.dart';

void main() {
  Map<String, dynamic> surveyWith(List<Map<String, dynamic>> questions) => {
        'id': 'survey-1',
        'name': 'Test survey',
        'questions': questions,
      };

  group('PostHogDisplaySurvey.fromDict', () {
    // PostHog upstream mistakenly read `id` from `type`, so the response keys
    // (`$survey_response_<id>`) ended up containing the question type
    // olardi va bir xil turdagi savollar bir-birini bosardi.
    test('reads the question id from the id field, not the type', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q_nps',
            'type': 'open',
            'question': 'Why?',
            'isOptional': false,
          },
        ]),
      );

      expect(survey.questions.single.id, 'q_nps');
    });

    test('distinguishes two questions of the same type', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q_first',
            'type': 'open',
            'question': 'A?',
            'isOptional': false,
          },
          {
            'id': 'q_second',
            'type': 'open',
            'question': 'B?',
            'isOptional': false,
          },
        ]),
      );

      expect(survey.questions[0].id, 'q_first');
      expect(survey.questions[1].id, 'q_second');
    });

    test('falls back to an empty id when the field is absent', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {'type': 'open', 'question': 'A?', 'isOptional': false},
        ]),
      );

      expect(survey.questions.single.id, '');
    });

    // An unexpected payload must not crash the whole survey: the official
    // plaginda bu maydonlar non-null cast edi.
    group('resilience to incomplete payloads', () {
      test('defaults isOptional when missing', () {
        final survey = PostHogDisplaySurvey.fromDict(
          surveyWith([
            {'id': 'q', 'type': 'open', 'question': 'A?'},
          ]),
        );

        expect(survey.questions.single.optional, isFalse);
      });

      test('defaults the rating scale when fields are missing', () {
        final survey = PostHogDisplaySurvey.fromDict(
          surveyWith([
            {'id': 'q', 'type': 'rating', 'question': 'Rate us'},
          ]),
        );

        final question = survey.questions.single as PostHogDisplayRatingQuestion;
        expect(question.scaleLowerBound, 1);
        expect(question.scaleUpperBound, 5);
        expect(question.lowerBoundLabel, '');
        expect(question.upperBoundLabel, '');
      });

      test('defaults choice fields when missing', () {
        final survey = PostHogDisplaySurvey.fromDict(
          surveyWith([
            {'id': 'q', 'type': 'single_choice', 'question': 'Pick one'},
          ]),
        );

        final question = survey.questions.single as PostHogDisplayChoiceQuestion;
        expect(question.choices, isEmpty);
        expect(question.hasOpenChoice, isFalse);
        expect(question.shuffleOptions, isFalse);
      });
    });

    test('keeps full payloads intact', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q_rating',
            'type': 'rating',
            'question': 'Rate us',
            'isOptional': true,
            'ratingType': 0,
            'scaleLowerBound': 0,
            'scaleUpperBound': 10,
            'lowerBoundLabel': 'Bad',
            'upperBoundLabel': 'Great',
          },
        ]),
      );

      final question = survey.questions.single as PostHogDisplayRatingQuestion;
      expect(question.id, 'q_rating');
      expect(question.optional, isTrue);
      expect(question.scaleLowerBound, 0);
      expect(question.scaleUpperBound, 10);
      expect(question.lowerBoundLabel, 'Bad');
      expect(question.upperBoundLabel, 'Great');
    });

    test('marks multiple choice questions', () {
      final survey = PostHogDisplaySurvey.fromDict(
        surveyWith([
          {
            'id': 'q',
            'type': 'multiple_choice',
            'question': 'Pick some',
            'isOptional': false,
            'choices': ['a', 'b'],
            'hasOpenChoice': true,
            'shuffleOptions': true,
          },
        ]),
      );

      final question = survey.questions.single as PostHogDisplayChoiceQuestion;
      expect(question.isMultipleChoice, isTrue);
      expect(question.choices, ['a', 'b']);
      expect(question.hasOpenChoice, isTrue);
      expect(question.shuffleOptions, isTrue);
    });
  });
}
