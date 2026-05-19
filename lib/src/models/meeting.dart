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
    this.audioOnly,
    this.creationTime,
  });

  factory IsometrikMeeting.fromJson(Map<String, dynamic> json) {
    // PushKit / MQTT payloads sometimes serialize numbers as strings (or other
    // JSON types). Keep parsing tolerant so incoming-call routing doesn't
    // silently fail.
    String? asString(dynamic v) {
      if (v == null) return null;
      if (v is String) return v;
      return v.toString();
    }

    int? asInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final membersRaw = json['members'];
    final rawRtcToken =
        json['rtcToken'] ?? json['token'] ?? json['roomToken'];
    // Keep a stable call identifier across PushKit/FCM and socket/MQTT.
    // Native call actions (CallKit / Android notification) use `callId`,
    // so when both are present prefer `callId`/`call_id`.
    final rawMeetingId = json['callId'] ??
        json['call_id'] ??
        json['meetingId'] ??
        json['roomId'] ??
        json['meeting_id'];
    final rawCustomType = json['customType'] ?? json['callType'];
    final rawAudioOnly = json['audioOnly'];
    final parsedAudioOnly = switch (rawAudioOnly) {
      bool v => v,
      int v => v != 0,
      String v => v.toLowerCase() == 'true' || v == '1',
      _ => null,
    };
    bool? boolFromPayload(dynamic v) {
      if (v == null) return null;
      if (v is bool) return v;
      if (v is int) return v != 0;
      if (v is String) {
        final n = v.trim().toLowerCase();
        if (n == 'true' || n == '1') return true;
        if (n == 'false' || n == '0') return false;
      }
      return null;
    }
    final payloadHasVideo = boolFromPayload(
      json['hasVideo'] ?? json['has_video'] ?? json['isVideo'] ?? json['is_video'],
    );
    // Align with iOS `resolvedVoipCallerDisplayName`: nested `user` objects are common in VoIP JSON.
    Map<String, dynamic>? userMap;
    final userRaw = json['user'];
    if (userRaw is Map) {
      userMap = Map<String, dynamic>.from(userRaw);
    }
    final fromNestedUser = userMap == null
        ? null
        : asString(
            userMap['userName'] ??
                userMap['name'] ??
                userMap['displayName'] ??
                userMap['callerName'],
          );
    final initiatorName = asString(
          json['initiatorName'] ??
              json['initiatorUserName'] ??
              json['createdByName'] ??
              json['callerName'] ??
              json['userName'] ??
              json['memberName'] ??
              json['displayName'] ??
              json['display_name'] ??
              json['name'] ??
              json['title'] ??
              json['label'],
        ) ??
        fromNestedUser;
    final initiatorIdentifier = asString(
      json['initiatorIdentifier'] ?? json['initiatorId'] ?? json['callerId'],
    );
    final rtcToken = asString(rawRtcToken);
    final meetingId = asString(rawMeetingId);
    var customType = asString(rawCustomType);
    var resolvedAudioOnly = parsedAudioOnly;
    // VoIP pushes often omit customType but include hasVideo — align with iOS CallKit.
    if ((customType == null || customType.isEmpty) && payloadHasVideo == true) {
      customType = IsometrikLiveCallType.videoCall.apiValue;
      resolvedAudioOnly = false;
    } else if (resolvedAudioOnly == null && payloadHasVideo == false) {
      resolvedAudioOnly = true;
    }

    return IsometrikMeeting(
      rtcToken: rtcToken,
      uid: asInt(json['uid']),
      action: asString(json['action']),
      createdBy: asString(json['createdBy']),
      userId: asString(json['userId']),

      ///parsing failure and due to this model breaks
      // members: membersRaw
      //     ?.map((e) => IsometrikCallMember.fromJson(e as Map<String, dynamic>))
      //     .toList(),
      members: (membersRaw is List)
          ? membersRaw
                .map((e) {
                  if (e is Map<String, dynamic>) {
                    return e;
                  } else if (e is Map) {
                    return Map<String, dynamic>.from(
                      e.map((key, value) => MapEntry(key.toString(), value)),
                    );
                  }
                  return null;
                })
                .whereType<Map<String, dynamic>>() // safety filter
                .map(IsometrikCallMember.fromJson)
                .toList()
          : null,
      meetingImageUrl: asString(json['meetingImageUrl']),
      meetingId: meetingId,
      meetingDescription: asString(json['meetingDescription']),
      initiatorName: initiatorName,
      initiatorImageUrl: asString(json['initiatorImageUrl']),
      initiatorIdentifier: initiatorIdentifier,
      senderName: asString(json['senderName']),
      senderId: asString(json['senderId']),
      body: asString(json['body']),
      customType: customType,
      audioOnly: resolvedAudioOnly,
      creationTime: asInt(json['creationTime']),
    );
  }

  /// True when REST/MQTT/VoIP payload indicates a video session (not only CallKit `hasVideo`).
  bool get indicatesVideoCall {
    if (callType == IsometrikLiveCallType.videoCall) return true;
    if (audioOnly == false) return true;
    return false;
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
  final bool? audioOnly;
  final int? creationTime;

  IsometrikLiveCallType get callType {
    final raw = (customType ?? '').trim();
    if (raw.isEmpty) {
      // Some payloads omit customType but include audioOnly.
      if (audioOnly == false) {
        return IsometrikLiveCallType.videoCall;
      }
      return IsometrikLiveCallType.audioCall;
    }
    final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (final type in IsometrikLiveCallType.values) {
      final candidate = type.apiValue.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (candidate == normalized) {
        return type;
      }
    }
    // Backward-compatible fallback when server introduces new/unknown values.
    return IsometrikLiveCallType.audioCall;
  }

  IsometrikMeetingAction get meetingAction =>
      IsometrikMeetingAction.fromRaw(action);

  /// When native CallKit already resolved a display string (e.g. PushKit banner) but the JSON map
  /// has no initiator/sender name fields, copy that string into [initiatorName] so in-app UI matches.
  ///
  /// **Reuse:** [IsometrikCallSdk] VoIP path + MQTT detail refresh (preserve prior hint when server omits name).
  IsometrikMeeting withVoipNativeCallerHint(String? nativeResolvedCallerName) {
    final hint = nativeResolvedCallerName?.trim();
    if (hint == null || hint.isEmpty) return this;
    final hasMeaningfulName = <String?>[
      initiatorName,
      senderName,
    ].any((s) => s != null && s.trim().isNotEmpty);
    if (hasMeaningfulName) return this;
    return IsometrikMeeting(
      rtcToken: rtcToken,
      uid: uid,
      action: action,
      createdBy: createdBy,
      userId: userId,
      members: members,
      meetingImageUrl: meetingImageUrl,
      meetingId: meetingId,
      meetingDescription: meetingDescription,
      initiatorName: hint,
      initiatorImageUrl: initiatorImageUrl,
      initiatorIdentifier: initiatorIdentifier,
      senderName: senderName,
      senderId: senderId,
      body: body,
      customType: customType,
      audioOnly: audioOnly,
      creationTime: creationTime,
    );
  }

  /// Native CallKit reported `hasVideo` while JSON omitted [customType] / [audioOnly] — treat as video.
  IsometrikMeeting withNativeHasVideoHint(bool nativeHasVideo) {
    if (!nativeHasVideo && !indicatesVideoCall) return this;
    if (indicatesVideoCall) return this;
    return IsometrikMeeting(
      rtcToken: rtcToken,
      uid: uid,
      action: action,
      createdBy: createdBy,
      userId: userId,
      members: members,
      meetingImageUrl: meetingImageUrl,
      meetingId: meetingId,
      meetingDescription: meetingDescription,
      initiatorName: initiatorName,
      initiatorImageUrl: initiatorImageUrl,
      initiatorIdentifier: initiatorIdentifier,
      senderName: senderName,
      senderId: senderId,
      body: body,
      customType: IsometrikLiveCallType.videoCall.apiValue,
      audioOnly: false,
      creationTime: creationTime,
    );
  }

  /// Force video call metadata when payload flags were sparse (VoIP / accept API).
  IsometrikMeeting withVideoCallForced() {
    if (indicatesVideoCall) return this;
    return IsometrikMeeting(
      rtcToken: rtcToken,
      uid: uid,
      action: action,
      createdBy: createdBy,
      userId: userId,
      members: members,
      meetingImageUrl: meetingImageUrl,
      meetingId: meetingId,
      meetingDescription: meetingDescription,
      initiatorName: initiatorName,
      initiatorImageUrl: initiatorImageUrl,
      initiatorIdentifier: initiatorIdentifier,
      senderName: senderName,
      senderId: senderId,
      body: body,
      customType: IsometrikLiveCallType.videoCall.apiValue,
      audioOnly: false,
      creationTime: creationTime,
    );
  }

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
    if (audioOnly != null) 'audioOnly': audioOnly,
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
