import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../util/logging.dart';

/// Outcome of a request. The queue decides whether to retry or drop based on
/// this.
class PostHogApiResult {
  const PostHogApiResult({
    required this.success,
    this.statusCode,
    this.retryAfterSeconds,
    this.body,
  });

  /// Whether the request was accepted.
  final bool success;

  /// HTTP status code. `null` on a network error.
  final int? statusCode;

  /// Value of the `Retry-After` header in seconds, when present.
  final int? retryAfterSeconds;

  /// Response body, read only for endpoints that need it.
  final String? body;

  /// Whether retrying makes sense.
  ///
  /// Network errors and 5xx: yes. 4xx: no — the request itself is at fault and
  /// resending would loop forever. The exceptions are `429` (rate limit) and
  /// `408` (timeout), which are transient.
  bool get isRetriable {
    final code = statusCode;
    if (code == null) return true; // network error
    if (code == 429 || code == 408) return true;
    return code >= 500;
  }
}

/// Layer that talks to the PostHog HTTP API.
///
/// Differs from PostHog upstream: in the official plugin this was done entirely
/// by the native SDK (`PostHogApi.kt` / posthog-ios). This class fills that
/// role in Dart, which is why it also works on Windows and Linux.
class PostHogApi {
  PostHogApi({
    required this.host,
    required this.projectToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Address of the PostHog instance, for example `https://us.i.posthog.com`.
  final String host;

  /// Project token (`api_key`).
  final String projectToken;

  final http.Client _client;

  /// Request timeout. Mobile networks can be slow, but waiting forever would
  /// block the queue.
  static const _timeout = Duration(seconds: 30);

  /// Host for static resources (remote config, surveys).
  ///
  /// On PostHog Cloud these are served from a separate, cacheable host:
  /// `us.i.posthog.com` -> `us-assets.i.posthog.com`. A self-hosted instance
  /// makes no such split, so the host is left untouched.
  String get assetsHost {
    final normalized = _stripTrailingSlash(host);
    if (normalized.contains('us.i.posthog.com')) {
      return normalized.replaceFirst('us.i.posthog.com', 'us-assets.i.posthog.com');
    }
    if (normalized.contains('eu.i.posthog.com')) {
      return normalized.replaceFirst('eu.i.posthog.com', 'eu-assets.i.posthog.com');
    }
    return normalized;
  }

  /// Posts a batch of events to `/batch`.
  Future<PostHogApiResult> batch(List<Map<String, Object?>> events) {
    return _post(
      '${_stripTrailingSlash(host)}/batch',
      {
        'api_key': projectToken,
        'batch': events,
      },
    );
  }

  /// Posts session replay snapshots to `/s/`.
  ///
  /// Replay goes to its own endpoint: it has a different size and throughput
  /// profile, so it is not batched together with ordinary events.
  Future<PostHogApiResult> snapshot(List<Map<String, Object?>> events) {
    return _post(
      '${_stripTrailingSlash(host)}/s/',
      {
        'api_key': projectToken,
        'batch': events,
      },
    );
  }

  /// Posts logs.
  Future<PostHogApiResult> logs(Map<String, Object?> payload) {
    return _post('${_stripTrailingSlash(host)}/i/v1/logs', payload);
  }

  /// Fetches feature flags from `/flags?v=2`.
  Future<PostHogApiResult> flags({
    required String distinctId,
    Map<String, String>? groups,
    Map<String, Object>? personProperties,
    Map<String, Map<String, Object>>? groupProperties,
  }) {
    return _post(
      '${_stripTrailingSlash(host)}/flags/?v=2',
      {
        'api_key': projectToken,
        'distinct_id': distinctId,
        if (groups != null && groups.isNotEmpty) 'groups': groups,
        if (personProperties != null && personProperties.isNotEmpty)
          'person_properties': personProperties,
        if (groupProperties != null && groupProperties.isNotEmpty)
          'group_properties': groupProperties,
      },
      readBody: true,
    );
  }

  /// Fetches remote config, which is where survey definitions come from.
  Future<PostHogApiResult> remoteConfig() async {
    final uri = Uri.parse('$assetsHost/array/$projectToken/config');
    try {
      final response = await _client.get(uri).timeout(_timeout);
      return PostHogApiResult(
        success: response.statusCode >= 200 && response.statusCode < 300,
        statusCode: response.statusCode,
        retryAfterSeconds: _retryAfter(response.headers),
        body: response.body,
      );
    } catch (e) {
      printIfDebug('[PostHog] remote config request failed: $e');
      return const PostHogApiResult(success: false);
    }
  }

  Future<PostHogApiResult> _post(
    String url,
    Map<String, Object?> payload, {
    bool readBody = false,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse(url),
            headers: const {
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(_timeout);

      final success = response.statusCode >= 200 && response.statusCode < 300;
      if (!success) {
        printIfDebug(
          '[PostHog] $url -> HTTP ${response.statusCode}: ${response.body}',
        );
      }
      return PostHogApiResult(
        success: success,
        statusCode: response.statusCode,
        retryAfterSeconds: _retryAfter(response.headers),
        body: readBody ? response.body : null,
      );
    } catch (e) {
      // Network failure (offline, DNS, timeout). This is retriable, so the
      // queue keeps the events.
      printIfDebug('[PostHog] request to $url failed: $e');
      return const PostHogApiResult(success: false);
    }
  }

  static int? _retryAfter(Map<String, String> headers) {
    final value = headers['retry-after'];
    if (value == null) return null;
    return int.tryParse(value.trim());
  }

  static String _stripTrailingSlash(String value) {
    var result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  void close() {
    _client.close();
  }
}
