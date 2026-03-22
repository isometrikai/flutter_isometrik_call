import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/isometrik_api_error.dart';
import '../livekit_session_manager.dart';
import '../models/models.dart';
import '../platform/isometrik_flutter_call_facade.dart';
import '../router/isometrik_meeting_router.dart';
import '../sdk/isometrik_call_sdk.dart';

/// Call lifecycle status — mirrors Swift `ISMCallStatus` in `ISMLiveCallView.swift`.
///
/// Transitions driven by MQTT events (see `MQTT+ISMCall.swift`):
///   outgoing: [calling] → [ringing] (callRinging) → [connected] (publishingStarted)
///   incoming: [connecting] (accepted) → [connected] (LiveKit + startPublishing)
enum IsometrikCallStatus {
  /// Outgoing: meeting created, waiting for remote device.
  calling,

  /// Remote device is ringing (MQTT `callRinging` message).
  ringing,

  /// Incoming accepted — setting up media (LiveKit connect + startPublishing).
  connecting,

  /// Call is live; timer running.
  connected,

  /// Call has ended.
  ended,
}

/// Manages the full state of an active call: status transitions, timer,
/// audio controls, video upgrade negotiation, and LiveKit media session.
///
/// Mirrors Swift `ISMLiveCallView` state + `MQTT+ISMCall.swift` event routing.
///
/// **Usage:** Create via [IsometrikCallSdk.startCall] for outgoing or from
/// the SDK's auto-handling for incoming. Pass to [IsometrikCallPage].
///
/// The controller listens to MQTT router events and native CallKit events
/// for its [meetingId] and updates status accordingly. It also manages
/// the LiveKit connection and REST `startPublishing` call when the call
/// becomes [IsometrikCallStatus.connected].
class IsometrikCallController extends ChangeNotifier {
  IsometrikCallController({
    required this.sdk,
    required this.meetingId,
    required this.peerName,
    required this.isOutgoing,
    this.hasVideo = false,
    this.rtcToken,
    this.peerImageUrl,
    IsometrikCallStatus initialStatus = IsometrikCallStatus.calling,
  }) : _status = initialStatus {
    _attach();
  }

  final IsometrikCallSdk sdk;
  final String meetingId;
  final String peerName;
  final String? peerImageUrl;
  final bool isOutgoing;

  /// RTC token for LiveKit — set on creation (outgoing) or after accept API (incoming).
  String? rtcToken;

  /// Tracks whether video is active; toggled by video upgrade acceptance.
  bool hasVideo;

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------

  IsometrikCallStatus _status;
  IsometrikCallStatus get status => _status;

  // ---------------------------------------------------------------------------
  // Timer
  // ---------------------------------------------------------------------------

  DateTime? _connectedAt;
  Timer? _tick;

  /// Formatted elapsed time since connected (e.g. "01:23" or "01:02:03").
  String get elapsed {
    final ca = _connectedAt;
    if (ca == null) return '';
    final d = DateTime.now().difference(ca);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }

  /// Human-readable status label for the call UI.
  String get statusText => switch (_status) {
    IsometrikCallStatus.calling => 'Calling…',
    IsometrikCallStatus.ringing => 'Ringing…',
    IsometrikCallStatus.connecting => 'Connecting…',
    IsometrikCallStatus.connected => elapsed,
    IsometrikCallStatus.ended => 'Call Ended',
  };

  // ---------------------------------------------------------------------------
  // Audio controls
  // ---------------------------------------------------------------------------

  bool _muted = false;
  bool get isMuted => _muted;

  bool _speaker = false;
  bool get isSpeaker => _speaker;

  // ---------------------------------------------------------------------------
  // Video upgrade (mirrors Swift ISMExpandableCallControlsViewDelegate)
  // ---------------------------------------------------------------------------

  IsometrikMeeting? _videoUpgradeRequest;
  IsometrikMeeting? get videoUpgradeRequest => _videoUpgradeRequest;

  bool _publishBusy = false;
  bool get isPublishBusy => _publishBusy;

  // ---------------------------------------------------------------------------
  // LiveKit media session
  // ---------------------------------------------------------------------------

  final IsometrikLiveKitSessionManager _liveKit =
      IsometrikLiveKitSessionManager();
  IsometrikLiveKitSessionManager get liveKit => _liveKit;

  // ---------------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------------

  StreamSubscription<IsometrikRoutedMeetingEvent>? _mqttSub;
  StreamSubscription<IsometrikNativeCallEvent>? _nativeSub;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void _attach() {
    sdk.meetingRouterContext.uiMeetingId = meetingId;

    _mqttSub = sdk.meetingRouter.events.listen(_onMqttEvent);
    _nativeSub = sdk.native.events.listen(_onNativeEvent);

    // Incoming-accepted: immediately start connecting media.
    if (_status == IsometrikCallStatus.connecting) {
      _connectAndPublish();
    }
  }

  void _onMqttEvent(IsometrikRoutedMeetingEvent e) {
    final mid = e.meeting.meetingId;
    if (mid == null || mid != meetingId) return;

    switch (e) {
      case IsometrikRoutedCallRinging():
        _setStatus(IsometrikCallStatus.ringing);
      case IsometrikRoutedRemotePublishingStarted():
        // Remote user published — our turn to connect & publish.
        _connectAndPublish();
      case IsometrikRoutedMeetingEnded():
      case IsometrikRoutedMemberLeftOrRejected():
        _setStatus(IsometrikCallStatus.ended);
      case IsometrikRoutedVideoUpgradeRequest():
        _videoUpgradeRequest = e.meeting;
        notifyListeners();
      case IsometrikRoutedVideoUpgradeRejected():
        _videoUpgradeRequest = null;
        notifyListeners();
      case IsometrikRoutedVideoUpgradeAccepted():
        _videoUpgradeRequest = null;
        hasVideo = true;
        notifyListeners();
      default:
        break;
    }
  }

  void _onNativeEvent(IsometrikNativeCallEvent e) {
    if (e.type == 'callEnded') {
      _setStatus(IsometrikCallStatus.ended);
    }
  }

  void _setStatus(IsometrikCallStatus s) {
    if (_status == s || _status == IsometrikCallStatus.ended) return;
    _status = s;
    notifyListeners();
  }

  /// Connect LiveKit room, call `startPublishing` API, start timer.
  /// Called when: (a) outgoing call — remote publishingStarted,
  ///              (b) incoming call — after accept API succeeds.
  Future<void> _connectAndPublish() async {
    if (_status == IsometrikCallStatus.connected) return;

    _connectedAt = DateTime.now();
    _setStatus(IsometrikCallStatus.connected);

    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });

    // Cancel the no-answer hangup timer (mirrors Swift startTheCall).
    try {
      await sdk.native.cancelScheduledHangup();
    } catch (_) {}

    final token = rtcToken;
    final url = sdk.configuration?.streamingUrl;
    if (token != null && token.isNotEmpty && url != null) {
      try {
        await _liveKit.connect(url: url, token: token);
      } catch (e) {
        debugPrint('IsometrikCallController: LiveKit connect error: $e');
      }
    }

    try {
      await sdk.startPublishing(meetingId: meetingId);
    } catch (e) {
      debugPrint('IsometrikCallController: startPublishing error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // User actions
  // ---------------------------------------------------------------------------

  /// Toggle microphone mute.
  Future<void> toggleMute() async {
    _muted = !_muted;
    try {
      await sdk.native.setMute(_muted);
    } catch (_) {}
    notifyListeners();
  }

  /// Toggle speaker / earpiece.
  Future<void> toggleSpeaker() async {
    _speaker = !_speaker;
    try {
      await sdk.native.setSpeaker(_speaker);
    } catch (_) {}
    notifyListeners();
  }

  /// End the call: disconnect media, end CallKit, leave meeting.
  Future<void> endCall() async {
    if (_status == IsometrikCallStatus.ended) return;
    _setStatus(IsometrikCallStatus.ended);
    await _liveKit.disconnect();
    try {
      await sdk.endNativeCall();
    } catch (_) {}
    try {
      await sdk.meetings.leaveMeeting(meetingId: meetingId);
    } catch (_) {}
  }

  /// Send a video upgrade request to the peer (MQTT publishMessage).
  Future<void> requestVideoUpgrade() async {
    if (_publishBusy || meetingId.isEmpty) return;
    _publishBusy = true;
    notifyListeners();
    await sdk.publishVideoUpgradeRequest(meetingId: meetingId);
    _publishBusy = false;
    notifyListeners();
  }

  /// Accept or decline an incoming video upgrade request.
  Future<void> respondToVideoUpgrade({required bool accept}) async {
    if (_publishBusy || meetingId.isEmpty) return;
    _publishBusy = true;
    notifyListeners();

    if (accept) {
      await sdk.publishVideoUpgradeAccepted(meetingId: meetingId);
      hasVideo = true;
    } else {
      await sdk.publishVideoUpgradeRejected(meetingId: meetingId);
    }
    _videoUpgradeRequest = null;
    _publishBusy = false;
    notifyListeners();
  }

  /// Handle incoming call acceptance — call accept API, then connect media.
  /// Typically called by the SDK's auto handler; exposed for manual use.
  Future<void> handleIncomingAccepted() async {
    _setStatus(IsometrikCallStatus.connecting);
    final r = await sdk.acceptCall(meetingId: meetingId);
    switch (r) {
      case IsometrikSuccess(:final data):
        rtcToken = data.rtcToken;
        await _connectAndPublish();
      case IsometrikFailure():
        _setStatus(IsometrikCallStatus.ended);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_mqttSub?.cancel());
    unawaited(_nativeSub?.cancel());
    if (sdk.meetingRouterContext.uiMeetingId == meetingId) {
      sdk.meetingRouterContext.uiMeetingId = null;
    }
    unawaited(_liveKit.disconnect());
    super.dispose();
  }
}
