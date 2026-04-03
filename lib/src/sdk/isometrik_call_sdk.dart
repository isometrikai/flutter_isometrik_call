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

  /// Prevent duplicate incoming UI when multiple triggers arrive (push + MQTT
  /// meetingCreated). Only one incoming UI should be shown at a time.
  bool _isIncomingCallShown = false;

  /// Stable meeting/call id for the currently shown incoming UI.
  String? _incomingCallId;

  /// Prevent duplicate incoming call UI when both PushKit and MQTT arrive.
  final Set<String> _reportedIncomingMeetingIds = <String>{};

  /// Idempotency: if native emits `callAnswered` multiple times for the same
  /// incoming call, ignore subsequent duplicates.
  String? _lastIncomingCallAnsweredMeetingId;

  /// Idempotency: if native emits `callEnded` multiple times for the same
  /// call, ignore subsequent duplicates.
  String? _lastIncomingCallEndedMeetingId;

  /// Meeting ended by server/MQTT; when native `callEnded` follows this
  /// signal we must skip leave/reject API to avoid 400 "already ended".
  String? _lastServerEndedMeetingId;

  /// Snapshot of previous active call when a waiting incoming call is shown.
  bool _hasCallWaitingSnapshot = false;
  String? _callWaitingPreviousMeetingId;
  String? _callWaitingPreviousUiMeetingId;
  String? _callWaitingPreviousAnsweredDeviceId;
  String? _waitingCallAcceptInProgressMeetingId;
  DateTime? _waitingCallAcceptStartedAt;

  /// Best-effort guard for caller-side loopback pushes/MQTT that can arrive
  /// before outgoing state is fully propagated.
  String? _lastLocalOutgoingMeetingId;
  DateTime? _lastLocalOutgoingAt;

  /// Idempotency guards for terminal REST actions so UI end + native end event
  /// cannot issue duplicate leave/reject requests for the same meeting.
  final Set<String> _leaveInFlightMeetingIds = <String>{};
  final Set<String> _rejectInFlightMeetingIds = <String>{};

  /// Diagnostic: whether an incoming call UI is currently shown.
  bool get isIncomingCallShown => _isIncomingCallShown;

  IsometrikCallConfiguration? get configuration => session.configuration;

  void _markLocalOutgoingMeeting(String meetingId) {
    _lastLocalOutgoingMeetingId = meetingId;
    _lastLocalOutgoingAt = DateTime.now();
  }

  bool _isLikelyLocalOutgoingLoopback(String meetingId) {
    final lastMid = _lastLocalOutgoingMeetingId;
    final at = _lastLocalOutgoingAt;
    if (lastMid == null || at == null) return false;
    if (lastMid != meetingId) return false;
    // Outgoing loopback events typically arrive right after call creation.
    return DateTime.now().difference(at) <= const Duration(seconds: 25);
  }

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

  bool _isGroupCall({
    IsometrikMeeting? primary,
    IsometrikMeeting? secondary,
  }) {
    return _resolveCallType(
          primary: primary,
          secondary: secondary,
        ) ==
        IsometrikLiveCallType.groupCall;
  }

  String _resolveIncomingCallerName({
    required IsometrikMeeting meeting,
  }) {
    final baseName = _resolvePeerName(primary: meeting, fallback: 'Unknown');
    if (_isGroupCall(primary: meeting)) {
      if (baseName.isNotEmpty && baseName != 'Unknown') {
        return '$baseName (Group)';
      }
      return 'Group call';
    }
    return baseName;
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
        // Set outgoing context before native call start to avoid races where
        // incoming loopback events arrive while state is still unset.
        _markLocalOutgoingMeeting(mid);
        meetingRouterContext.callDetailsMeetingId = mid;
        meetingRouterContext.outgoingCallPending = true;
        meetingRouterContext.nativeCallActive = true;
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
        _markLocalOutgoingMeeting(mid);
        meetingRouterContext.callDetailsMeetingId = mid;
        meetingRouterContext.outgoingCallPending = true;
        meetingRouterContext.nativeCallActive = true;
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

  /// Idempotent wrapper for `leaveMeeting` to avoid duplicate terminal calls.
  Future<void> leaveMeetingOnce(String meetingId) async {
    final normalized = meetingId.trim();
    if (normalized.isEmpty) return;
    if (_leaveInFlightMeetingIds.contains(normalized)) return;
    _leaveInFlightMeetingIds.add(normalized);
    try {
      await meetings.leaveMeeting(meetingId: normalized);
    } finally {
      _leaveInFlightMeetingIds.remove(normalized);
    }
  }

  /// Idempotent wrapper for `rejectCall` to avoid duplicate terminal calls.
  Future<void> rejectCallOnce(String meetingId) async {
    final normalized = meetingId.trim();
    if (normalized.isEmpty) return;
    if (_rejectInFlightMeetingIds.contains(normalized)) return;
    _rejectInFlightMeetingIds.add(normalized);
    try {
      await rejectCall(meetingId: normalized);
    } finally {
      _rejectInFlightMeetingIds.remove(normalized);
    }
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
    final mid = meeting.meetingId?.trim();
    if (mid == null || mid.isEmpty) {
      debugPrint(
        'IsometrikCallSdk: reportIncomingCallFromMeeting skipped: missing meetingId. '
        'payload=${meeting.toJson()}',
      );
      return;
    }

    if (_isLikelyLocalOutgoingLoopback(mid)) {
      debugPrint(
        'IsometrikCallSdk: ignoring likely local outgoing loopback for mid=$mid',
      );
      return;
    }

    // Ignore self-originated incoming payloads (can happen when push/socket
    // fan-out includes local actor). Without this, caller side may show
    // CallKit "End & Accept" for its own outgoing call.
    final localUserId = meetingRouterContext.currentUserId?.trim();
    final meetingActor = (meeting.createdBy ??
            meeting.userId ??
            meeting.initiatorIdentifier ??
            meeting.senderId)
        ?.trim();
    if (localUserId != null &&
        localUserId.isNotEmpty &&
        meetingActor != null &&
        meetingActor.isNotEmpty &&
        meetingActor == localUserId) {
      debugPrint(
        'IsometrikCallSdk: ignoring self-originated incoming for mid=$mid actor=$meetingActor',
      );
      return;
    }

    // If another call is already active and this is a different meeting, keep
    // a snapshot so we can support call waiting:
    // - accept new -> leave previous call
    // - decline new -> continue previous call.
    final activeMid = meetingRouterContext.callDetailsMeetingId?.trim();
    // During outgoing dialing/connecting phase, ignore incoming only when it
    // is for the same meeting id (loopback). This prevents caller-side
    // CallKit "End & Accept" while still allowing true call-waiting for a
    // different meeting.
    if (meetingRouterContext.outgoingCallPending &&
        activeMid != null &&
        activeMid == mid) {
      debugPrint(
        'IsometrikCallSdk: ignoring incoming loopback while outgoing pending '
        '(mid=$mid)',
      );
      return;
    }

    // Ignore duplicate incoming for the same already-active meeting.
    if (meetingRouterContext.nativeCallActive &&
        activeMid != null &&
        activeMid == mid) {
      debugPrint(
        'IsometrikCallSdk: ignoring duplicate incoming for active mid=$mid',
      );
      return;
    }

    if (meetingRouterContext.nativeCallActive &&
        activeMid != null &&
        activeMid != mid) {
      _captureCallWaitingSnapshotIfNeeded(activeMid);
    }

    // Enforce single incoming UI across duplicates ( PushKit + MQTT meetingCreated).
    if (_isIncomingCallShown) {
      if (_incomingCallId == mid) {
        // Same call: keep pending meeting updated, but don't re-report UI.
        _pendingIncomingMeeting = meeting;
        meetingRouterContext.callDetailsMeetingId = mid;
      }
      return;
    }

    if (_reportedIncomingMeetingIds.contains(mid)) {
      debugPrint(
        'IsometrikCallSdk: reportIncomingCallFromMeeting skipped duplicate mid=$mid',
      );
      return;
    }

    _reportedIncomingMeetingIds.add(mid);
    _isIncomingCallShown = true;
    _incomingCallId = mid;
    _lastIncomingCallAnsweredMeetingId = null;
    _lastIncomingCallEndedMeetingId = null;
    _pendingIncomingMeeting = meeting;
    meetingRouterContext.callDetailsMeetingId = mid;
    meetingRouterContext.outgoingCallPending = false;
    meetingRouterContext.nativeCallActive = true;
    meetingRouterContext.callAnsweredByDeviceId = null;
    try {
      await native.reportIncomingCall(
        callerName: _resolveIncomingCallerName(meeting: meeting),
        callId: mid,
        hasVideo: meeting.callType != IsometrikLiveCallType.audioCall,
        metadata: <String, dynamic>{
          ...meeting.toJson(),
          'isGroupCall': _isGroupCall(primary: meeting),
        },
      );
      final cfg = session.configuration;
      if (cfg != null) {
        await native.scheduleHangup(
          seconds: cfg.callHangupTimeOnNoAnswerSeconds,
        );
      }
      // Swift: after incoming CallKit succeeds, `publishMessage(.callRingingMessage)`.
      final did = session.deviceId;
      if (did != null) {
        await meetings.publishMessage(
          meetingId: mid,
          deviceId: did,
          messageBody: IsometrikPublishMessage.callRinging.rawValue,
        );
      }
    } catch (e) {
      debugPrint(
        'IsometrikCallSdk: reportIncomingCallFromMeeting failed mid=$mid error=$e',
      );
      _reportedIncomingMeetingIds.remove(mid);
      _isIncomingCallShown = false;
      _incomingCallId = null;
      _pendingIncomingMeeting = null;
      meetingRouterContext.nativeCallActive = false;
      meetingRouterContext.callDetailsMeetingId = null;
      rethrow;
    }
  }

  /// Decode VoIP push payload map (from [IsometrikNativeCallEvent] `incomingVoipPush`) to [IsometrikMeeting].
  static IsometrikMeeting? meetingFromVoipPayload(
    Map<String, dynamic> payload,
  ) {
    try {
      return IsometrikMeeting.fromJson(Map<String, dynamic>.from(payload));
    } catch (e) {
      debugPrint(
        'IsometrikCallSdk: meetingFromVoipPayload parse failed: $e. '
        'keys=${payload.keys.toList()}',
      );
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
    final currentMid = meetingRouterContext.callDetailsMeetingId;
    await native.cancelScheduledHangup();
    await native.endCurrentCall();
    _resetRuntimeCallState(meetingId: currentMid);
  }

  void _resetRuntimeCallState({
    String? meetingId,
    bool clearAllReportedIncomingIds = false,
  }) {
    meetingRouterContext.outgoingCallPending = false;
    meetingRouterContext.nativeCallActive = false;
    meetingRouterContext.callDetailsMeetingId = null;
    meetingRouterContext.uiMeetingId = null;
    meetingRouterContext.callAnsweredByDeviceId = null;

    _isIncomingCallShown = false;
    _incomingCallId = null;
    _pendingIncomingMeeting = null;
    _lastIncomingCallAnsweredMeetingId = null;
    _lastIncomingCallEndedMeetingId = null;
    _lastServerEndedMeetingId = null;
    _clearCallWaitingSnapshot();
    _waitingCallAcceptInProgressMeetingId = null;
    _waitingCallAcceptStartedAt = null;
    _lastLocalOutgoingMeetingId = null;
    _lastLocalOutgoingAt = null;
    _leaveInFlightMeetingIds.clear();
    _rejectInFlightMeetingIds.clear();

    if (clearAllReportedIncomingIds) {
      _reportedIncomingMeetingIds.clear();
      return;
    }
    final normalized = meetingId?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      _reportedIncomingMeetingIds.remove(normalized);
    }
  }

  void _captureCallWaitingSnapshotIfNeeded(String previousMeetingId) {
    if (_hasCallWaitingSnapshot) return;
    _hasCallWaitingSnapshot = true;
    _callWaitingPreviousMeetingId = previousMeetingId;
    _callWaitingPreviousUiMeetingId = meetingRouterContext.uiMeetingId;
    _callWaitingPreviousAnsweredDeviceId =
        meetingRouterContext.callAnsweredByDeviceId;
  }

  void _clearCallWaitingSnapshot() {
    _hasCallWaitingSnapshot = false;
    _callWaitingPreviousMeetingId = null;
    _callWaitingPreviousUiMeetingId = null;
    _callWaitingPreviousAnsweredDeviceId = null;
  }

  void _scheduleWaitingAcceptGuardCleanup(String acceptedMeetingId) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 16), () {
        final waitingMid = _waitingCallAcceptInProgressMeetingId?.trim();
        final startedAt = _waitingCallAcceptStartedAt;
        if (waitingMid == null || waitingMid.isEmpty) return;
        if (waitingMid != acceptedMeetingId) return;
        if (startedAt == null) return;
        // Keep protection window for iOS End&Accept races, then always clear
        // to avoid stale waiting-call state when publish events are filtered.
        if (DateTime.now().difference(startedAt) >= const Duration(seconds: 12)) {
          _clearCallWaitingSnapshot();
          _waitingCallAcceptInProgressMeetingId = null;
          _waitingCallAcceptStartedAt = null;
        }
      }),
    );
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
        final endedMid = e.meeting.meetingId?.trim();
        final waitingPreviousMid = _callWaitingPreviousMeetingId?.trim();
        final waitingAcceptMid = _waitingCallAcceptInProgressMeetingId?.trim();
        final waitingTransitionActive = waitingPreviousMid != null &&
            waitingPreviousMid.isNotEmpty &&
            waitingAcceptMid != null &&
            waitingAcceptMid.isNotEmpty;
        if (waitingTransitionActive &&
            (endedMid == null ||
                endedMid.isEmpty ||
                endedMid == waitingPreviousMid)) {
          // During iOS End&Accept, MQTT for previous call can arrive after new
          // call is accepted. Ignore ambiguous/previous end signals so they
          // never tear down the newly accepted call.
          return;
        }
        debugPrint(
          'IsometrikCallSdk: auto-handler — meeting ended ${e.meeting.meetingId}',
        );
        _lastServerEndedMeetingId = e.meeting.meetingId?.trim();
        await endNativeCall();
      case IsometrikRoutedMemberLeftOrRejected():
        final leftMid = e.meeting.meetingId?.trim();
        final waitingPreviousMid = _callWaitingPreviousMeetingId?.trim();
        final waitingAcceptMid = _waitingCallAcceptInProgressMeetingId?.trim();
        final waitingTransitionActive = waitingPreviousMid != null &&
            waitingPreviousMid.isNotEmpty &&
            waitingAcceptMid != null &&
            waitingAcceptMid.isNotEmpty;
        if (waitingTransitionActive &&
            (leftMid == null ||
                leftMid.isEmpty ||
                leftMid == waitingPreviousMid)) {
          // Same guard as meetingEnded: ignore previous-call leave/reject while
          // waiting-call accept is transitioning, including ambiguous events
          // that omit a meeting id.
          return;
        }
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
        // iOS End&Accept: once media is flowing for the newly accepted call,
        // we can safely clear waiting-transition guards.
        final publishingMid = e.meeting.meetingId?.trim();
        final waitingAcceptMid = _waitingCallAcceptInProgressMeetingId?.trim();
        if (waitingAcceptMid != null &&
            waitingAcceptMid.isNotEmpty &&
            publishingMid == waitingAcceptMid) {
          _clearCallWaitingSnapshot();
          _waitingCallAcceptInProgressMeetingId = null;
          _waitingCallAcceptStartedAt = null;
        }
        await markOutgoingConnected();
      case IsometrikRoutedLocalSessionSuperseded():
        debugPrint(
          'IsometrikCallSdk: auto-handler — answered on another device',
        );
        await endNativeCall();
      case IsometrikRoutedMeetingCreated():
        final meeting = e.meeting;
        final mid = meeting.meetingId?.trim();
        if (mid == null || mid.isEmpty) return;

        final usePushForIncoming =
            defaultTargetPlatform == TargetPlatform.iOS &&
            (session.configuration?.usePushKit ?? false);
        if (usePushForIncoming) {
          // PushKit/FCM is the only trigger for incoming UI.
          // MQTT can only refresh pending details for the already-shown call.
          if (_isIncomingCallShown && _incomingCallId == mid) {
            _pendingIncomingMeeting = meeting;
            meetingRouterContext.callDetailsMeetingId = mid;
          }
          return;
        }

        // Non-Push mode: MQTT is the incoming-call UI trigger (documented).
        // If UI is already shown (e.g. app manually reported), only refresh
        // pending details for the same call id.
        if (_isIncomingCallShown) {
          if (_incomingCallId == mid) {
            _pendingIncomingMeeting = meeting;
            meetingRouterContext.callDetailsMeetingId = mid;
          }
          return;
        }

        final createdBy = meeting.createdBy ??
            meeting.userId ??
            meeting.initiatorIdentifier ??
            meeting.senderId;
        if (createdBy != null &&
            createdBy == meetingRouterContext.currentUserId) {
          return;
        }
        await reportIncomingCallFromMeeting(meeting);
      default:
        break;
    }
  }

  Future<void> _handleAutoNativeEvent(IsometrikNativeCallEvent e) async {
    if (e.type == 'incomingVoipPush') {
      final meeting = _meetingFromIncomingVoipNativeEvent(e);
      if (meeting != null) {
        await reportIncomingCallFromMeeting(meeting);
      }
    } else if (e.type == 'providerReset') {
      try {
        await native.cancelScheduledHangup();
      } catch (_) {}
      // CallKit provider reset can happen without a usable call id payload.
      // Clear all runtime incoming ids to avoid stale dedupe/resource state.
      _resetRuntimeCallState(clearAllReportedIncomingIds: true);
    } else if (e.type == 'callAnswered') {
      // User accepted via CallKit — call accept API and show call page.
      final pending = _pendingIncomingMeeting;
      _pendingIncomingMeeting = null;

      // Freeze expected incoming call id so duplicate/stale events don't
      // misroute the accept API to the wrong meeting.
      final expectedIncomingId = _incomingCallId;
      // Incoming UI is no longer "ringing shown" once user has answered.
      // Keeping this true blocks future waiting-call incoming UI.
      _isIncomingCallShown = false;
      _incomingCallId = null;

      String? asString(dynamic v) {
        if (v == null) return null;
        if (v is String) return v;
        return v.toString();
      }

      // iOS native sends `callAnswered` payload as:
      //   { "callId": <activeCallId> }
      // so we must read `callId` (not `meetingId`).
      final meetingId = expectedIncomingId ??
          asString(e.payload['callId'])?.trim() ??
          pending?.meetingId?.trim() ??
          meetingRouterContext.callDetailsMeetingId?.trim();
      if (meetingId == null || meetingId.isEmpty) return;

      if (expectedIncomingId != null && meetingId != expectedIncomingId) {
        debugPrint(
          'IsometrikCallSdk: ignoring stale callAnswered for mid=$meetingId '
          '(expected $expectedIncomingId)',
        );
        return;
      }

      // Idempotency: ignore duplicate accept actions for the same call.
      if (_lastIncomingCallAnsweredMeetingId != null &&
          _lastIncomingCallAnsweredMeetingId == meetingId) {
        return;
      }

      _lastIncomingCallAnsweredMeetingId = meetingId;
      if (_hasCallWaitingSnapshot) {
        _waitingCallAcceptInProgressMeetingId = meetingId;
        _waitingCallAcceptStartedAt = DateTime.now();
      }

      // Mark answered immediately to avoid `callEnded` arriving while the
      // REST accept API is still in-flight (race can otherwise trigger a
      // reject instead of leave).
      final deviceId = session.deviceId;
      if (deviceId != null) {
        meetingRouterContext.callAnsweredByDeviceId = deviceId;
      }
      await native.cancelScheduledHangup();

      final r = await acceptCall(meetingId: meetingId);
      switch (r) {
        case IsometrikSuccess(:final data):
          // Call waiting accept: end/leave previous call so new one becomes
          // the single active session.
          if (_hasCallWaitingSnapshot) {
            final previousMid = _callWaitingPreviousMeetingId?.trim();
            if (previousMid != null &&
                previousMid.isNotEmpty &&
                previousMid != meetingId) {
              try {
                await leaveMeetingOnce(previousMid);
              } catch (_) {}
            }
          }

          final resolvedMeetingId = data.meetingId?.trim() ?? meetingId;
          // Ensure router context points to the accepted waiting call.
          meetingRouterContext.callDetailsMeetingId = resolvedMeetingId;
          meetingRouterContext.nativeCallActive = true;
          meetingRouterContext.outgoingCallPending = false;
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
          // Keep waiting-call transition markers until old-call `callEnded`
          // is consumed; otherwise a late ambiguous `callEnded` can tear down
          // the newly accepted call.
          _waitingCallAcceptInProgressMeetingId = resolvedMeetingId;
          _scheduleWaitingAcceptGuardCleanup(resolvedMeetingId);
        case IsometrikFailure(:final error):
          debugPrint('IsometrikCallSdk: auto-handler — accept failed: $error');
          _waitingCallAcceptInProgressMeetingId = null;
          _waitingCallAcceptStartedAt = null;
          await endNativeCall();
      }
    } else if (e.type == 'callEnded') {
      // CallKit ended — if the call was never accepted, reject via API.
      String? asString(dynamic v) {
        if (v == null) return null;
        if (v is String) return v;
        return v.toString();
      }

      // iOS native sends `callEnded` as:
      //   { "callId": <activeCallId> }
      // Prefer context, but fall back to payload to avoid race conditions.
      final contextMeetingId = meetingRouterContext.callDetailsMeetingId?.trim();
      final payloadMeetingId = asString(e.payload['callId'])?.trim();

      // iOS "End & Accept" race:
      // Old-call end can arrive with missing/ambiguous callId while context
      // already points to the new incoming call. In that case, never treat this
      // as the new incoming call ending; just end previous snapshot call.
      final waitingPreviousMid = _callWaitingPreviousMeetingId?.trim();
      final incomingMid = _incomingCallId?.trim();
      if (_hasCallWaitingSnapshot &&
          waitingPreviousMid != null &&
          waitingPreviousMid.isNotEmpty &&
          (payloadMeetingId == null || payloadMeetingId.isEmpty) &&
          incomingMid != null &&
          incomingMid.isNotEmpty &&
          contextMeetingId == incomingMid) {
        try {
          await leaveMeetingOnce(waitingPreviousMid);
        } catch (_) {}
        _clearCallWaitingSnapshot();
        _waitingCallAcceptInProgressMeetingId = null;
        _waitingCallAcceptStartedAt = null;
        return;
      }

      if (contextMeetingId != null &&
          payloadMeetingId != null &&
          payloadMeetingId != contextMeetingId) {
        debugPrint(
          'IsometrikCallSdk: ignoring stale callEnded for mid=$payloadMeetingId '
          '(expected $contextMeetingId)',
        );
        return;
      }

      final normalizedMeetingId = contextMeetingId ?? payloadMeetingId;
      final waitingAcceptMid = _waitingCallAcceptInProgressMeetingId?.trim();
      final waitingTransitionActive = _hasCallWaitingSnapshot &&
          waitingAcceptMid != null &&
          waitingAcceptMid.isNotEmpty &&
          waitingPreviousMid != null &&
          waitingPreviousMid.isNotEmpty;
      final waitingAcceptAt = _waitingCallAcceptStartedAt;
      final waitingAcceptWindowActive = waitingAcceptAt != null &&
          DateTime.now().difference(waitingAcceptAt) <=
              const Duration(seconds: 12);
      if (waitingTransitionActive &&
          normalizedMeetingId == waitingPreviousMid) {
        // iOS End & Accept emits callEnded for previous call first. Do not
        // reset runtime state here, otherwise new accepted call setup is lost.
        try {
          await leaveMeetingOnce(waitingPreviousMid);
        } catch (_) {}
        // Keep transition guards until new call media starts (or timeout
        // fallback guards below), because iOS can emit another delayed old-call
        // `callEnded` with missing/ambiguous callId.
        return;
      }
      if (waitingTransitionActive &&
          waitingAcceptWindowActive &&
          normalizedMeetingId == waitingAcceptMid &&
          (payloadMeetingId == null ||
              payloadMeetingId.isEmpty ||
              payloadMeetingId == waitingAcceptMid ||
              payloadMeetingId == waitingPreviousMid)) {
        // During iOS End&Accept transition, old-call end may arrive without a
        // reliable callId while context already points to the newly accepted
        // meeting. Ignore this ambiguous event to avoid ending the new call.
        return;
      }
      final expectedIncomingMid = _incomingCallId?.trim();
      final isDeclinedWaitingCall = _hasCallWaitingSnapshot &&
          normalizedMeetingId != null &&
          expectedIncomingMid != null &&
          normalizedMeetingId == expectedIncomingMid;
      final endedByServer = normalizedMeetingId != null &&
          normalizedMeetingId.isNotEmpty &&
          _lastServerEndedMeetingId == normalizedMeetingId;
      if (normalizedMeetingId != null && normalizedMeetingId.isNotEmpty) {
        // Idempotency: ignore duplicate end actions for the same call.
        final isDuplicateEnd =
            _lastIncomingCallEndedMeetingId == normalizedMeetingId;
        _lastIncomingCallEndedMeetingId = normalizedMeetingId;

        // Always reset SDK state (even on duplicates) so the next incoming call
        // can be processed cleanly. Only skip REST side-effects for dupes.
        if (!isDuplicateEnd && !endedByServer) {
          final wasAnswered =
              meetingRouterContext.callAnsweredByDeviceId != null;
          final wasOutgoing = meetingRouterContext.outgoingCallPending;
          if (wasAnswered || wasOutgoing) {
            try {
              await leaveMeetingOnce(normalizedMeetingId);
            } catch (_) {}
          } else {
            try {
              await rejectCallOnce(normalizedMeetingId);
            } catch (_) {}
          }
        }
      }
      if (isDeclinedWaitingCall) {
        final previousMid = _callWaitingPreviousMeetingId?.trim();
        final previousUiMid = _callWaitingPreviousUiMeetingId?.trim();
        final previousAnsweredBy = _callWaitingPreviousAnsweredDeviceId;

        _isIncomingCallShown = false;
        _incomingCallId = null;
        _pendingIncomingMeeting = null;
        if (normalizedMeetingId.isNotEmpty) {
          _reportedIncomingMeetingIds.remove(normalizedMeetingId);
        }

        // Keep previous ongoing call alive after declining waiting call.
        meetingRouterContext.nativeCallActive =
            previousMid != null && previousMid.isNotEmpty;
        meetingRouterContext.callDetailsMeetingId = previousMid;
        meetingRouterContext.uiMeetingId = previousUiMid;
        meetingRouterContext.callAnsweredByDeviceId = previousAnsweredBy;
        meetingRouterContext.outgoingCallPending = false;
        _clearCallWaitingSnapshot();
        return;
      }
      _resetRuntimeCallState(
        meetingId: normalizedMeetingId,
        clearAllReportedIncomingIds:
            normalizedMeetingId == null || normalizedMeetingId.isEmpty,
      );
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
    debugPrint(
      'IsometrikCallSdk: incomingVoipPush unexpected payload shape: '
      'rawPayloadType=${rawPayload.runtimeType}',
    );
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
