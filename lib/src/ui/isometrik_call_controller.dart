import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

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
    this.preflightPermissionsOnInit = false,
    IsometrikCallStatus initialStatus = IsometrikCallStatus.calling,
  }) : _status = initialStatus {
    _localVideoEnabled = hasVideo;
    _attach();
  }

  final IsometrikCallSdk sdk;
  final String meetingId;
  final String peerName;
  final String? peerImageUrl;
  final bool isOutgoing;
  final bool preflightPermissionsOnInit;

  /// RTC token for LiveKit — set on creation (outgoing) or after accept API (incoming).
  String? rtcToken;

  /// Tracks whether video is active; toggled by video upgrade acceptance.
  bool hasVideo;

  /// True when in-call UI is shown as a minimized floating window.
  ///
  /// This lets host apps react consistently and avoids duplicating minimize
  /// state in multiple widgets.
  bool _isMinimized = false;
  bool get isMinimized => _isMinimized;

  /// Last on-screen position of minimized window (logical pixels).
  Offset _minimizedWindowOffset = const Offset(16, 120);
  Offset get minimizedWindowOffset => _minimizedWindowOffset;

  /// Last permission failure message shown in UI fallback.
  String? _permissionsMessage;
  String? get permissionsMessage => _permissionsMessage;
  bool _permissionPreflightTriggered = false;
  Future<bool>? _permissionRequestInFlight;

  /// True when required runtime permissions are missing for the active call mode.
  bool get hasMissingPermissions => _permissionsMessage != null;

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
  // Video controls
  // ---------------------------------------------------------------------------

  /// Whether the local camera stream is currently enabled.
  ///
  /// This is intentionally tracked in controller state so UI can react even
  /// when LiveKit publishes/unpublishes asynchronously.
  bool _localVideoEnabled = false;
  bool get isLocalVideoEnabled => _localVideoEnabled;

  /// Current preferred camera side for local publishing.
  bool _isFrontCamera = true;
  bool get isFrontCamera => _isFrontCamera;
  bool _cameraFlipInProgress = false;

  /// True when at least one local/remote video track is currently published.
  ///
  /// Used by UI to gracefully fall back to an audio-focused layout when all
  /// participants disable camera streams.
  bool get hasAnyVideoStreaming {
    final room = _liveKit.currentRoom;
    if (room == null) return false;

    bool hasTrack(Participant? participant) {
      if (participant == null) return false;
      for (final publication in participant.videoTrackPublications) {
        if (publication.track != null) return true;
      }
      return false;
    }

    if (hasTrack(room.localParticipant)) return true;
    for (final participant in room.remoteParticipants.values) {
      if (hasTrack(participant)) return true;
    }
    return false;
  }

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

    // Optional SDK-level preflight so iOS system permission prompts can be
    // shown as soon as call intent starts (outgoing create / incoming accept).
    if (preflightPermissionsOnInit) {
      unawaited(preflightPermissionsIfNeeded());
    }

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
        _localVideoEnabled = true;
        unawaited(_syncLocalMediaState());
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

    final granted = await _ensureRequiredPermissions();
    if (!granted) return;

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
        await _syncLocalMediaState();
        await _syncLocalAudioState();
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

  /// Requests and validates permissions needed for the current call mode.
  ///
  /// Audio call requires microphone; video call requires both microphone + camera.
  /// Returns `true` only when all required permissions are granted.
  Future<bool> _ensureRequiredPermissions() async {
    final inFlight = _permissionRequestInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final request = _requestRequiredPermissionsInternal();
    _permissionRequestInFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_permissionRequestInFlight, request)) {
        _permissionRequestInFlight = null;
      }
    }
  }

  Future<bool> _requestRequiredPermissionsInternal() async {
    final required = <Permission>[
      Permission.microphone,
      if (hasVideo) Permission.camera,
    ];

    Map<Permission, PermissionStatus> statuses;
    try {
      statuses = await required.request();
    } on PlatformException catch (e) {
      // iOS permission_handler rejects concurrent requests with this error.
      // Wait briefly and read current permission state instead of failing call setup.
      if (e.code == 'ERROR_ALREADY_REQUESTING_PERMISSIONS') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        statuses = <Permission, PermissionStatus>{
          for (final permission in required) permission: await permission.status,
        };
      } else {
        rethrow;
      }
    }
    final missing = <String>[];
    var needsSettings = false;

    for (final entry in statuses.entries) {
      final permission = entry.key;
      final status = entry.value;
      if (status.isGranted) continue;

      if (permission == Permission.microphone) {
        missing.add('Microphone');
      } else if (permission == Permission.camera) {
        missing.add('Camera');
      } else {
        missing.add(permission.toString());
      }

      if (status.isPermanentlyDenied || status.isRestricted) {
        needsSettings = true;
      }
    }

    if (missing.isEmpty) {
      _permissionsMessage = null;
      notifyListeners();
      return true;
    }

    final missingText = missing.join(' and ');
    _permissionsMessage = needsSettings
        ? '$missingText permission is required. Please enable it from Settings.'
        : '$missingText permission is required to continue this call.';
    notifyListeners();
    return false;
  }

  /// Public permission preflight used by the call page.
  ///
  /// This prompts as soon as the in-call UI is shown, instead of waiting for
  /// later call lifecycle events.
  Future<bool> ensurePermissionsForCurrentCall() {
    return preflightPermissionsIfNeeded();
  }

  /// Triggers one-time permission preflight for this controller lifecycle.
  ///
  /// Safe to call from multiple places (SDK, call page, retry buttons).
  Future<bool> preflightPermissionsIfNeeded() async {
    if (_permissionPreflightTriggered) {
      return !hasMissingPermissions;
    }
    _permissionPreflightTriggered = true;
    return _ensureRequiredPermissions();
  }

  /// Public retry hook for the fallback UI after user grants permissions.
  Future<void> retryPermissionFlow() async {
    final granted = await _ensureRequiredPermissions();
    if (granted && _status != IsometrikCallStatus.ended) {
      await _connectAndPublish();
    }
  }

  /// Opens app settings so user can manually grant blocked permissions.
  Future<bool> openPermissionSettings() {
    return openAppSettings();
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
    final local = _liveKit.currentRoom?.localParticipant;
    if (local != null) {
      try {
        await local.setMicrophoneEnabled(!_muted);
      } catch (e) {
        debugPrint('IsometrikCallController: toggleMute error: $e');
      }
    }
    notifyListeners();
  }

  /// Toggle speaker / earpiece.
  Future<void> toggleSpeaker() async {
    _speaker = !_speaker;
    try {
      await sdk.native.setSpeaker(_speaker);
    } catch (_) {}
    final room = _liveKit.currentRoom;
    if (room != null) {
      try {
        await room.setSpeakerOn(_speaker);
      } catch (e) {
        debugPrint('IsometrikCallController: toggleSpeaker error: $e');
      }
    }
    notifyListeners();
  }

  /// Enable/disable local camera stream without ending the call.
  Future<void> toggleLocalVideo() async {
    if (!hasVideo || _status == IsometrikCallStatus.ended) return;

    final target = !_localVideoEnabled;
    if (target) {
      final granted = await _ensureRequiredPermissionsForVideoUpgrade();
      if (!granted) return;
    }

    _localVideoEnabled = target;
    notifyListeners();

    final local = _liveKit.currentRoom?.localParticipant;
    if (local == null) return;
    try {
      await local.setCameraEnabled(
        target,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition:
              _isFrontCamera ? CameraPosition.front : CameraPosition.back,
        ),
      );
    } catch (e) {
      debugPrint('IsometrikCallController: toggleLocalVideo error: $e');
    }
    notifyListeners();
  }

  /// Switches active camera between front and back.
  Future<void> flipCamera() async {
    if (!hasVideo ||
        !_localVideoEnabled ||
        _status == IsometrikCallStatus.ended ||
        _cameraFlipInProgress) {
      return;
    }

    _cameraFlipInProgress = true;
    final local = _liveKit.currentRoom?.localParticipant;
    if (local == null) {
      _cameraFlipInProgress = false;
      return;
    }
    final targetIsFront = !_isFrontCamera;
    final targetPosition =
        targetIsFront ? CameraPosition.front : CameraPosition.back;
    try {
      // Prefer native track camera switch for a seamless in-call flip.
      final localTrack = _firstLocalVideoTrack(local);
      if (localTrack != null) {
        await localTrack.setCameraPosition(targetPosition);
      } else {
        // Fallback: restart camera publication with target side.
        await local.setCameraEnabled(
          true,
          cameraCaptureOptions: CameraCaptureOptions(
            cameraPosition: targetPosition,
          ),
        );
      }
      _isFrontCamera = targetIsFront;
    } catch (e) {
      debugPrint('IsometrikCallController: flipCamera error: $e');
    } finally {
      _cameraFlipInProgress = false;
      notifyListeners();
    }
  }

  /// End the call: disconnect media, end CallKit, leave meeting.
  Future<void> endCall() async {
    if (_status == IsometrikCallStatus.ended) return;
    _setStatus(IsometrikCallStatus.ended);
    _isMinimized = false;
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
    try {
      await sdk.publishVideoUpgradeRequest(meetingId: meetingId);
    } catch (e) {
      debugPrint('IsometrikCallController: requestVideoUpgrade error: $e');
    } finally {
      _publishBusy = false;
      notifyListeners();
    }
  }

  /// Accept or decline an incoming video upgrade request.
  Future<void> respondToVideoUpgrade({required bool accept}) async {
    if (_publishBusy || meetingId.isEmpty) return;
    _publishBusy = true;
    notifyListeners();

    try {
      if (accept) {
        final granted = await _ensureRequiredPermissionsForVideoUpgrade();
        if (!granted) return;
        await sdk.publishVideoUpgradeAccepted(meetingId: meetingId);
        hasVideo = true;
        _localVideoEnabled = true;
        await _syncLocalMediaState();
      } else {
        await sdk.publishVideoUpgradeRejected(meetingId: meetingId);
      }
      _videoUpgradeRequest = null;
    } catch (e) {
      debugPrint('IsometrikCallController: respondToVideoUpgrade error: $e');
    } finally {
      _publishBusy = false;
      notifyListeners();
    }
  }

  /// Video upgrade is only allowed when both microphone and camera are granted.
  Future<bool> _ensureRequiredPermissionsForVideoUpgrade() async {
    final previousHasVideo = hasVideo;
    hasVideo = true;
    final granted = await _ensureRequiredPermissions();
    if (!granted) {
      hasVideo = previousHasVideo;
    }
    return granted;
  }

  Future<void> _syncLocalMediaState() async {
    if (_status == IsometrikCallStatus.ended) return;
    final local = _liveKit.currentRoom?.localParticipant;
    if (local == null) return;
    try {
      await local.setCameraEnabled(
        hasVideo && _localVideoEnabled,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition:
              _isFrontCamera ? CameraPosition.front : CameraPosition.back,
        ),
      );
    } catch (e) {
      debugPrint('IsometrikCallController: syncLocalMediaState error: $e');
    }
  }

  Future<void> _syncLocalAudioState() async {
    if (_status == IsometrikCallStatus.ended) return;
    final room = _liveKit.currentRoom;
    final local = room?.localParticipant;
    if (local == null || room == null) return;
    try {
      await local.setMicrophoneEnabled(!_muted);
      await room.setSpeakerOn(_speaker);
    } catch (e) {
      debugPrint('IsometrikCallController: syncLocalAudioState error: $e');
    }
  }

  LocalVideoTrack? _firstLocalVideoTrack(LocalParticipant participant) {
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track is LocalVideoTrack) return track;
    }
    return null;
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

  /// Marks the call UI as minimized/restored.
  void setMinimized(bool value) {
    if (_isMinimized == value) return;
    _isMinimized = value;
    notifyListeners();
  }

  /// Persists floating window drag position so it can be restored.
  void setMinimizedWindowOffset(Offset value) {
    if (_minimizedWindowOffset == value) return;
    _minimizedWindowOffset = value;
    notifyListeners();
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
