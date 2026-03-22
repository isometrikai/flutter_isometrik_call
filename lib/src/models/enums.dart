/// Mirrors `ISMLiveCallType`.
enum IsometrikLiveCallType {
  audioCall('AudioCall'),
  videoCall('VideoCall'),
  groupCall('GroupCall');

  const IsometrikLiveCallType(this.apiValue);
  final String apiValue;
}

/// Mirrors `ISMMeetingActions`.
enum IsometrikMeetingAction {
  meetingCreated('meetingCreated'),
  meetingEnded('meetingEndedDueToNoUserPublishing'),
  memberLeft('memberLeave'),
  publishingStarted('publishingStarted'),
  messagePublished('messagePublished'),
  joinRequestAccept('joinRequestAccept'),
  joinRequestReject('joinRequestReject'),
  unknown('');

  const IsometrikMeetingAction(this.rawValue);
  final String rawValue;

  static IsometrikMeetingAction fromRaw(String? raw) {
    if (raw == null || raw.isEmpty) {
      return IsometrikMeetingAction.unknown;
    }
    return IsometrikMeetingAction.values.firstWhere(
      (e) => e.rawValue == raw,
      orElse: () => IsometrikMeetingAction.unknown,
    );
  }
}

/// Mirrors `ISMPublishMessageConstants`.
enum IsometrikPublishMessage {
  callRinging('callRinging'),
  requestToSwitchToVideoCall('requestToSwitchToVideoCall'),
  requestToSwitchToVideoCallCancelled('requestToSwitchToVideoCallCancelled'),
  requestToSwitchToVideoCallRejected('requestToSwitchToVideoCallRejected'),
  requestToSwitchToVideoCallAccepted('requestToSwitchToVideoCallAccepted'),
  unknown('');

  const IsometrikPublishMessage(this.rawValue);
  final String rawValue;

  static IsometrikPublishMessage fromBody(String? body) {
    if (body == null || body.isEmpty) {
      return IsometrikPublishMessage.unknown;
    }
    return IsometrikPublishMessage.values.firstWhere(
      (e) => e.rawValue == body,
      orElse: () => IsometrikPublishMessage.unknown,
    );
  }
}
