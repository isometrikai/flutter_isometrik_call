import 'package:flutter_test/flutter_test.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';

void main() {
  test('meetingCreated always emits MeetingCreated', () {
    final ctx = IsometrikMeetingRouterContext()..currentUserId = 'u1';
    final router = IsometrikMeetingRouter(context: ctx);
    final m = IsometrikMeeting.fromJson(<String, dynamic>{
      'action': 'meetingCreated',
      'meetingId': 'm1',
    });
    final out = router.route(m);
    expect(out, isA<List<IsometrikRoutedMeetingEvent>>());
    expect(out.single, isA<IsometrikRoutedMeetingCreated>());
  });

  test('meetingEnded matches uiMeetingId', () {
    final ctx = IsometrikMeetingRouterContext()..uiMeetingId = 'm1';
    final router = IsometrikMeetingRouter(context: ctx);
    final m = IsometrikMeeting.fromJson(<String, dynamic>{
      'action': 'meetingEndedDueToNoUserPublishing',
      'meetingId': 'm1',
    });
    expect(router.route(m).single, isA<IsometrikRoutedMeetingEnded>());
  });

  test('remote publishing started when outgoing pending and other user', () {
    final ctx = IsometrikMeetingRouterContext()
      ..currentUserId = 'u1'
      ..outgoingCallPending = true;
    final router = IsometrikMeetingRouter(context: ctx);
    final m = IsometrikMeeting.fromJson(<String, dynamic>{
      'action': 'publishingStarted',
      'meetingId': 'm1',
      'userId': 'u2',
    });
    expect(
      router.route(m).single,
      isA<IsometrikRoutedRemotePublishingStarted>(),
    );
  });

  test('messagePublished callRinging from peer', () {
    final ctx = IsometrikMeetingRouterContext()..currentUserId = 'u1';
    final router = IsometrikMeetingRouter(context: ctx);
    final m = IsometrikMeeting.fromJson(<String, dynamic>{
      'action': 'messagePublished',
      'senderId': 'u2',
      'body': 'callRinging',
    });
    expect(router.route(m).single, isA<IsometrikRoutedCallRinging>());
  });

  test('memberLeave matches uiMeetingId when callDetails unset', () {
    final ctx = IsometrikMeetingRouterContext()..uiMeetingId = 'm1';
    final router = IsometrikMeetingRouter(context: ctx);
    final m = IsometrikMeeting.fromJson(<String, dynamic>{
      'action': 'memberLeave',
      'meetingId': 'm1',
    });
    expect(
      router.route(m).single,
      isA<IsometrikRoutedMemberLeftOrRejected>(),
    );
  });
}
