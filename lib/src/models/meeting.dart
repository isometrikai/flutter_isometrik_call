import 'enums.dart';
import 'user.dart';

/// Mirrors Swift `ISMMeetings`.
class IsometrikMeetingsList {
  const IsometrikMeetingsList({this.msg, this.meetings});

  factory IsometrikMeetingsList.fromJson(Map<String, dynamic> json) {
    final list = json['meetings'] as List<dynamic>?;
    return IsometrikMeetingsList(
      msg: json['msg'] as String?,
      meetings: list
          ?.map((e) => IsometrikMeeting.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String? msg;
  final List<IsometrikMeeting>? meetings;
}

/// Mirrors Swift `ISMMeeting` (subset used by REST + MQTT + PushKit).
class IsometrikMeeting {
  const IsometrikMeeting({
    this.rtcToken,
    this.uid,
    this.action,
    this.createdBy,
    this.userId,
    this.members,
    this.meetingImageUrl,
    this.meetingId,
    this.meetingDescription,
    this.initiatorName,
    this.initiatorImageUrl,
    this.initiatorIdentifier,
    this.senderName,
    this.senderId,
    this.body,
    this.customType,
    this.creationTime,
  });

  factory IsometrikMeeting.fromJson(Map<String, dynamic> json) {
    final membersRaw = json['members'] as List<dynamic>?;
    final dynamic rawRtcToken =
        json['rtcToken'] ?? json['token'] ?? json['roomToken'];
    final dynamic rawMeetingId =
        json['meetingId'] ?? json['roomId'] ?? json['meeting_id'];
    final dynamic rawCustomType = json['customType'] ?? json['callType'];
    return IsometrikMeeting(
      rtcToken: rawRtcToken is String ? rawRtcToken : null,
      uid: json['uid'] as int?,
      action: json['action'] as String?,
      createdBy: json['createdBy'] as String?,
      userId: json['userId'] as String?,
      members: membersRaw
          ?.map((e) => IsometrikCallMember.fromJson(e as Map<String, dynamic>))
          .toList(),
      meetingImageUrl: json['meetingImageUrl'] as String?,
      meetingId: rawMeetingId is String ? rawMeetingId : null,
      meetingDescription: json['meetingDescription'] as String?,
      initiatorName: json['initiatorName'] as String?,
      initiatorImageUrl: json['initiatorImageUrl'] as String?,
      initiatorIdentifier: json['initiatorIdentifier'] as String?,
      senderName: json['senderName'] as String?,
      senderId: json['senderId'] as String?,
      body: json['body'] as String?,
      customType: rawCustomType is String ? rawCustomType : null,
      creationTime: json['creationTime'] as int?,
    );
  }

  final String? rtcToken;
  final int? uid;
  final String? action;
  final String? createdBy;
  final String? userId;
  final List<IsometrikCallMember>? members;
  final String? meetingImageUrl;
  final String? meetingId;
  final String? meetingDescription;
  final String? initiatorName;
  final String? initiatorImageUrl;
  final String? initiatorIdentifier;
  final String? senderName;
  final String? senderId;
  final String? body;
  final String? customType;
  final int? creationTime;

  IsometrikLiveCallType get callType {
    final raw = (customType ?? '').trim();
    if (raw.isEmpty) {
      return IsometrikLiveCallType.audioCall;
    }
    final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final type in IsometrikLiveCallType.values) {
      final candidate = type.apiValue
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (candidate == normalized) {
        return type;
      }
    }
    // Backward-compatible fallback when server introduces new/unknown values.
    return IsometrikLiveCallType.audioCall;
  }

  IsometrikMeetingAction get meetingAction =>
      IsometrikMeetingAction.fromRaw(action);

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (rtcToken != null) 'rtcToken': rtcToken,
    if (uid != null) 'uid': uid,
    if (action != null) 'action': action,
    if (createdBy != null) 'createdBy': createdBy,
    if (userId != null) 'userId': userId,
    if (members != null)
      'members': members!.map((IsometrikCallMember m) => m.toJson()).toList(),
    if (meetingImageUrl != null) 'meetingImageUrl': meetingImageUrl,
    if (meetingId != null) 'meetingId': meetingId,
    if (meetingDescription != null) 'meetingDescription': meetingDescription,
    if (initiatorName != null) 'initiatorName': initiatorName,
    if (initiatorImageUrl != null) 'initiatorImageUrl': initiatorImageUrl,
    if (initiatorIdentifier != null) 'initiatorIdentifier': initiatorIdentifier,
    if (senderName != null) 'senderName': senderName,
    if (senderId != null) 'senderId': senderId,
    if (body != null) 'body': body,
    if (customType != null) 'customType': customType,
    if (creationTime != null) 'creationTime': creationTime,
  };
}

/// Mirrors Swift `ISMCallMeetingLeft` (leave / publish ack).
class IsometrikMeetingAck {
  const IsometrikMeetingAck({this.membersCount, this.error});

  factory IsometrikMeetingAck.fromJson(Map<String, dynamic> json) {
    return IsometrikMeetingAck(
      membersCount: json['membersCount'] as int?,
      error: json['error'] as String?,
    );
  }

  final int? membersCount;
  final String? error;
}
