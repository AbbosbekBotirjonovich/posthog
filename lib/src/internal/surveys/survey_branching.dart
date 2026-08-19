import '../../surveys/models/survey_callbacks.dart';

/// Computes the transition between survey questions.
///
/// Differs from PostHog upstream: this logic lived in the native SDK
/// (`PostHogSurveysIntegration.getNextQuestion()`). The rules are reproduced
/// exactly.
class SurveyBranching {
  SurveyBranching._();

  /// Determines the next question index and whether the survey is complete.
  ///
  /// [branching] is the rule attached to the question:
  /// - `null` or `{"type": "next_question"}` — the next question in sequence
  /// - `{"type": "end"}` — the survey is complete
  /// - `{"type": "specific_question", "index": N}` — jump to a given question
  /// - `{"type": "response_based", "responseValues": {...}}` — depends on the
  ///   answer
  static PostHogSurveyNextQuestion nextQuestion({
    required int currentIndex,
    required int questionCount,
    Map<String, dynamic>? branching,
    Object? response,
  }) {
    if (questionCount <= 0) {
      return const PostHogSurveyNextQuestion(
        questionIndex: 0,
        isSurveyCompleted: true,
      );
    }

    final sequentialIndex =
        currentIndex + 1 < questionCount ? currentIndex + 1 : questionCount - 1;
    final isLastQuestion = currentIndex >= questionCount - 1;

    if (branching == null) {
      return PostHogSurveyNextQuestion(
        questionIndex: sequentialIndex,
        isSurveyCompleted: isLastQuestion,
      );
    }

    final type = branching['type'] as String?;

    switch (type) {
      case 'end':
        // Note: the index does not change. The native SDK behaves the same
        // way — the end screen is shown over the current question.
        return PostHogSurveyNextQuestion(
          questionIndex: currentIndex,
          isSurveyCompleted: true,
        );

      case 'specific_question':
        final target = branching['index'];
        if (target is int && target >= 0 && target < questionCount) {
          return PostHogSurveyNextQuestion(
            questionIndex: target,
            isSurveyCompleted: false,
          );
        }
        return PostHogSurveyNextQuestion(
          questionIndex: sequentialIndex,
          isSurveyCompleted: isLastQuestion,
        );

      case 'response_based':
        final values = branching['responseValues'];
        if (values is Map) {
          final key = _responseKey(response);
          if (key != null && values.containsKey(key)) {
            final target = values[key];
            if (target is int && target >= 0 && target < questionCount) {
              return PostHogSurveyNextQuestion(
                questionIndex: target,
                isSurveyCompleted: false,
              );
            }
            // Qiymat `"end"` bo'lishi ham mumkin.
            if (target == 'end') {
              return PostHogSurveyNextQuestion(
                questionIndex: currentIndex,
                isSurveyCompleted: true,
              );
            }
          }
        }
        return PostHogSurveyNextQuestion(
          questionIndex: sequentialIndex,
          isSurveyCompleted: isLastQuestion,
        );

      case 'next_question':
      default:
        return PostHogSurveyNextQuestion(
          questionIndex: sequentialIndex,
          isSurveyCompleted: isLastQuestion,
        );
    }
  }

  /// Javobni `responseValues` xaritasidagi kalitga aylantiradi.
  static String? _responseKey(Object? response) {
    if (response == null) return null;
    if (response is String) return response;
    if (response is num) return response.toString();
    if (response is bool) return response.toString();
    if (response is List && response.isNotEmpty) {
      // A single-choice answer arrives as a list.
      return _responseKey(response.first);
    }
    return null;
  }
}
