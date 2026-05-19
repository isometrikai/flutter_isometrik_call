import 'package:flutter/services.dart';

import '../../isometrik_flutter_call_platform_interface.dart';
import '../configuration/isometrik_call_configuration.dart';

/// Small UI helper for outgoing target (not the same as API `IsometrikDirectoryUser`).
class IsometrikCallDisplayUser {
  const IsometrikCallDisplayUser({
    required this.userId,
    required this.userName,
    this.avatarUrl,
  });

  final String userId;
  final String userName;
  final String? avatarUrl;
}

/// Events emitted by native iOS CallKit/PushKit (and Android no-ops).
///
/// **iOS extras:** `callAudioSessionActivated` (CallKit `didActivate` — native audio
/// coordinator already running; Dart may refresh LiveKit routes), `iosAppBecameActive`
/// (unlock / app resume).
class IsometrikNativeCallEvent {
  const IsometrikNativeCallEvent({required this.type, required this.payload});

  final String type;
  final Map<String, dynamic> payload;

  factory IsometrikNativeCallEvent.fromMap(Map<String, dynamic> map) {
    return IsometrikNativeCallEvent(
      type: map['type'] as String? ?? 'unknown',
      payload: Map<String, dynamic>.from(
        map['payload'] as Map? ?? <String, dynamic>{},
      ),
    );
  }
}

/// Native-only bridge: CallKit / PushKit / audio route (mirrors `ISMCallManager` surface).
class IsometrikFlutterCall {
  IsometrikFlutterCall();

  Stream<IsometrikNativeCallEvent>? _sharedEvents;

  Future<void> initialize(IsometrikCallConfiguration configuration) {
    return IsometrikFlutterCallPlatform.instance.initialize(
      configuration.toNativeMap(),
    );
  }

  Future<void> updateUserSession({
    required String userId,
    required String userToken,
  }) {
    return IsometrikFlutterCallPlatform.instance.updateUserSession(
      userId: userId,
      userToken: userToken,
    );
  }

  Future<void> registerForVoipPushes() {
    return IsometrikFlutterCallPlatform.instance.registerForVoipPushes();
  }

  Future<void> unregisterVoipToken() {
    return IsometrikFlutterCallPlatform.instance.unregisterVoipToken();
  }

  Future<void> startOutgoingCall({
    required IsometrikCallDisplayUser callee,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) {
    return IsometrikFlutterCallPlatform.instance.startOutgoingCall(
      calleeName: callee.userName,
      callId: callId,
      hasVideo: hasVideo,
      metadata: metadata,
    );
  }

  Future<void> reportIncomingCall({
    required String callerName,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) {
    return IsometrikFlutterCallPlatform.instance.reportIncomingCall(
      callerName: callerName,
      callId: callId,
      hasVideo: hasVideo,
      metadata: metadata,
    );
  }

  Future<void> endCurrentCall({String? callId}) {
    return IsometrikFlutterCallPlatform.instance.endCurrentCall(callId: callId);
  }

  Future<void> setMute(bool isMuted) {
    return IsometrikFlutterCallPlatform.instance.setMute(isMuted);
  }

  Future<void> setSpeaker(bool isSpeakerOn) {
    return IsometrikFlutterCallPlatform.instance.setSpeaker(isSpeakerOn);
  }

  Future<bool> canMakeOutgoingCall() {
    return IsometrikFlutterCallPlatform.instance.canMakeOutgoingCall();
  }

  Future<void> reportOutgoingCallConnected() {
    return IsometrikFlutterCallPlatform.instance.reportOutgoingCallConnected();
  }

  Future<void> scheduleHangup({required double seconds}) {
    return IsometrikFlutterCallPlatform.instance.scheduleHangup(
      seconds: seconds,
    );
  }

  Future<void> cancelScheduledHangup() {
    return IsometrikFlutterCallPlatform.instance.cancelScheduledHangup();
  }

  /// iOS: native VoIP audio coordinator — stable session + main-runloop watchdog.
  /// **Reuse:** Prefer these over Dart `Future.delayed` when backgrounded / locked.
  Future<void> beginIosVoipCallAudio({
    bool hasVideo = false,
    bool preferSpeaker = false,
  }) async {
    try {
      await IsometrikFlutterCallPlatform.instance.beginIosVoipCallAudio(
        hasVideo: hasVideo,
        preferSpeaker: preferSpeaker,
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> refreshIosVoipCallAudio({
    bool hasVideo = false,
    bool preferSpeaker = false,
    bool hardReset = false,
  }) async {
    try {
      await IsometrikFlutterCallPlatform.instance.refreshIosVoipCallAudio(
        hasVideo: hasVideo,
        preferSpeaker: preferSpeaker,
        hardReset: hardReset,
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> endIosVoipCallAudio() async {
    try {
      await IsometrikFlutterCallPlatform.instance.endIosVoipCallAudio();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// iOS: stop native session churn after LiveKit `Room.connect` (prevents audio glitch loops).
  Future<void> handoffIosVoipCallAudioToLiveKit() async {
    try {
      await IsometrikFlutterCallPlatform.instance
          .handoffIosVoipCallAudioToLiveKit();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Legacy alias — prefer [refreshIosVoipCallAudio].
  Future<void> reactivateIosCallAudioSession({
    bool hasVideo = false,
    bool preferSpeaker = false,
    bool hardReset = false,
  }) async {
    try {
      await IsometrikFlutterCallPlatform.instance.reactivateIosCallAudioSession(
        hasVideo: hasVideo,
        preferSpeaker: preferSpeaker,
        hardReset: hardReset,
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// iOS PushKit path may already show CallKit; returns whether to skip Dart-initiated
  /// [reportIncomingCall]. Safe on all platforms (false when unsupported).
  Future<bool> wasCallKitReportedNatively() async {
    try {
      return await IsometrikFlutterCallPlatform.instance
          .wasCallKitReportedNatively();
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      if (e.code == 'channel-error' || e.code == 'not-implemented') {
        return false;
      }
      return false;
    }
  }

  Future<Map<String, dynamic>> requestRuntimePermissions({
    required bool requestMicrophone,
    required bool requestCamera,
  }) {
    return IsometrikFlutterCallPlatform.instance.requestRuntimePermissions(
      requestMicrophone: requestMicrophone,
      requestCamera: requestCamera,
    );
  }

  Stream<IsometrikNativeCallEvent> get events {
    return _sharedEvents ??=
        IsometrikFlutterCallPlatform.instance
            .events()
            .map(IsometrikNativeCallEvent.fromMap)
            .asBroadcastStream();
  }

  /// iOS: reads a **ring buffer** in `UserDefaults` written on each VoIP push (keys only, outcomes).
  ///
  /// **`pushkit_delegate_invoked`** rows prove the OS called the PushKit delegate (before main/async);
  /// **`pushkit`** rows follow after CallKit handling. Inspect after a suspected missed push (`usedFallbackCallId`,
  /// `callKitError`, `payloadTopLevelKeys`). Cleared via [clearIosPushKitDiagnostics]. Non‑iOS: empty list.
  Future<List<Map<String, dynamic>>> getIosPushKitDiagnostics() async {
    try {
      return await IsometrikFlutterCallPlatform.instance
          .getIosPushKitDiagnostics();
    } on MissingPluginException {
      return <Map<String, dynamic>>[];
    } on PlatformException {
      return <Map<String, dynamic>>[];
    }
  }

  /// Clears persisted VoIP diagnostics (iOS); no‑op elsewhere.
  Future<void> clearIosPushKitDiagnostics() async {
    try {
      await IsometrikFlutterCallPlatform.instance.clearIosPushKitDiagnostics();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
