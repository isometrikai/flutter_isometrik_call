import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'isometrik_flutter_call_platform_interface.dart';

/// An implementation of [IsometrikFlutterCallPlatform] that uses method channels.
class MethodChannelIsometrikFlutterCall extends IsometrikFlutterCallPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('isometrik_flutter_call');

  @visibleForTesting
  final eventChannel = const EventChannel('isometrik_flutter_call/events');

  @override
  Future<void> initialize(Map<String, dynamic> configuration) async {
    await methodChannel.invokeMethod<void>('initialize', configuration);
  }

  @override
  Future<void> updateUserSession({
    required String userId,
    required String userToken,
  }) async {
    await methodChannel.invokeMethod<void>('updateUserSession', {
      'userId': userId,
      'userToken': userToken,
    });
  }

  @override
  Future<void> registerForVoipPushes() async {
    await methodChannel.invokeMethod<void>('registerForVoipPushes');
  }

  @override
  Future<void> unregisterVoipToken() async {
    await methodChannel.invokeMethod<void>('unregisterVoipToken');
  }

  @override
  Future<void> reportIncomingCall({
    required String callerName,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) async {
    await methodChannel.invokeMethod<void>('reportIncomingCall', {
      'callerName': callerName,
      'callId': callId,
      'hasVideo': hasVideo,
      'metadata': metadata ?? <String, dynamic>{},
    });
  }

  @override
  Future<void> startOutgoingCall({
    required String calleeName,
    required String callId,
    bool hasVideo = false,
    Map<String, dynamic>? metadata,
  }) async {
    await methodChannel.invokeMethod<void>('startOutgoingCall', {
      'calleeName': calleeName,
      'callId': callId,
      'hasVideo': hasVideo,
      'metadata': metadata ?? <String, dynamic>{},
    });
  }

  @override
  Future<void> endCurrentCall({String? callId}) async {
    await methodChannel.invokeMethod<void>('endCurrentCall', {
      'callId': callId,
    });
  }

  @override
  Future<void> setMute(bool isMuted) async {
    await methodChannel.invokeMethod<void>('setMute', {'isMuted': isMuted});
  }

  @override
  Future<void> setSpeaker(bool isSpeakerOn) async {
    await methodChannel.invokeMethod<void>('setSpeaker', {
      'isSpeakerOn': isSpeakerOn,
    });
  }

  @override
  Future<bool> canMakeOutgoingCall() async {
    final r = await methodChannel.invokeMethod<bool>('canMakeOutgoingCall');
    return r ?? true;
  }

  @override
  Future<void> reportOutgoingCallConnected() async {
    await methodChannel.invokeMethod<void>('reportOutgoingCallConnected');
  }

  @override
  Future<void> scheduleHangup({required double seconds}) async {
    await methodChannel.invokeMethod<void>('scheduleHangup', {
      'seconds': seconds,
    });
  }

  @override
  Future<void> cancelScheduledHangup() async {
    await methodChannel.invokeMethod<void>('cancelScheduledHangup');
  }

  @override
  Stream<Map<String, dynamic>> events() {
    return eventChannel.receiveBroadcastStream().map((dynamic event) {
      return Map<String, dynamic>.from(event as Map);
    });
  }
}
