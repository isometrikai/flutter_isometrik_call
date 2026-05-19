import 'enums.dart';

/// Mirrors `ISMMeetingRequest`.
class IsometrikCreateMeetingRequest {
  IsometrikCreateMeetingRequest({
    required this.members,
    required this.deviceId,
    required this.customType,
    required this.audioOnly,
    this.meetingDescription = 'NA',
    this.conversationId,
    this.selfHosted = true,
    this.pushNotifications = false,
    this.metaData = const <String, String>{},
    this.meetingImageUrl =
        'https://d1q6f0aelx0por.cloudfront.net/product-logos/cb773227-1c2c-42a4-a527-12e6f827c1d2-elixir.png',
    this.hdMeeting = false,
    this.enableRecording = false,
    this.meetingType = 0,
    this.autoTerminate = true,
  });

  final List<String> members;
  final String deviceId;
  final String customType;
  final bool audioOnly;
  final String meetingDescription;
  final String? conversationId;
  final bool selfHosted;
  final bool pushNotifications;
  final Map<String, String> metaData;
  final String meetingImageUrl;
  final bool hdMeeting;
  final bool enableRecording;
  final int meetingType;
  final bool autoTerminate;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'selfHosted': selfHosted,
    'pushNotifications': pushNotifications,
    'metaData': metaData,
    'members': members,
    'meetingImageUrl': meetingImageUrl,
    'meetingDescription': meetingDescription,
    'hdMeeting': hdMeeting,
    'enableRecording': enableRecording,
    'deviceId': deviceId,
    'customType': customType,
    'meetingType': meetingType,
    'autoTerminate': autoTerminate,
    'audioOnly': audioOnly,
    if (conversationId != null) 'conversationId': conversationId,
  };

  factory IsometrikCreateMeetingRequest.forCallee({
    required String memberId,
    required String deviceId,
    required IsometrikLiveCallType callType,
    String? conversationId,
  }) {
    return IsometrikCreateMeetingRequest(
      members: <String>[memberId],
      deviceId: deviceId,
      customType: callType.apiValue,
      audioOnly: callType == IsometrikLiveCallType.audioCall,
      conversationId: conversationId,
    );
  }
}

/// Mirrors `ISMStartPublishingRequest`.
class IsometrikStartPublishingRequest {
  const IsometrikStartPublishingRequest({
    required this.meetingId,
    required this.deviceId,
  });

  final String meetingId;
  final String deviceId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'meetingId': meetingId,
    'deviceId': deviceId,
  };
}

/// Mirrors `ISMPublishMessage`.
class IsometrikPublishMessageRequest {
  IsometrikPublishMessageRequest({
    required this.deviceId,
    required this.meetingId,
    required this.body,
    this.messageType = '1',
    this.metaData = const <String, String>{},
  });

  final String deviceId;
  final String meetingId;
  final String body;
  final String messageType;
  final Map<String, String> metaData;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'deviceId': deviceId,
    'meetingId': meetingId,
    'messageType': messageType,
    'metaData': metaData,
    'body': body,
  };
}

/// Mirrors `ISMAuthRequest`.
class IsometrikAuthenticateRequest {
  const IsometrikAuthenticateRequest({
    required this.userIdentifier,
    required this.password,
  });

  final String userIdentifier;
  final String password;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'userIdentifier': userIdentifier,
    'password': password,
  };
}

/// Mirrors `ISMUpdateUserRequest`.
class IsometrikUpdateUserRequest {
  const IsometrikUpdateUserRequest({
    required this.addApnsDeviceToken,
    required this.apnsDeviceToken,
  });

  final bool addApnsDeviceToken;
  final String apnsDeviceToken;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'addApnsDeviceToken': addApnsDeviceToken,
    'apnsDeviceToken': apnsDeviceToken,
  };
}
