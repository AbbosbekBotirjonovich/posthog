import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_dart/src/internal/surveys/survey_branching.dart';

void main() {
  group('SurveyBranching', () {
    group('without branching', () {
      test('advances to the next question', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 3,
        );

        expect(next.questionIndex, 1);
        expect(next.isSurveyCompleted, isFalse);
      });

      test('completes on the last question', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 2,
          questionCount: 3,
        );

        expect(next.isSurveyCompleted, isTrue);
      });

      test('never advances past the last index', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 2,
          questionCount: 3,
        );

        expect(next.questionIndex, 2);
      });
    });

    test('next_question behaves like no branching', () {
      final next = SurveyBranching.nextQuestion(
        currentIndex: 0,
        questionCount: 3,
        branching: {'type': 'next_question'},
      );

      expect(next.questionIndex, 1);
      expect(next.isSurveyCompleted, isFalse);
    });

    // Native SDK ham shunday qiladi: tugash sahifasi joriy savol ustidan
    // ko'rsatiladi, shuning uchun indeks siljimaydi.
    test('end completes without moving the index', () {
      final next = SurveyBranching.nextQuestion(
        currentIndex: 0,
        questionCount: 3,
        branching: {'type': 'end'},
      );

      expect(next.questionIndex, 0);
      expect(next.isSurveyCompleted, isTrue);
    });

    group('specific_question', () {
      test('jumps to the requested index', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {'type': 'specific_question', 'index': 3},
        );

        expect(next.questionIndex, 3);
        expect(next.isSurveyCompleted, isFalse);
      });

      test('falls back to sequential for an out-of-range index', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 3,
          branching: {'type': 'specific_question', 'index': 99},
        );

        expect(next.questionIndex, 1);
      });

      test('falls back to sequential for a missing index', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 3,
          branching: {'type': 'specific_question'},
        );

        expect(next.questionIndex, 1);
      });
    });

    group('response_based', () {
      test('routes on a string response', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'yes': 3, 'no': 4},
          },
          response: 'yes',
        );

        expect(next.questionIndex, 3);
      });

      test('routes on a numeric response', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'5': 2},
          },
          response: 5,
        );

        expect(next.questionIndex, 2);
      });

      // Bitta tanlovli savol javobni ro'yxat sifatida beradi.
      test('unwraps a single-element list response', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'yes': 3},
          },
          response: ['yes'],
        );

        expect(next.questionIndex, 3);
      });

      test('can end the survey', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 1,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'no': 'end'},
          },
          response: 'no',
        );

        expect(next.questionIndex, 1);
        expect(next.isSurveyCompleted, isTrue);
      });

      test('falls back to sequential for an unmapped response', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'yes': 3},
          },
          response: 'maybe',
        );

        expect(next.questionIndex, 1);
      });

      test('falls back to sequential for a null response', () {
        final next = SurveyBranching.nextQuestion(
          currentIndex: 0,
          questionCount: 5,
          branching: {
            'type': 'response_based',
            'responseValues': {'yes': 3},
          },
          response: null,
        );

        expect(next.questionIndex, 1);
      });
    });

    test('handles an unknown branching type as sequential', () {
      final next = SurveyBranching.nextQuestion(
        currentIndex: 0,
        questionCount: 3,
        branching: {'type': 'something_new'},
      );

      expect(next.questionIndex, 1);
    });

    test('handles an empty survey without crashing', () {
      final next = SurveyBranching.nextQuestion(
        currentIndex: 0,
        questionCount: 0,
      );

      expect(next.isSurveyCompleted, isTrue);
      expect(next.questionIndex, 0);
    });
  });
}
