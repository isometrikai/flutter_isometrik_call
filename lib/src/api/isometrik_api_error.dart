import '../models/models.dart' show IsometrikMeeting;

/// API errors aligned with Swift `ISMCallAPIError` + HTTP layer.
sealed class IsometrikApiError implements Exception {
  const IsometrikApiError();

  @override
  String toString() => switch (this) {
    IsometrikNetworkError(:final message) => 'Network: $message',
    IsometrikInvalidResponse() => 'Invalid response',
    IsometrikDecodingError(:final cause) => 'Decoding: $cause',
    IsometrikHttpError(:final statusCode) => 'HTTP $statusCode',
    IsometrikServerMessageError(:final message) => message,
  };
}

final class IsometrikNetworkError extends IsometrikApiError {
  const IsometrikNetworkError(this.message);
  final String message;
}

final class IsometrikInvalidResponse extends IsometrikApiError {
  const IsometrikInvalidResponse();
}

final class IsometrikDecodingError extends IsometrikApiError {
  const IsometrikDecodingError(this.cause);
  final Object cause;
}

final class IsometrikHttpError extends IsometrikApiError {
  const IsometrikHttpError(this.statusCode);
  final int statusCode;
}

final class IsometrikServerMessageError extends IsometrikApiError {
  const IsometrikServerMessageError(this.message);
  final String message;
}

/// Result type used across repositories (Dart 3 sealed style).
sealed class IsometrikResult<T> {
  const IsometrikResult();
  R when<R>({
    required R Function(T data) success,
    required R Function(IsometrikApiError e) failure,
  });
}

final class IsometrikSuccess<T> extends IsometrikResult<T> {
  const IsometrikSuccess(this.data);
  final T data;

  @override
  R when<R>({
    required R Function(T data) success,
    required R Function(IsometrikApiError e) failure,
  }) {
    return success(data);
  }
}

final class IsometrikFailure<T> extends IsometrikResult<T> {
  const IsometrikFailure(this.error);
  final IsometrikApiError error;

  @override
  R when<R>({
    required R Function(T data) success,
    required R Function(IsometrikApiError e) failure,
  }) {
    return failure(error);
  }
}

/// Convenience getters when you want to read common fields without switching
/// on [IsometrikResult].
///
/// These return `null` when the result is a failure.
extension IsometrikMeetingResultX on IsometrikResult<IsometrikMeeting> {
  String? get meetingId => when(
        success: (d) => d.meetingId,
        failure: (_) => null,
      );

  String? get rtcToken => when(
        success: (d) => d.rtcToken,
        failure: (_) => null,
      );
}
