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
  Future<void> beginIosVoipCallAudio({
    bool hasVideo = false,
    bool preferSpeaker = false,
  }) async {
    await methodChannel.invokeMethod<void>('iosBeginVoipCallAudio', {
      'hasVideo': hasVideo,
      'preferSpeaker': preferSpeaker,
    });
  }

  @override
  Future<void> refreshIosVoipCallAudio({
    bool hasVideo = false,
    bool preferSpeaker = false,
    bool hardReset = false,
  }) async {
    await methodChannel.invokeMethod<void>('iosRefreshVoipCallAudio', {
      'hasVideo': hasVideo,
      'preferSpeaker': preferSpeaker,
      'hardReset': hardReset,
    });
  }

  @override
  Future<void> endIosVoipCallAudio() async {
    await methodChannel.invokeMethod<void>('iosEndVoipCallAudio');
  }

  @override
  Future<void> handoffIosVoipCallAudioToLiveKit() async {
    await methodChannel.invokeMethod<void>('iosHandoffVoipCallAudioToLiveKit');
  }

  @override
  Future<void> reactivateIosCallAudioSession({
    bool hasVideo = false,
    bool preferSpeaker = false,
    bool hardReset = false,
  }) async {
    await methodChannel.invokeMethod<void>('reactivateIosCallAudioSession', {
      'hasVideo': hasVideo,
      'preferSpeaker': preferSpeaker,
      'hardReset': hardReset,
    });
  }

  @override
  Future<bool> wasCallKitReportedNatively() async {
    final dynamic r = await methodChannel.invokeMethod<dynamic>(
      'wasCallKitReportedNatively',
    );
    if (r is bool) return r;
    if (r is num) return r != 0;
    return false;
  }

  @override
  Future<Map<String, dynamic>> requestRuntimePermissions({
    required bool requestMicrophone,
    required bool requestCamera,
  }) async {
    final response = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'requestRuntimePermissions',
      <String, dynamic>{
        'requestMicrophone': requestMicrophone,
        'requestCamera': requestCamera,
      },
    );
    return Map<String, dynamic>.from(response ?? <String, dynamic>{});
  }

  @override
  Future<List<Map<String, dynamic>>> getIosPushKitDiagnostics() async {
    final dynamic rows = await methodChannel.invokeMethod<dynamic>(
      'getIosPushKitDiagnostics',
    );
    if (rows is! List<dynamic>) {
      return <Map<String, dynamic>>[];
    }
    return rows
        .map(
          (dynamic e) =>
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
        )
        .toList();
  }

  @override
  Future<void> clearIosPushKitDiagnostics() async {
    await methodChannel.invokeMethod<void>('clearIosPushKitDiagnostics');
  }

  @override
  Stream<Map<String, dynamic>> events() {
    return eventChannel.receiveBroadcastStream().map((dynamic event) {
      return Map<String, dynamic>.from(event as Map);
    });
  }
}
