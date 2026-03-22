import '../api/isometrik_api_error.dart';
import '../api/isometrik_endpoints.dart';
import '../api/isometrik_http_client.dart';
import '../models/models.dart';

/// Mirrors Swift `ISMCallMeetingViewModel` meeting-related REST APIs.
class IsometrikMeetingRepository {
  IsometrikMeetingRepository(this._client);

  final IsometrikHttpClient _client;

  Future<IsometrikResult<List<IsometrikMeeting>>> getMeetings() async {
    final r = await _client.sendJson<IsometrikMeetingsList>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.meetingsList,
        method: IsometrikHttpMethod.get,
      ),
      decode: IsometrikMeetingsList.fromJson,
    );
    return r.when(
      success: (data) =>
          IsometrikSuccess(data.meetings ?? <IsometrikMeeting>[]),
      failure: IsometrikFailure.new,
    );
  }

  Future<IsometrikResult<IsometrikMeeting>> createMeeting({
    required IsometrikCreateMeetingRequest body,
  }) async {
    return _client.sendJson<IsometrikMeeting>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.createMeeting,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikMeeting.fromJson,
    );
  }

  Future<IsometrikResult<IsometrikMeeting>> rejectCall({
    required String meetingId,
    required String deviceId,
  }) async {
    final body = IsometrikStartPublishingRequest(
      meetingId: meetingId,
      deviceId: deviceId,
    );
    return _client.sendJson<IsometrikMeeting>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.rejectMeeting,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikMeeting.fromJson,
    );
  }

  Future<IsometrikResult<IsometrikMeeting>> acceptCall({
    required String meetingId,
    required String deviceId,
  }) async {
    final body = IsometrikStartPublishingRequest(
      meetingId: meetingId,
      deviceId: deviceId,
    );
    return _client.sendJson<IsometrikMeeting>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.acceptMeeting,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikMeeting.fromJson,
    );
  }

  Future<IsometrikResult<IsometrikMeeting>> startPublishing({
    required String meetingId,
    required String deviceId,
  }) async {
    final body = IsometrikStartPublishingRequest(
      meetingId: meetingId,
      deviceId: deviceId,
    );
    return _client.sendJson<IsometrikMeeting>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.startPublishing,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikMeeting.fromJson,
    );
  }

  Future<IsometrikResult<Null>> leaveMeeting({
    required String meetingId,
  }) async {
    final r = await _client.sendJson<IsometrikMeetingAck>(
      IsometrikEndpoint(
        path: IsometrikApiPaths.leaveMeetingPath,
        method: IsometrikHttpMethod.delete,
        query: <String, String>{'meetingId': meetingId},
      ),
      decode: IsometrikMeetingAck.fromJson,
    );
    return r.when(
      success: (_) => const IsometrikSuccess<Null>(null),
      failure: IsometrikFailure.new,
    );
  }

  Future<IsometrikResult<Null>> publishMessage({
    required String meetingId,
    required String deviceId,
    required String messageBody,
  }) async {
    final body = IsometrikPublishMessageRequest(
      deviceId: deviceId,
      meetingId: meetingId,
      body: messageBody,
    );
    final r = await _client.sendJson<IsometrikMeetingAck>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.publishMessage,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikMeetingAck.fromJson,
    );
    return r.when(
      success: (_) => const IsometrikSuccess<Null>(null),
      failure: IsometrikFailure.new,
    );
  }

  Future<IsometrikResult<Null>> updatePushRegistryApnsToken({
    required bool addApnsDeviceToken,
    required String apnsDeviceToken,
  }) async {
    final body = IsometrikUpdateUserRequest(
      addApnsDeviceToken: addApnsDeviceToken,
      apnsDeviceToken: apnsDeviceToken,
    );
    final r = await _client.sendJson<IsometrikUpdateUserAck>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.updateUser,
        method: IsometrikHttpMethod.patch,
      ),
      body: body.toJson(),
      decode: IsometrikUpdateUserAck.fromJson,
    );
    return r.when(
      success: (_) => const IsometrikSuccess<Null>(null),
      failure: IsometrikFailure.new,
    );
  }
}
