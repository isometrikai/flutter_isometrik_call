import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'isometrik_flutter_call_method_channel.dart';

abstract class IsometrikFlutterCallPlatform extends PlatformInterface {
  /// Constructs a IsometrikFlutterCallPlatform.
  IsometrikFlutterCallPlatform() : super(token: _token);

  static final Object _token = Object();

  static IsometrikFlutterCallPlatform _instance =
      MethodChannelIsometrikFlutterCall();

  /// The default instance of [IsometrikFlutterCallPlatform] to use.
  ///
  /// Defaults to [MethodChannelIsometrikFlutterCall].
  static IsometrikFlutterCallPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [IsometrikFlutterCallPlatform] when
  /// they register themselves.
  static set instance(IsometrikFlutterCallPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> initialize(Map<String, dynamic> configuration) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  Future<void> updateUserSession({
    required String userId,
    required String userToken,
  }) {
    throw UnimplementedError('updateUserSession() has not been implemented.');
  }

  Future<void> registerForVoipPushes() {
    throw UnimplementedError(
      'registerForVoipPushes() has not been implemented.',
    );
  }

  Future<void> unregisterVoipToken() {
    throw UnimplementedError('unregisterVoipToken() has not been implemented.');
  }

  Future<void> reportIncomingCall({
    required String callerName,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) {
    throw UnimplementedError('reportIncomingCall() has not been implemented.');
  }

  Future<void> startOutgoingCall({
    required String calleeName,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) {
    throw UnimplementedError('startOutgoingCall() has not been implemented.');
  }

  Future<void> endCurrentCall({String? callId}) {
    throw UnimplementedError('endCurrentCall() has not been implemented.');
  }

  Future<void> setMute(bool isMuted) {
    throw UnimplementedError('setMute() has not been implemented.');
  }

  Future<void> setSpeaker(bool isSpeakerOn) {
    throw UnimplementedError('setSpeaker() has not been implemented.');
  }

  /// Mirrors `ISMCallManager.canMakeAOutgoingCall()` (CXCallObserver).
  Future<bool> canMakeOutgoingCall() {
    throw UnimplementedError('canMakeOutgoingCall() has not been implemented.');
  }

  /// Mirrors `startTheCall()` — report outgoing connected (`reportOutgoingCall connectedAt`).
  Future<void> reportOutgoingCallConnected() {
    throw UnimplementedError(
      'reportOutgoingCallConnected() has not been implemented.',
    );
  }

  /// Mirrors `scheduleCallHangup` — auto end if not answered (seconds).
  Future<void> scheduleHangup({required double seconds}) {
    throw UnimplementedError('scheduleHangup() has not been implemented.');
  }

  /// Cancel scheduled hangup timer.
  Future<void> cancelScheduledHangup() {
    throw UnimplementedError(
      'cancelScheduledHangup() has not been implemented.',
    );
  }

  /// Android runtime permissions request (camera / microphone).
  Future<Map<String, dynamic>> requestRuntimePermissions({
    required bool requestMicrophone,
    required bool requestCamera,
  }) {
    throw UnimplementedError(
      'requestRuntimePermissions() has not been implemented.',
    );
  }

  Stream<Map<String, dynamic>> events() {
    throw UnimplementedError('events() has not been implemented.');
  }
}
