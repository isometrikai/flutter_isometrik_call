import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api/isometrik_api_error.dart';
import '../api/isometrik_http_client.dart';
import '../configuration/isometrik_call_configuration.dart';
import '../models/models.dart';
import '../platform/isometrik_flutter_call_facade.dart';
import '../repositories/auth_repository.dart';
import '../repositories/meeting_repository.dart';
import '../router/isometrik_meeting_router.dart';
import '../services/isometrik_device_id.dart';
import '../services/isometrik_mqtt_service.dart';
import '../services/isometrik_pushkit_token_store.dart';
import '../services/isometrik_session_state.dart';
import '../ui/isometrik_call_controller.dart';

class IsometrikCallPermissionsResult {
  const IsometrikCallPermissionsResult({
    required this.microphoneGranted,
    required this.cameraGranted,
    required this.requiresSettingsAction,
    this.message,
  });

  final bool microphoneGranted;
  final bool cameraGranted;
  final bool requiresSettingsAction;
  final String? message;

  bool get isGranted => microphoneGranted && cameraGranted;
}

/// True when the Flutter method channel has no native implementation (web, tests, or
/// plugin not registered). In that case REST/MQTT can still work; only CallKit/PushKit
/// bridge calls should be skipped — see [IsometrikCallSdk.updateUserSession].
bool _isNativeBridgeUnavailable(Object error) {
  if (error is MissingPluginException) {
    return true;
  }
  if (error is PlatformException) {
    if (error.code == 'channel-error' || error.code == 'not-implemented') {
      return true;
    }
    final String? m = error.message;
    if (m != null && m.contains('Unable to establish connection')) {
      return true;
    }
  }
  return false;
}

/// True when iOS CallKit cannot place an outgoing call (Simulator / unsupported).
/// Native code normally skips CallKit on the Simulator; this catches older plugins or
/// edge cases so REST + [meetingRouterContext] + in-app call UI still succeed.
bool _isCallKitOutgoingUnsupported(Object error) {
  if (error is PlatformException) {
    if (error.code == 'callkit_unsupported_simulator') {
      return true;
    }
    final String m = (error.message ?? '').toLowerCase();
    if (m.contains('simulator') &&
        (m.contains('callkit') || m.contains('outgoing'))) {
      return true;
    }
  }
  return false;
}

Future<void> _startOutgoingCallSkippingSimulatorFailures(
  IsometrikFlutterCall native, {
  required IsometrikCallDisplayUser callee,
  required String callId,
  required bool hasVideo,
  required Map<String, dynamic> metadata,
}) async {
  try {
    await native.startOutgoingCall(
      callee: callee,
      callId: callId,
      hasVideo: hasVideo,
      metadata: metadata,
    );
  } catch (e, st) {
    if (_isCallKitOutgoingUnsupported(e)) {
      debugPrint(
        'IsometrikCallSdk: outgoing CallKit skipped (simulator / unsupported): $e',
      );
      return;
    }
    Error.throwWithStackTrace(e, st);
  }
}

Future<void> _invokeNativeBridgeIgnoringMissingPlugin(
  Future<void> Function() call, {
  String? debugLabel,
}) async {
  try {
    await call();
  } catch (e, st) {
    if (_isNativeBridgeUnavailable(e)) {
      debugPrint(
        'IsometrikCallSdk: native bridge skipped'
        '${debugLabel != null ? ' ($debugLabel)' : ''}: $e',
      );
      return;
    }
    Error.throwWithStackTrace(e, st);
  }
}

/// High-level SDK matching Swift `IsometrikCall` + `ISMCallManager` + `ISMCallMeetingViewModel` + `ISMMQTTManager`.
///
/// Use one instance per app (or inject for tests).
class IsometrikCallSdk {
  IsometrikCallSdk();

  final IsometrikSessionState session = IsometrikSessionState();
  final IsometrikPushKitTokenStore pushKitTokenStore =
      IsometrikPushKitTokenStore();
  final IsometrikFlutterCall native = IsometrikFlutterCall();
  final IsometrikMqttService mqtt = IsometrikMqttService();

  /// Shared with [meetingRouter] — keep in sync with call UI / CallKit (see INTEGRATION.md).
  final IsometrikMeetingRouterContext meetingRouterContext =
      IsometrikMeetingRouterContext();

  IsometrikMeetingRouter? _meetingRouter;

  /// Lazily built router over [meetingRouterContext]; use [attachMeetingRouterToMqtt] after MQTT connects.
  IsometrikMeetingRouter get meetingRouter =>
      _meetingRouter ??= IsometrikMeetingRouter(context: meetingRouterContext);

  IsometrikHttpClient? _http;
  IsometrikMeetingRepository? _meetings;
  IsometrikAuthRepository? _auth;

  StreamSubscription<IsometrikNativeCallEvent>? _nativeSub;

  // ---------------------------------------------------------------------------
  // Auto call handling (mirrors Swift ISMCallManager global MQTT + CallKit)
  // ---------------------------------------------------------------------------

  StreamSubscription<IsometrikRoutedMeetingEvent>? _autoMqttSub;
  StreamSubscription<IsometrikNativeCallEvent>? _autoNativeSub;
  void Function(IsometrikCallController controller)? _onShowCallPage;
  bool _triggerPermissionsOnIncomingAccept = true;

  /// Stored incoming meeting for use when native `callAnswered` fires.
  /// Set by [reportIncomingCallFromMeeting], consumed by auto native handler.
  IsometrikMeeting? _pendingIncomingMeeting;

  IsometrikCallConfiguration? get configuration => session.configuration;

  String _firstNonEmpty(List<String?> values, {String fallback = ''}) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return fallback;
  }

  String _resolvePeerName({
    IsometrikMeeting? primary,
    IsometrikMeeting? secondary,
    String fallback = 'Unknown',
  }) {
    final fromMembers = <String?>[
      (primary?.members != null && primary!.members!.isNotEmpty)
          ? primary.members!.first.memberName
          : null,
      (secondary?.members != null && secondary!.members!.isNotEmpty)
          ? secondary.members!.first.memberName
          : null,
    ];
    return _firstNonEmpty(<String?>[
      primary?.initiatorName,
      secondary?.initiatorName,
      primary?.senderName,
      secondary?.senderName,
      ...fromMembers,
      primary?.initiatorIdentifier,
      secondary?.initiatorIdentifier,
      primary?.senderId,
      secondary?.senderId,
      primary?.createdBy,
      secondary?.createdBy,
    ], fallback: fallback);
  }

  IsometrikLiveCallType _resolveCallType({
    IsometrikMeeting? primary,
    IsometrikMeeting? secondary,
    IsometrikLiveCallType fallback = IsometrikLiveCallType.audioCall,
  }) {
    final customType = _firstNonEmpty(<String?>[
      primary?.customType,
      secondary?.customType,
    ]);
    if (customType.isNotEmpty) {
      return IsometrikMeeting(customType: customType).callType;
    }
    final audioOnly = primary?.audioOnly ?? secondary?.audioOnly;
    if (audioOnly != null) {
      return audioOnly
          ? IsometrikLiveCallType.audioCall
          : IsometrikLiveCallType.videoCall;
    }
    return fallback;
  }

  Future<IsometrikCallPermissionsResult> ensureCallPermissions({
    required bool hasVideo,
  }) async {
    // Android: use native plugin permission request for reliable SDK-level control.
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final response = await native.requestRuntimePermissions(
          requestMicrophone: true,
          requestCamera: hasVideo,
        );
        final microphoneGranted = response['microphoneGranted'] == true;
        final cameraGranted = hasVideo
            ? response['cameraGranted'] == true
            : true;
        final requiresSettingsAction =
            response['requiresSettingsAction'] == true;
        if (microphoneGranted && cameraGranted) {
          return const IsometrikCallPermissionsResult(
            microphoneGranted: true,
            cameraGranted: true,
            requiresSettingsAction: false,
          );
        }
        final missing = <String>[
          if (!microphoneGranted) 'Microphone',
          if (!cameraGranted) 'Camera',
        ];
        final missingText = missing.join(' and ');
        return IsometrikCallPermissionsResult(
          microphoneGranted: microphoneGranted,
          cameraGranted: cameraGranted,
          requiresSettingsAction: requiresSettingsAction,
          message: requiresSettingsAction
              ? '$missingText permission is required. Please enable it from Settings.'
              : '$missingText permission is required to continue this call.',
        );
      } catch (e) {
        // Backward compatibility: if native Android side is older and does not
        // expose `requestRuntimePermissions`, fall back to permission_handler.
        if (_isNativeBridgeUnavailable(e)) {
          debugPrint(
            'IsometrikCallSdk: native Android permission bridge unavailable, '
            'falling back to permission_handler: $e',
          );
        } else {
          rethrow;
        }
      }
    }

    // iOS (and Android fallback): permission_handler runtime bridge.
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      final required = <Permission>[
        Permission.microphone,
        if (hasVideo) Permission.camera,
      ];
      final statuses = await required.request();
      final mic = statuses[Permission.microphone]?.isGranted ?? false;
      final cam = hasVideo
          ? (statuses[Permission.camera]?.isGranted ?? false)
          : true;
      final needsSettings = statuses.values.any(
        (s) => s.isPermanentlyDenied || s.isRestricted,
      );
      if (mic && cam) {
        return const IsometrikCallPermissionsResult(
          microphoneGranted: true,
          cameraGranted: true,
          requiresSettingsAction: false,
        );
      }
      final missing = <String>[if (!mic) 'Microphone', if (!cam) 'Camera'];
      final missingText = missing.join(' and ');
      return IsometrikCallPermissionsResult(
        microphoneGranted: mic,
        cameraGranted: cam,
        requiresSettingsAction: needsSettings,
        message: needsSettings
            ? '$missingText permission is required. Please enable it from Settings.'
            : '$missingText permission is required to continue this call.',
      );
    }

    return const IsometrikCallPermissionsResult(
      microphoneGranted: true,
      cameraGranted: true,
      requiresSettingsAction: false,
    );
  }

  Future<bool> openPermissionSettings() => openAppSettings();

  /// Direct REST access (same as Swift `ISMCallMeetingViewModel`).
  IsometrikMeetingRepository get meetings {
    final m = _meetings;
    if (m == null) {
      throw StateError('Call IsometrikCallSdk.initialize() first.');
    }
    return m;
  }

  /// Auth / user search (Swift `fetchUsers` + `authenticate`).
  IsometrikAuthRepository get auth {
    final a = _auth;
    if (a == null) {
      throw StateError('Call IsometrikCallSdk.initialize() first.');
    }
    return a;
  }

  /// Bootstrap configuration, HTTP clients, and native layer.
  ///
  /// [apiDebugLog] — optional sink for each HTTP request/response (truncated); use in examples or diagnostics.
  ///
  /// [apiDebugLogIncludeSecrets] — when true with [apiDebugLog], logs full `appSecret` / `userSecret` /
  /// `licenseKey`, `userToken`, and JSON bodies (passwords). **Never use in production.**
  Future<void> initialize(
    IsometrikCallConfiguration configuration, {
    IsometrikHttpDebugLog? apiDebugLog,
    bool apiDebugLogIncludeSecrets = false,
  }) async {
    session.configuration = configuration;
    session.deviceId ??= await IsometrikDeviceId.instance.resolve();

    _http = IsometrikHttpClient(
      baseUrl: configuration.apiBaseUrl,
      meetingHeaders: () => <String, String>{
        'appSecret': configuration.appSecret,
        'userToken': session.userToken ?? '',
        'licenseKey': configuration.licenseKey,
      },
      authHeaders: () => <String, String>{
        'appSecret': configuration.appSecret,
        'userSecret': configuration.userSecret,
        'licenseKey': configuration.licenseKey,
      },
      debugLog: apiDebugLog,
      debugLogFullSecrets: apiDebugLogIncludeSecrets,
    );
    _meetings = IsometrikMeetingRepository(_http!);
    _auth = IsometrikAuthRepository(_http!);

    await _invokeNativeBridgeIgnoringMissingPlugin(
      () => native.initialize(configuration),
      debugLabel: 'initialize',
    );
    _attachNativeListeners();
  }

  void _attachNativeListeners() {
    _nativeSub?.cancel();
    _nativeSub = native.events.listen((IsometrikNativeCallEvent e) async {
      if (e.type == 'voipTokenUpdated') {
        final token = e.payload['token'] as String?;
        if (token == null) {
          return;
        }
        pushKitTokenStore.newToken = token;
        if (session.hasSession && pushKitTokenStore.needToUpdate()) {
          final r = await meetings.updatePushRegistryApnsToken(
            addApnsDeviceToken: true,
            apnsDeviceToken: token,
          );
          switch (r) {
            case IsometrikSuccess():
              pushKitTokenStore.markSyncedFromNew();
            case IsometrikFailure():
              break;
          }
        }
      } else if (e.type == 'voipTokenInvalidated') {
        final last =
            pushKitTokenStore.lastSyncedToken ??
            pushKitTokenStore.newToken ??
            '';
        if (last.isNotEmpty) {
          await _meetings?.updatePushRegistryApnsToken(
            addApnsDeviceToken: false,
            apnsDeviceToken: last,
          );
        }
        pushKitTokenStore.clear();
      }
    });
  }

  /// Update logged-in user (mirrors Swift `updateUserId` / `updateUserToken`).
  Future<void> updateUserSession({
    required String userId,
    required String userToken,
  }) async {
    session.updateSession(userId: userId, userToken: userToken);
    meetingRouterContext.currentUserId = userId;
    await _invokeNativeBridgeIgnoringMissingPlugin(
      () => native.updateUserSession(userId: userId, userToken: userToken),
      debugLabel: 'updateUserSession',
    );
    if (pushKitTokenStore.needToUpdate() &&
        pushKitTokenStore.newToken != null) {
      final r = await meetings.updatePushRegistryApnsToken(
        addApnsDeviceToken: true,
        apnsDeviceToken: pushKitTokenStore.newToken!,
      );
      switch (r) {
        case IsometrikSuccess():
          pushKitTokenStore.markSyncedFromNew();
        case IsometrikFailure():
          break;
      }
    }
  }

  /// Swift `ISMMQTTManager.shared.connect(clientId:)` — `clientId` is the **user id**.
  Future<void> connectMqtt() async {
    final cfg = session.configuration;
    final uid = session.userId;
    final did = session.deviceId;
    if (cfg == null || uid == null || did == null) {
      throw StateError('Missing configuration, userId, or deviceId for MQTT.');
    }
    await mqtt.connect(configuration: cfg, userClientId: uid, deviceId: did);
  }

  Future<void> disconnectMqtt() => mqtt.disconnect();

  /// Wire [meetingRouter] to [mqtt.meetingEvents] (Swift `handleTheMeetingEvents` pipeline).
  void attachMeetingRouterToMqtt() {
    meetingRouter.bind(mqtt);
  }

  void detachMeetingRouter() {
    meetingRouter.unbind();
  }

  /// Register for VoIP pushes (iOS PushKit). No-op on unsupported platforms.
  Future<void> registerForVoipPushes() =>
      _invokeNativeBridgeIgnoringMissingPlugin(
        native.registerForVoipPushes,
        debugLabel: 'registerForVoipPushes',
      );

  /// Login — mirrors Example `ISMAuthViewModel.loginWith` + `/streaming/v2/user/authenticate`.
  Future<IsometrikResult<IsometrikAuthSession>> login({
    required String email,
    required String password,
  }) async {
    final r = await auth.authenticate(email: email, password: password);
    switch (r) {
      case IsometrikSuccess(:final data):
        await updateUserSession(userId: data.userId, userToken: data.userToken);
        return IsometrikSuccess(data);
      case IsometrikFailure(:final error):
        return IsometrikFailure(error);
    }
  }

  /// Full outgoing flow: `createMeeting` → CallKit outgoing → schedule no-answer hangup.
  /// Mirrors Swift `ISMCallManager.createCall(callUser:conversationId:callType:)`.
  Future<IsometrikResult<IsometrikMeeting>> createOutgoingCall({
    required String memberId,
    required IsometrikCallDisplayUser displayUser,
    String? conversationId,
    IsometrikLiveCallType callType = IsometrikLiveCallType.audioCall,
  }) async {
    final deviceId = session.deviceId;
    final cfg = session.configuration;
    if (deviceId == null || cfg == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    final permissions = await ensureCallPermissions(
      hasVideo: callType == IsometrikLiveCallType.videoCall,
    );
    if (!permissions.isGranted) {
      return IsometrikFailure(
        IsometrikServerMessageError(
          permissions.message ?? 'Required call permissions are missing.',
        ),
      );
    }
    final allowed = await native.canMakeOutgoingCall();
    if (!allowed) {
      return const IsometrikFailure(
        IsometrikServerMessageError('Already on another call.'),
      );
    }
    final body = IsometrikCreateMeetingRequest.forCallee(
      memberId: memberId,
      deviceId: deviceId,
      callType: callType,
      conversationId: conversationId,
    );
    final created = await meetings.createMeeting(body: body);
    switch (created) {
      case IsometrikFailure(:final error):
        return IsometrikFailure(error);
      case IsometrikSuccess(:final data):
        final rtc = data.rtcToken;
        final mid = data.meetingId;
        if (rtc == null || mid == null) {
          return const IsometrikFailure(IsometrikInvalidResponse());
        }
        await _startOutgoingCallSkippingSimulatorFailures(
          native,
          callee: displayUser,
          callId: mid,
          hasVideo: callType == IsometrikLiveCallType.videoCall,
          metadata: <String, dynamic>{'rtcToken': rtc, 'meetingId': mid},
        );
        // Swift `reportOutgoingCall` success: `callAnsweredByDeviceId = ISMDeviceId` so
        // multi-device MQTT (`joinRequestAccept` / `publishingStarted`) routes correctly.
        meetingRouterContext.callAnsweredByDeviceId = deviceId;
        await native.scheduleHangup(
          seconds: cfg.callHangupTimeOnNoAnswerSeconds,
        );
        meetingRouterContext.callDetailsMeetingId = mid;
        meetingRouterContext.outgoingCallPending = true;
        meetingRouterContext.nativeCallActive = true;
        return IsometrikSuccess(data);
    }
  }

  /// Creates a meeting with one or more members, then starts native CallKit (Swift `MeetingCreationViewController` + `startCall(with:callType:)`).
  Future<IsometrikResult<IsometrikMeeting>> createMeetingWithMembers({
    required List<String> memberIds,
    required String meetingDescription,
    IsometrikLiveCallType callType = IsometrikLiveCallType.videoCall,
    String? conversationId,
  }) async {
    final deviceId = session.deviceId;
    final cfg = session.configuration;
    if (deviceId == null || cfg == null || memberIds.isEmpty) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    final permissions = await ensureCallPermissions(
      hasVideo: callType == IsometrikLiveCallType.videoCall,
    );
    if (!permissions.isGranted) {
      return IsometrikFailure(
        IsometrikServerMessageError(
          permissions.message ?? 'Required call permissions are missing.',
        ),
      );
    }
    final allowed = await native.canMakeOutgoingCall();
    if (!allowed) {
      return const IsometrikFailure(
        IsometrikServerMessageError('Already on another call.'),
      );
    }
    final body = IsometrikCreateMeetingRequest(
      members: memberIds,
      deviceId: deviceId,
      customType: callType.apiValue,
      audioOnly: callType == IsometrikLiveCallType.audioCall,
      meetingDescription: meetingDescription.isEmpty
          ? 'NA'
          : meetingDescription,
      conversationId: conversationId,
    );
    final created = await meetings.createMeeting(body: body);
    switch (created) {
      case IsometrikFailure(:final error):
        return IsometrikFailure(error);
      case IsometrikSuccess(:final data):
        final rtc = data.rtcToken;
        final mid = data.meetingId;
        if (rtc == null || mid == null) {
          return const IsometrikFailure(IsometrikInvalidResponse());
        }
        final firstMember = data.members?.isNotEmpty == true
            ? data.members!.first
            : null;
        final displayName = firstMember?.memberName ?? 'Call';
        await _startOutgoingCallSkippingSimulatorFailures(
          native,
          callee: IsometrikCallDisplayUser(
            userId: firstMember?.memberId ?? mid,
            userName: displayName,
          ),
          callId: mid,
          hasVideo: callType != IsometrikLiveCallType.audioCall,
          metadata: <String, dynamic>{'rtcToken': rtc, 'meetingId': mid},
        );
        meetingRouterContext.callAnsweredByDeviceId = deviceId;
        await native.scheduleHangup(
          seconds: cfg.callHangupTimeOnNoAnswerSeconds,
        );
        meetingRouterContext.callDetailsMeetingId = mid;
        meetingRouterContext.outgoingCallPending = true;
        meetingRouterContext.nativeCallActive = true;
        return IsometrikSuccess(data);
    }
  }

  /// Join an existing meeting from the list (Swift `IsometrikCall.joinCall(meetingId:)`).
  Future<IsometrikResult<IsometrikMeeting>> joinMeeting({
    required String meetingId,
  }) async {
    final deviceId = session.deviceId;
    final cfg = session.configuration;
    if (deviceId == null || cfg == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    final permissions = await ensureCallPermissions(hasVideo: false);
    if (!permissions.isGranted) {
      return IsometrikFailure(
        IsometrikServerMessageError(
          permissions.message ?? 'Microphone permission is required.',
        ),
      );
    }
    final allowed = await native.canMakeOutgoingCall();
    if (!allowed) {
      return const IsometrikFailure(
        IsometrikServerMessageError('Already on another call.'),
      );
    }
    final accepted = await meetings.acceptCall(
      meetingId: meetingId,
      deviceId: deviceId,
    );
    switch (accepted) {
      case IsometrikFailure(:final error):
        return IsometrikFailure(error);
      case IsometrikSuccess(:final data):
        final rtc = data.rtcToken;
        final mid = data.meetingId ?? meetingId;
        if (rtc == null) {
          return const IsometrikFailure(IsometrikInvalidResponse());
        }
        final displayName = _resolvePeerName(
          primary: data,
          fallback: 'Meeting',
        );
        final hasVideo =
            _resolveCallType(primary: data) != IsometrikLiveCallType.audioCall;
        await _startOutgoingCallSkippingSimulatorFailures(
          native,
          callee: IsometrikCallDisplayUser(
            userId: data.initiatorIdentifier ?? mid,
            userName: displayName,
          ),
          callId: mid,
          hasVideo: hasVideo,
          metadata: <String, dynamic>{'rtcToken': rtc, 'meetingId': mid},
        );
        meetingRouterContext.callAnsweredByDeviceId = deviceId;
        await native.scheduleHangup(
          seconds: cfg.callHangupTimeOnNoAnswerSeconds,
        );
        meetingRouterContext.callDetailsMeetingId = mid;
        meetingRouterContext.outgoingCallPending = true;
        meetingRouterContext.nativeCallActive = true;
        return IsometrikSuccess(data);
    }
  }

  /// When callee accepts from CallKit / UI — mirrors `accpetCall`.
  Future<IsometrikResult<IsometrikMeeting>> acceptCall({
    required String meetingId,
  }) async {
    final deviceId = session.deviceId;
    if (deviceId == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    final r = await meetings.acceptCall(
      meetingId: meetingId,
      deviceId: deviceId,
    );
    switch (r) {
      case IsometrikSuccess():
        // Swift `CXAnswerCallAction`: `callAnsweredByDeviceId = ISMDeviceId`.
        meetingRouterContext.callAnsweredByDeviceId = deviceId;
      case IsometrikFailure():
        break;
    }
    return r;
  }

  /// Mirrors `rejectCall`.
  Future<IsometrikResult<IsometrikMeeting>> rejectCall({
    required String meetingId,
  }) async {
    final deviceId = session.deviceId;
    if (deviceId == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    return meetings.rejectCall(meetingId: meetingId, deviceId: deviceId);
  }

  /// Mirrors `startPublishing`.
  Future<IsometrikResult<IsometrikMeeting>> startPublishing({
    required String meetingId,
  }) async {
    final deviceId = session.deviceId;
    if (deviceId == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    return meetings.startPublishing(meetingId: meetingId, deviceId: deviceId);
  }

  /// Mirrors `publishMessage` with string body (use [IsometrikPublishMessage] raw values).
  Future<IsometrikResult<Null>> publishMeetingMessage({
    required String meetingId,
    required String messageBody,
  }) async {
    final deviceId = session.deviceId;
    if (deviceId == null) {
      return const IsometrikFailure(IsometrikInvalidResponse());
    }
    return meetings.publishMessage(
      meetingId: meetingId,
      deviceId: deviceId,
      messageBody: messageBody,
    );
  }

  /// Same REST bodies as Swift `ISMLiveCallView` + `ISMExpandableCallControlsViewDelegate` MQTT publish helpers.
  Future<IsometrikResult<Null>> publishVideoUpgradeRequest({
    required String meetingId,
  }) {
    return publishMeetingMessage(
      meetingId: meetingId,
      messageBody: IsometrikPublishMessage.requestToSwitchToVideoCall.rawValue,
    );
  }

  Future<IsometrikResult<Null>> publishVideoUpgradeAccepted({
    required String meetingId,
  }) {
    return publishMeetingMessage(
      meetingId: meetingId,
      messageBody:
          IsometrikPublishMessage.requestToSwitchToVideoCallAccepted.rawValue,
    );
  }

  Future<IsometrikResult<Null>> publishVideoUpgradeRejected({
    required String meetingId,
  }) {
    return publishMeetingMessage(
      meetingId: meetingId,
      messageBody:
          IsometrikPublishMessage.requestToSwitchToVideoCallRejected.rawValue,
    );
  }

  /// Report CallKit incoming UI from decoded PushKit / MQTT payload — mirrors `reportIncomingCall(callDetails:)`.
  Future<void> reportIncomingCallFromMeeting(IsometrikMeeting meeting) async {
    _pendingIncomingMeeting = meeting;
    meetingRouterContext.callDetailsMeetingId = meeting.meetingId;
    meetingRouterContext.nativeCallActive = true;
    await native.reportIncomingCall(
      callerName: _resolvePeerName(primary: meeting),
      callId: meeting.meetingId ?? '',
      hasVideo: meeting.callType != IsometrikLiveCallType.audioCall,
      metadata: meeting.toJson(),
    );
    final cfg = session.configuration;
    if (cfg != null) {
      await native.scheduleHangup(seconds: cfg.callHangupTimeOnNoAnswerSeconds);
    }
    // Swift: after incoming CallKit succeeds, `publishMessage(.callRingingMessage)`.
    final mid = meeting.meetingId;
    final did = session.deviceId;
    if (mid != null && did != null) {
      await meetings.publishMessage(
        meetingId: mid,
        deviceId: did,
        messageBody: IsometrikPublishMessage.callRinging.rawValue,
      );
    }
  }

  /// Decode VoIP push payload map (from [IsometrikNativeCallEvent] `incomingVoipPush`) to [IsometrikMeeting].
  static IsometrikMeeting? meetingFromVoipPayload(
    Map<String, dynamic> payload,
  ) {
    try {
      return IsometrikMeeting.fromJson(Map<String, dynamic>.from(payload));
    } catch (_) {
      return null;
    }
  }

  /// Mark outgoing as connected — mirrors `startTheCall()`.
  Future<void> markOutgoingConnected() async {
    meetingRouterContext.outgoingCallPending = false;
    await native.reportOutgoingCallConnected();
  }

  /// End native call + cancel hangup — mirrors `endCall` / disconnect.
  Future<void> endNativeCall() async {
    await native.cancelScheduledHangup();
    await native.endCurrentCall();
    meetingRouterContext.outgoingCallPending = false;
    meetingRouterContext.nativeCallActive = false;
    meetingRouterContext.callDetailsMeetingId = null;
    meetingRouterContext.uiMeetingId = null;
    meetingRouterContext.callAnsweredByDeviceId = null;
  }

  /// Logout: invalidate PushKit token on server, disconnect MQTT, clear session.
  Future<void> logout() async {
    detachMeetingRouter();
    meetingRouterContext.reset();
    await disconnectMqtt();
    final t = pushKitTokenStore.lastSyncedToken ?? pushKitTokenStore.newToken;
    if (t != null && t.isNotEmpty) {
      await _meetings?.updatePushRegistryApnsToken(
        addApnsDeviceToken: false,
        apnsDeviceToken: t,
      );
    }
    pushKitTokenStore.clear();
    session.clearSession();
    await _invokeNativeBridgeIgnoringMissingPlugin(
      native.unregisterVoipToken,
      debugLabel: 'unregisterVoipToken',
    );
  }

  // ---------------------------------------------------------------------------
  // Auto call handling — "batteries-included" mode
  // ---------------------------------------------------------------------------

  /// Enable automatic call handling: global MQTT → CallKit side effects,
  /// incoming call detection (PushKit + MQTT fallback), and auto-navigation.
  ///
  /// Mirrors Swift `ISMCallManager` + `MQTT+ISMCall.swift` global routing
  /// that the example app previously wired up manually.
  ///
  /// [onShowCallPage] is invoked when the SDK needs the call page displayed
  /// (e.g. incoming call accepted via CallKit). The callback receives a
  /// pre-configured [IsometrikCallController] to pass to [IsometrikCallPage].
  ///
  /// [triggerPermissionsOnIncomingAccept] controls whether SDK preflights
  /// microphone/camera permissions right after incoming call acceptance.
  ///
  /// Call after [attachMeetingRouterToMqtt].
  void enableAutoCallHandling({
    required void Function(IsometrikCallController controller) onShowCallPage,
    bool triggerPermissionsOnIncomingAccept = true,
  }) {
    _onShowCallPage = onShowCallPage;
    _triggerPermissionsOnIncomingAccept = triggerPermissionsOnIncomingAccept;

    _autoMqttSub?.cancel();
    _autoMqttSub = meetingRouter.events.listen(_handleAutoMqttEvent);

    _autoNativeSub?.cancel();
    _autoNativeSub = native.events.listen(_handleAutoNativeEvent);
  }

  /// Disable automatic call handling; host app resumes manual control.
  void disableAutoCallHandling() {
    _autoMqttSub?.cancel();
    _autoMqttSub = null;
    _autoNativeSub?.cancel();
    _autoNativeSub = null;
    _onShowCallPage = null;
  }

  Future<void> _handleAutoMqttEvent(IsometrikRoutedMeetingEvent e) async {
    switch (e) {
      case IsometrikRoutedMeetingEnded():
        debugPrint(
          'IsometrikCallSdk: auto-handler — meeting ended ${e.meeting.meetingId}',
        );
        await endNativeCall();
      case IsometrikRoutedMemberLeftOrRejected():
        final action = e.meeting.meetingAction;
        final shouldEnd =
            action == IsometrikMeetingAction.joinRequestReject ||
            _isLocalActorMeetingEvent(e.meeting);
        if (shouldEnd) {
          debugPrint(
            'IsometrikCallSdk: auto-handler — local leave/reject ${e.meeting.meetingId}',
          );
          await endNativeCall();
        } else {
          debugPrint(
            'IsometrikCallSdk: auto-handler — remote member left, keep call active ${e.meeting.meetingId}',
          );
        }
      case IsometrikRoutedRemotePublishingStarted():
        debugPrint(
          'IsometrikCallSdk: auto-handler — remote publishing, outgoing connected',
        );
        await markOutgoingConnected();
      case IsometrikRoutedLocalSessionSuperseded():
        debugPrint(
          'IsometrikCallSdk: auto-handler — answered on another device',
        );
        await endNativeCall();
      case IsometrikRoutedMeetingCreated():
        // When PushKit is disabled, acknowledge MQTT meetingCreated as
        // incoming call and register it with CallKit (mirrors Swift flow
        // where PushKit would normally trigger CallKit).
        if (session.configuration?.usePushKit == false) {
          final meeting = e.meeting;
          final createdBy = meeting.createdBy ?? meeting.userId;
          if (createdBy != null &&
              createdBy != meetingRouterContext.currentUserId) {
            debugPrint(
              'IsometrikCallSdk: auto-handler — MQTT incoming call '
              '(usePushKit=false) from $createdBy',
            );
            await reportIncomingCallFromMeeting(meeting);
          }
        }
      default:
        break;
    }
  }

  Future<void> _handleAutoNativeEvent(IsometrikNativeCallEvent e) async {
    if (e.type == 'incomingVoipPush') {
      final meeting = _meetingFromIncomingVoipNativeEvent(e);
      if (meeting != null) {
        debugPrint(
          'IsometrikCallSdk: auto-handler — incoming VoIP push for meeting ${meeting.meetingId}',
        );
        await reportIncomingCallFromMeeting(meeting);
      } else if (e.type == 'callAnswered') {
        // User accepted via CallKit — call accept API and show call page.
        final pending = _pendingIncomingMeeting;
        _pendingIncomingMeeting = null;

        final meetingId =
            pending?.meetingId ??
            (e.payload['meetingId'] as String?) ??
            meetingRouterContext.callDetailsMeetingId;
        if (meetingId == null) return;

        final r = await acceptCall(meetingId: meetingId);
        switch (r) {
          case IsometrikSuccess(:final data):
            final resolvedMeetingId =
                data.meetingId ?? pending?.meetingId ?? meetingId;
            final resolvedRtcToken = data.rtcToken ?? pending?.rtcToken;
            final resolvedCallType = _resolveCallType(
              primary: data,
              secondary: pending,
            );
            final controller = IsometrikCallController(
              sdk: this,
              meetingId: resolvedMeetingId,
              peerName: _resolvePeerName(primary: data, secondary: pending),
              isOutgoing: false,
              hasVideo: resolvedCallType != IsometrikLiveCallType.audioCall,
              rtcToken: resolvedRtcToken,
              peerImageUrl: pending?.initiatorImageUrl,
              initialStatus: IsometrikCallStatus.connecting,
              preflightPermissionsOnInit: _triggerPermissionsOnIncomingAccept,
            );
            _onShowCallPage?.call(controller);
          case IsometrikFailure(:final error):
            debugPrint(
              'IsometrikCallSdk: auto-handler — accept failed: $error',
            );
            await endNativeCall();
        }
      } else if (e.type == 'callEnded') {
        // CallKit ended — if the call was never accepted, reject via API.
        final meetingId = meetingRouterContext.callDetailsMeetingId;
        if (meetingId != null) {
          final wasAnswered =
              meetingRouterContext.callAnsweredByDeviceId != null;
          final wasOutgoing = meetingRouterContext.outgoingCallPending;
          if (wasAnswered || wasOutgoing) {
            try {
              await meetings.leaveMeeting(meetingId: meetingId);
            } catch (_) {}
          } else {
            try {
              await rejectCall(meetingId: meetingId);
            } catch (_) {}
          }
        }
        meetingRouterContext.nativeCallActive = false;
        meetingRouterContext.callDetailsMeetingId = null;
        meetingRouterContext.outgoingCallPending = false;
        meetingRouterContext.callAnsweredByDeviceId = null;
        _pendingIncomingMeeting = null;
      }
    }
  }

  IsometrikMeeting? _meetingFromIncomingVoipNativeEvent(
    IsometrikNativeCallEvent e,
  ) {
    final rawPayload = e.payload['payload'];
    if (rawPayload is Map) {
      return IsometrikCallSdk.meetingFromVoipPayload(
        Map<String, dynamic>.from(rawPayload),
      );
    }
    return IsometrikCallSdk.meetingFromVoipPayload(e.payload);
  }

  bool _isLocalActorMeetingEvent(IsometrikMeeting meeting) {
    final localUserId = meetingRouterContext.currentUserId;
    if (localUserId == null || localUserId.isEmpty) return false;
    final actor =
        meeting.userId ??
        meeting.senderId ??
        meeting.createdBy ??
        meeting.initiatorIdentifier;
    return actor != null && actor == localUserId;
  }

  // ---------------------------------------------------------------------------
  // Convenience: start outgoing call and get a ready-to-use controller
  // ---------------------------------------------------------------------------

  /// Create an outgoing call and return a ready-to-use [IsometrikCallController].
  ///
  /// The controller starts in [IsometrikCallStatus.calling] and transitions
  /// through ringing → connected as MQTT events arrive.
  ///
  /// Returns `null` if the call could not be created (already on a call,
  /// missing session, API failure). Show the result with [IsometrikCallPage]:
  /// ```dart
  /// final ctrl = await sdk.startCall(memberId: id, memberName: name);
  /// if (ctrl != null) IsometrikCallPage.show(context, controller: ctrl);
  /// ```
  ///
  /// [triggerPermissionsOnCallIntent] controls whether SDK preflights
  /// microphone/camera permissions immediately when controller is created.
  Future<IsometrikCallController?> startCall({
    required String memberId,
    required String memberName,
    String? memberImageUrl,
    IsometrikLiveCallType callType = IsometrikLiveCallType.audioCall,
    String? conversationId,
    bool triggerPermissionsOnCallIntent = true,
  }) async {
    final r = await createOutgoingCall(
      memberId: memberId,
      displayUser: IsometrikCallDisplayUser(
        userId: memberId,
        userName: memberName,
        avatarUrl: memberImageUrl,
      ),
      callType: callType,
      conversationId: conversationId,
    );
    switch (r) {
      case IsometrikSuccess(:final data):
        final mid = data.meetingId;
        if (mid == null) return null;
        return IsometrikCallController(
          sdk: this,
          meetingId: mid,
          peerName: memberName,
          isOutgoing: true,
          hasVideo: callType == IsometrikLiveCallType.videoCall,
          rtcToken: data.rtcToken,
          peerImageUrl: memberImageUrl,
          preflightPermissionsOnInit: triggerPermissionsOnCallIntent,
        );
      case IsometrikFailure(:final error):
        debugPrint('IsometrikCallSdk.startCall failed: $error');
        return null;
    }
  }

  Future<void> dispose() async {
    disableAutoCallHandling();
    await _nativeSub?.cancel();
    _meetingRouter?.dispose();
    _meetingRouter = null;
    await mqtt.dispose();
    _http?.close();
  }
}
