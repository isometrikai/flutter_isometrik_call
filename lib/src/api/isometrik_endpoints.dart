/// Base URLs and routes — mirrors Swift `ISMCallMeetingEndpoints` + `ISMCallAuthEndpoints`.
class IsometrikApiPaths {
  IsometrikApiPaths._();

  static const String defaultBaseUrl = 'https://apis.isometrik.io';

  // Meetings
  static const String meetingsList = '/meetings/v1/meetings';
  static const String createMeeting = '/meetings/v1/meeting';
  static const String acceptMeeting = '/meetings/v1/accept';
  static const String rejectMeeting = '/meetings/v1/reject';
  static const String startPublishing = '/meetings/v1/publish/start';
  static const String publishMessage = '/meetings/v1/publish/message';
  static const String updateUser = '/chat/user';
  static const String leaveMeetingPath = '/meetings/v1/leave';

  // Auth
  static const String authenticate = '/streaming/v2/user/authenticate';
  static const String users = '/streaming/v2/users';
}

enum IsometrikHttpMethod { get, post, put, delete, patch }

/// Describes one HTTP call (Swift `ISMURLConvertible` equivalent).
class IsometrikEndpoint {
  const IsometrikEndpoint({
    required this.path,
    required this.method,
    this.query = const <String, String>{},
  });

  final String path;
  final IsometrikHttpMethod method;
  final Map<String, String> query;

  Uri resolveUri(String baseUrl) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$base$path');
    if (query.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }
}
