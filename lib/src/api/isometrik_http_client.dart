import 'dart:convert';

import 'package:http/http.dart' as http;

import 'isometrik_api_error.dart';
import 'isometrik_endpoints.dart';

typedef IsometrikHeaderProvider = Map<String, String> Function();

/// Optional hook for example apps / debugging (request + response lines).
typedef IsometrikHttpDebugLog = void Function(String line);

/// Thin HTTP client mirroring Swift `ISMCallAPIManager.sendRequest` (without UI loader).
class IsometrikHttpClient {
  IsometrikHttpClient({
    required this.baseUrl,
    required this.meetingHeaders,
    required this.authHeaders,
    http.Client? httpClient,
    this.debugLog,
    this.debugLogFullSecrets = false,
  }) : _client = httpClient ?? http.Client();

  final String baseUrl;
  final IsometrikHeaderProvider meetingHeaders;
  final IsometrikHeaderProvider authHeaders;
  final IsometrikHttpDebugLog? debugLog;

  /// When true with [debugLog], logs **full** header values and bodies (passwords, tokens).
  /// **Never enable in production** or in builds whose logs may be collected.
  final bool debugLogFullSecrets;
  final http.Client _client;

  static const int _maxBodyLogChars = 4000;

  static final JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

  void _log(String line) => debugLog?.call(line);

  Future<IsometrikResult<T>> sendJson<T>(
    IsometrikEndpoint endpoint, {
    Object? body,
    required T Function(Map<String, dynamic> json) decode,
    bool useMeetingHeaders = true,
  }) async {
    final uri = endpoint.resolveUri(baseUrl);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (useMeetingHeaders) ...meetingHeaders(),
      if (!useMeetingHeaders) ...authHeaders(),
    };

    final String? bodyStr = body == null ? null : jsonEncode(body);
    if (debugLogFullSecrets) {
      _log(
        '[SECRET DEBUG] --> ${endpoint.method.name.toUpperCase()} $uri\n'
        'headers (full JSON — rotate credentials if this log leaves your machine):\n'
        '${_prettyJson.convert(headers)}\n'
        'body (full): ${bodyStr ?? "(no body)"}',
      );
    } else {
      _log(
        '--> ${endpoint.method.name.toUpperCase()} $uri\n'
        'header names: ${headers.keys.join(", ")}\n'
        '${_describeHeadersForDebug(headers)}\n'
        '${bodyStr == null ? "(no body)" : "body: ${_truncate(bodyStr)}"}',
      );
    }

    late http.Response response;
    try {
      switch (endpoint.method) {
        case IsometrikHttpMethod.get:
          response = await _client.get(uri, headers: headers);
          break;
        case IsometrikHttpMethod.post:
          response = await _client.post(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          );
          break;
        case IsometrikHttpMethod.put:
          response = await _client.put(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          );
          break;
        case IsometrikHttpMethod.delete:
          response = await _client.delete(uri, headers: headers);
          break;
        case IsometrikHttpMethod.patch:
          response = await _client.patch(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          );
          break;
      }
    } catch (e) {
      _log('<-- ERROR $e');
      return IsometrikFailure(IsometrikNetworkError(e.toString()));
    }

    final String raw = utf8.decode(response.bodyBytes);
    if (debugLogFullSecrets) {
      _log(
        '[SECRET DEBUG] <-- ${response.statusCode} ${response.reasonPhrase ?? ""}\n'
        'body (full): $raw',
      );
    } else {
      _log(
        '<-- ${response.statusCode} ${response.reasonPhrase ?? ""}\n'
        '${_truncate(raw)}',
      );
    }

    if (response.statusCode == 200) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        return IsometrikSuccess(decode(map));
      } catch (e) {
        return IsometrikFailure(IsometrikDecodingError(e));
      }
    }

    // Prefer API body (`error`, `errorCode`) for any non-200 — e.g. 404 authenticate:
    // `{"error":"User not found.","errorCode":1}` (see swagger Error_404_authenticate_user).
    final IsometrikApiError? fromBody = _tryParseServerErrorBody(raw);
    if (fromBody != null) {
      return IsometrikFailure(fromBody);
    }
    if (response.statusCode == 404) {
      return const IsometrikFailure(IsometrikHttpError(404));
    }
    if (response.statusCode == 401 || response.statusCode == 406) {
      return IsometrikFailure(IsometrikHttpError(response.statusCode));
    }
    return IsometrikFailure(IsometrikHttpError(response.statusCode));
  }

  /// Swagger: `error` + optional `errorCode` on failed requests.
  static IsometrikApiError? _tryParseServerErrorBody(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final String? msg = decoded['error'] as String?;
      if (msg == null || msg.isEmpty) {
        return null;
      }
      final Object? code = decoded['errorCode'];
      final String suffix = code != null ? ' (errorCode: $code)' : '';
      return IsometrikServerMessageError('$msg$suffix');
    } catch (_) {
      return null;
    }
  }

  /// Shows every header is non-empty without logging secret values (length-only for secrets).
  static String _describeHeadersForDebug(Map<String, String> headers) {
    final List<String> parts = <String>[];
    for (final MapEntry<String, String> e in headers.entries) {
      final String k = e.key;
      final String v = e.value;
      if (k == 'Content-Type') {
        parts.add('$k=$v');
      } else {
        parts.add('$k=*** ${v.length} chars');
      }
    }
    return 'header values: ${parts.join('; ')}';
  }

  void close() {
    _client.close();
  }

  static String _truncate(String s) {
    if (s.length <= _maxBodyLogChars) {
      return s;
    }
    return '${s.substring(0, _maxBodyLogChars)}… [truncated ${s.length - _maxBodyLogChars} chars]';
  }
}
