import 'dart:async';

import '../models/models.dart';
import '../services/isometrik_mqtt_service.dart';

/// Mutable state the host app keeps in sync with call UI + CallKit (mirrors Swift globals on `ISMCallManager` / `ISMLiveCallView`).
///
/// **Reusability:** Document any field your app updates — see package **INTEGRATION.md** for the full contract.
class IsometrikMeetingRouterContext {
  /// Logged-in user id (`ISMCallConfiguration.userId`).
  String? currentUserId;

  /// Active meeting from server / call object (`ISMCallManager.callDetails?.meetingId`).
  String? callDetailsMeetingId;

  /// Meeting id shown on your in-call screen (`ISMLiveCallView.shared.meetingId`).
  String? uiMeetingId;

  /// True while an outgoing CallKit call is waiting for remote publish (`outgoingCallID != nil`).
  bool outgoingCallPending = false;

  /// Device id that answered (Swift `callAnsweredByDeviceId`); null until answered.
  String? callAnsweredByDeviceId;

  /// True when you consider a native CallKit call active (`callIDs` non-empty semantics).
  bool nativeCallActive = false;

  void reset() {
    currentUserId = null;
    callDetailsMeetingId = null;
    uiMeetingId = null;
    outgoingCallPending = false;
    callAnsweredByDeviceId = null;
    nativeCallActive = false;
  }
}

/// Typed outcomes from [IsometrikMeetingRouter.route] — map 1:1 to Swift `MQTT+ISMCall.swift` branches.
sealed class IsometrikRoutedMeetingEvent {
  const IsometrikRoutedMeetingEvent({required this.meeting});

  final IsometrikMeeting meeting;
}

/// `meetingCreated` — Swift stores `callDetails`; app may show incoming or update state.
final class IsometrikRoutedMeetingCreated extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedMeetingCreated({required super.meeting});
}

/// `meetingEndedDueToNoUserPublishing` — Swift disconnects LiveKit UI + ends CallKit when meeting matches.
final class IsometrikRoutedMeetingEnded extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedMeetingEnded({required super.meeting});
}

/// `memberLeave` / `joinRequestReject` — Swift ends CallKit when `callDetails` matches.
final class IsometrikRoutedMemberLeftOrRejected
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedMemberLeftOrRejected({required super.meeting});
}

/// Remote user started publishing / join accepted — Swift calls `startTheCall()` (outgoing connected).
final class IsometrikRoutedRemotePublishingStarted
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedRemotePublishingStarted({required super.meeting});
}

/// Same user answered on another device — Swift ends this device’s CallKit call.
final class IsometrikRoutedLocalSessionSuperseded
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedLocalSessionSuperseded({required super.meeting});
}

/// Sub-message `callRinging` from another participant.
final class IsometrikRoutedCallRinging extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedCallRinging({required super.meeting});
}

/// Sub-message `requestToSwitchToVideoCall`.
final class IsometrikRoutedVideoUpgradeRequest
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedVideoUpgradeRequest({required super.meeting});
}

/// Sub-message `requestToSwitchToVideoCallRejected`.
final class IsometrikRoutedVideoUpgradeRejected
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedVideoUpgradeRejected({required super.meeting});
}

/// Sub-message `requestToSwitchToVideoCallAccepted`.
final class IsometrikRoutedVideoUpgradeAccepted
    extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedVideoUpgradeAccepted({required super.meeting});
}

/// No event produced (conditions not met) or unknown `action` — useful for logging only.
final class IsometrikRoutedIgnored extends IsometrikRoutedMeetingEvent {
  const IsometrikRoutedIgnored({required super.meeting, this.reason});

  final String? reason;
}

/// Routes MQTT `IsometrikMeeting` payloads like Swift `ISMMQTTManager.handleTheMeetingEvents`.
///
/// **Usage:** update [context] from your call UI / SDK, then `bind(mqtt)` and listen to [events].
class IsometrikMeetingRouter {
  IsometrikMeetingRouter({required this.context});

  final IsometrikMeetingRouterContext context;

  final StreamController<IsometrikRoutedMeetingEvent> _controller =
      StreamController<IsometrikRoutedMeetingEvent>.broadcast();

  Stream<IsometrikRoutedMeetingEvent> get events => _controller.stream;

  StreamSubscription<IsometrikMeeting>? _mqttSub;

  /// Subscribe to [IsometrikMqttService.meetingEvents] and emit routed events.
  void bind(IsometrikMqttService mqtt) {
    unbind();
    _mqttSub = mqtt.meetingEvents.listen(_emitRouted);
  }

  void unbind() {
    _mqttSub?.cancel();
    _mqttSub = null;
  }

  void dispose() {
    unbind();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  void _emitRouted(IsometrikMeeting meeting) {
    for (final IsometrikRoutedMeetingEvent e in route(meeting)) {
      if (!_controller.isClosed) {
        _controller.add(e);
      }
    }
  }

  /// Pure routing — call from tests or custom streams without MQTT.
  List<IsometrikRoutedMeetingEvent> route(IsometrikMeeting meeting) {
    final uid = context.currentUserId;
    switch (meeting.meetingAction) {
      case IsometrikMeetingAction.meetingCreated:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedMeetingCreated(meeting: meeting),
        ];

      case IsometrikMeetingAction.meetingEnded:
        final mid = meeting.meetingId;
        if (mid == null) {
          return <IsometrikRoutedMeetingEvent>[
            IsometrikRoutedIgnored(
              meeting: meeting,
              reason: 'meetingEnded missing meetingId',
            ),
          ];
        }
        final matchesUi = context.uiMeetingId == mid;
        final matchesDetails = context.callDetailsMeetingId == mid;
        if (matchesUi || matchesDetails) {
          return <IsometrikRoutedMeetingEvent>[
            IsometrikRoutedMeetingEnded(meeting: meeting),
          ];
        }
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedIgnored(
            meeting: meeting,
            reason: 'meetingEnded no matching active meeting',
          ),
        ];

      case IsometrikMeetingAction.memberLeft:
      case IsometrikMeetingAction.joinRequestReject:
        // Swift: `callDetails?.meetingId == meeting.meetingId` — also match in-call UI id
        // (`uiMeetingId`) so Flutter screens that only set `uiMeetingId` still react.
        final mid = meeting.meetingId;
        final matches = mid != null &&
            (context.callDetailsMeetingId == mid ||
                context.uiMeetingId == mid);
        if (matches) {
          return <IsometrikRoutedMeetingEvent>[
            IsometrikRoutedMemberLeftOrRejected(meeting: meeting),
          ];
        }
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedIgnored(
            meeting: meeting,
            reason: 'memberLeft/joinReject no matching active meeting',
          ),
        ];

      case IsometrikMeetingAction.publishingStarted:
      case IsometrikMeetingAction.joinRequestAccept:
        final senderId = meeting.userId;
        if (senderId != null &&
            uid != null &&
            senderId != uid &&
            context.outgoingCallPending) {
          return <IsometrikRoutedMeetingEvent>[
            IsometrikRoutedRemotePublishingStarted(meeting: meeting),
          ];
        }
        if (senderId != null &&
            uid != null &&
            senderId == uid &&
            context.nativeCallActive &&
            context.callAnsweredByDeviceId == null) {
          return <IsometrikRoutedMeetingEvent>[
            IsometrikRoutedLocalSessionSuperseded(meeting: meeting),
          ];
        }
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedIgnored(
            meeting: meeting,
            reason: 'publishingStarted/joinAccept conditions not met',
          ),
        ];

      case IsometrikMeetingAction.messagePublished:
        return _routeMessagePublished(meeting, uid);

      case IsometrikMeetingAction.unknown:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedIgnored(
            meeting: meeting,
            reason: 'unknown or empty action',
          ),
        ];
    }
  }

  List<IsometrikRoutedMeetingEvent> _routeMessagePublished(
    IsometrikMeeting meeting,
    String? uid,
  ) {
    final senderId = meeting.senderId;
    final body = meeting.body;
    if (senderId == null || uid == null || senderId == uid || body == null) {
      return <IsometrikRoutedMeetingEvent>[
        IsometrikRoutedIgnored(
          meeting: meeting,
          reason: 'messagePublished filtered (self or missing body)',
        ),
      ];
    }
    switch (IsometrikPublishMessage.fromBody(body)) {
      case IsometrikPublishMessage.callRinging:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedCallRinging(meeting: meeting),
        ];
      case IsometrikPublishMessage.requestToSwitchToVideoCall:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedVideoUpgradeRequest(meeting: meeting),
        ];
      case IsometrikPublishMessage.requestToSwitchToVideoCallRejected:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedVideoUpgradeRejected(meeting: meeting),
        ];
      case IsometrikPublishMessage.requestToSwitchToVideoCallAccepted:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedVideoUpgradeAccepted(meeting: meeting),
        ];
      case IsometrikPublishMessage.requestToSwitchToVideoCallCancelled:
      case IsometrikPublishMessage.unknown:
        return <IsometrikRoutedMeetingEvent>[
          IsometrikRoutedIgnored(
            meeting: meeting,
            reason: 'messagePublished unhandled body: $body',
          ),
        ];
    }
  }
}
