import 'package:flutter/foundation.dart';
import 'posthog_survey_question_type.dart';
import 'posthog_display_survey_text_content_type.dart';

/// Base class for all survey questions
@immutable
abstract class PostHogDisplaySurveyQuestion {
  const PostHogDisplaySurveyQuestion({
    required this.id,
    required this.type,
    required this.question,
    this.description,
    this.descriptionContentType = PostHogDisplaySurveyTextContentType.text,
    this.optional = false,
    this.buttonText,
    this.branching,
  });

  final String id;
  final PostHogSurveyQuestionType type;
  final String question;
  final String? description;
  final PostHogDisplaySurveyTextContentType descriptionContentType;
  final bool optional;
  final String? buttonText;

  /// Rules for which question follows this one.
  ///
  /// Differs from PostHog upstream: this field did not exist, because the
  /// native SDK decided the next question (the `surveyAction` MethodChannel
  /// call returned `nextIndex`; on web branching was not supported at all). In
  /// the pure-Dart implementation that decision is made here, so the raw
  /// condition is retained.
  ///
  /// The shape is exactly as it comes from the PostHog API; `SurveyBranching`
  /// interprets it:
  /// - `{"type": "next_question"}` — the next question in sequence
  /// - `{"type": "end"}` — the survey is complete
  /// - `{"type": "specific_question", "index": N}` — jump to a given question
  /// - `{"type": "response_based", "responseValues": {...}}` — depends on the
  ///   answer
  final Map<String, dynamic>? branching;
}
