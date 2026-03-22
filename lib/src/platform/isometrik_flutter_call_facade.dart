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
  const IsometrikFlutterCall();

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

  Stream<IsometrikNativeCallEvent> get events {
    return IsometrikFlutterCallPlatform.instance.events().map(
      IsometrikNativeCallEvent.fromMap,
    );
  }
}
