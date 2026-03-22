import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';

/// High-level app state: mirrors Swift flow (Login → MyMeetings → create/join → live UI).
///
/// Reuses a single [IsometrikCallSdk]; session is persisted like Swift `UserDefaults`.
/// The SDK's [enableAutoCallHandling] replaces the old manual MQTT routing — it
/// handles CallKit side effects, incoming call detection, and auto-navigation.
enum AuthGate { bootstrapping, loggedOut, loggedIn }

class ExampleAppController extends ChangeNotifier {
  ExampleAppController({this.navigatorKey}) {
    _bootstrap();
  }

  /// Skips async SDK/bootstrap for widget tests (no platform plugins).
  ///
  /// Reuse: `example/test/widget_test.dart` pumps [IsometrikExampleApp] without
  /// waiting on native [IsometrikCallSdk.initialize]. Do not use for production.
  @visibleForTesting
  ExampleAppController.forWidgetTest() : navigatorKey = null {
    gate = AuthGate.loggedOut;
    sdkReady = true;
  }

  /// Navigator key for auto-pushing the call page on incoming calls.
  final GlobalKey<NavigatorState>? navigatorKey;

  static const _kUserId = 'example_user_id';
  static const _kUserToken = 'example_user_token';
  static const _kEmail = 'example_email';

  final IsometrikCallSdk sdk = IsometrikCallSdk();

  /// Last HTTP lines from [IsometrikHttpClient] (request + response, truncated).
  final List<String> apiLogBuffer = <String>[];

  AuthGate gate = AuthGate.bootstrapping;
  bool sdkReady = false;

  /// After login / restore — mirrors Swift `user` + `UserDefaults`.
  IsometrikAuthSession? authSession;
  String? signedInEmail;

  bool loginBusy = false;

  void _logApi(String line) {
    debugPrint('[Isometrik HTTP] $line');
    final stamp = DateTime.now().toIso8601String();
    apiLogBuffer.insert(0, '[$stamp] $line');
    const max = 400;
    while (apiLogBuffer.length > max) {
      apiLogBuffer.removeLast();
    }
    notifyListeners();
  }

  void clearApiLogs() {
    apiLogBuffer.clear();
    notifyListeners();
  }

  /// Settings / manual tests — same buffer as HTTP [apiDebugLog].
  void appendExampleLog(String line) => _logApi('(manual) $line');

  /// [SharedPreferences] can throw [PlatformException] (channel-error) on iOS when
  /// the implicit Flutter engine has not finished registering plugins yet — see
  /// [AppDelegate] early [GeneratedPluginRegistrant.register]. Retries give the
  /// bridge time to connect; reuse this helper anywhere you touch prefs in the example.
  Future<SharedPreferences?> _sharedPreferencesWithRetry() async {
    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 50),
      Duration(milliseconds: 200),
    ];
    for (var i = 0; i < delays.length; i++) {
      if (i > 0) {
        await Future<void>.delayed(delays[i]);
      }
      try {
        return await SharedPreferences.getInstance();
      } catch (e, st) {
        final bool isChannel =
            e is PlatformException && e.code == 'channel-error';
        _logApi(
          'SharedPreferences attempt ${i + 1}/${delays.length}: $e'
          '${isChannel ? ' (waiting for native plugins)' : ''}',
        );
        if (i == delays.length - 1) {
          _logApi('SharedPreferences unavailable after retries: $e\n$st');
        }
      }
    }
    return null;
  }

  Future<void> _persistSessionToDisk({
    required String userId,
    required String userToken,
    required String email,
  }) async {
    try {
      final prefs = await _sharedPreferencesWithRetry();
      if (prefs == null) {
        return;
      }
      await prefs.setString(_kUserId, userId);
      await prefs.setString(_kUserToken, userToken);
      await prefs.setString(_kEmail, email);
    } catch (e, st) {
      _logApi('Persist session failed (session still active in memory): $e\n$st');
    }
  }

  Future<void> _ensureSdkInitialized() async {
    if (sdkReady) {
      return;
    }
    await sdk.initialize(
      kDemoIsometrikCallConfiguration,
      apiDebugLog: _logApi,
      apiDebugLogIncludeSecrets: kDemoHttpLogFullSecrets,
    );
    sdkReady = true;
  }

  Future<void> _bootstrap() async {
    gate = AuthGate.bootstrapping;
    notifyListeners();
    try {
      await _ensureSdkInitialized();
      final prefs = await _sharedPreferencesWithRetry();
      if (prefs == null) {
        gate = AuthGate.loggedOut;
        notifyListeners();
        return;
      }
      final uid = prefs.getString(_kUserId);
      final token = prefs.getString(_kUserToken);
      signedInEmail = prefs.getString(_kEmail);
      if (uid != null &&
          token != null &&
          uid.isNotEmpty &&
          token.isNotEmpty) {
        await sdk.updateUserSession(userId: uid, userToken: token);
        authSession = IsometrikAuthSession(
          userToken: token,
          userId: uid,
          msg: '',
        );
        await _afterAuthConnected();
        gate = AuthGate.loggedIn;
      } else {
        gate = AuthGate.loggedOut;
      }
    } catch (e, st) {
      _logApi('Bootstrap error: $e\n$st');
      gate = AuthGate.loggedOut;
    }
    notifyListeners();
  }

  /// VoIP + MQTT after REST login (or restored session).
  ///
  /// Uses [IsometrikCallSdk.enableAutoCallHandling] which replaces the old
  /// manual MQTT routing. The SDK now automatically handles:
  ///   • meetingEnded / memberLeft → end CallKit
  ///   • remotePublishingStarted → mark outgoing connected
  ///   • localSessionSuperseded → end CallKit
  ///   • meetingCreated (usePushKit=false) → report incoming via CallKit
  ///   • callAnswered → accept API + show call page
  ///   • callEnded (rejected) → reject API
  Future<void> _afterAuthConnected() async {
    await sdk.registerForVoipPushes();
    try {
      await sdk.connectMqtt();
      _logApi('MQTT connected=${sdk.mqtt.hasConnected}');
    } catch (e) {
      _logApi('MQTT connect failed: $e');
    }
    sdk.attachMeetingRouterToMqtt();

    // Enable SDK's auto call handling — replaces manual MQTT → CallKit wiring.
    // The callback pushes the SDK's built-in call page when an incoming call
    // is accepted (via CallKit or MQTT).
    sdk.enableAutoCallHandling(
      onShowCallPage: (IsometrikCallController controller) {
        final nav = navigatorKey?.currentState;
        if (nav == null) {
          _logApi('Cannot show call page: no navigator available');
          return;
        }
        nav.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => IsometrikCallPage(
              controller: controller,
              config: const IsometrikCallPageConfig(showMeetingIdDebug: true),
            ),
          ),
        );
      },
    );
  }

  /// Email/password — same as Swift `ISMAuthViewModel.loginWith`.
  Future<String?> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    loginBusy = true;
    notifyListeners();
    try {
      await _ensureSdkInitialized();
      final r = await sdk.login(email: email, password: password);
      switch (r) {
        case IsometrikSuccess(:final data):
          authSession = data;
          signedInEmail = email;
          await _afterAuthConnected();
          gate = AuthGate.loggedIn;
          notifyListeners();
          // Persist after navigation so a prefs race does not block the logged-in UI.
          await _persistSessionToDisk(
            userId: data.userId,
            userToken: data.userToken,
            email: email,
          );
          return null;
        case IsometrikFailure(:final error):
          return error.toString();
      }
    } catch (e) {
      return e.toString();
    } finally {
      loginBusy = false;
      notifyListeners();
    }
  }

  /// Swift logout + clear `UserDefaults` (`MyMeetingsViewController.profileButtonTapped`).
  Future<void> signOut() async {
    sdk.disableAutoCallHandling();
    await sdk.logout();
    try {
      final prefs = await _sharedPreferencesWithRetry();
      if (prefs != null) {
        await prefs.remove(_kUserId);
        await prefs.remove(_kUserToken);
        await prefs.remove(_kEmail);
      }
    } catch (e, st) {
      _logApi('Clearing SharedPreferences on sign-out failed: $e\n$st');
    }
    authSession = null;
    signedInEmail = null;
    gate = AuthGate.loggedOut;
    notifyListeners();
  }

  Future<List<IsometrikMeeting>> loadMeetings() async {
    final r = await sdk.meetings.getMeetings();
    switch (r) {
      case IsometrikSuccess(:final data):
        return data;
      case IsometrikFailure(:final error):
        _logApi('getMeetings failed: $error');
        throw Exception(error.toString());
    }
  }

  Future<void> leaveMeeting(String meetingId) async {
    final r = await sdk.meetings.leaveMeeting(meetingId: meetingId);
    switch (r) {
      case IsometrikSuccess():
        _logApi('leaveMeeting ok $meetingId');
      case IsometrikFailure(:final error):
        _logApi('leaveMeeting failed: $error');
        throw Exception(error.toString());
    }
  }

  Future<IsometrikMeeting?> joinMeetingAndStartNative(String meetingId) async {
    final r = await sdk.joinMeeting(meetingId: meetingId);
    switch (r) {
      case IsometrikSuccess(:final data):
        return data;
      case IsometrikFailure(:final error):
        _logApi('joinMeeting failed: $error');
        return null;
    }
  }

  /// Swift `ISMCallMeetingViewModel.fetchUsers(searchTag:)`.
  Future<List<IsometrikDirectoryUser>> searchUsers(String searchTag) async {
    final r = await sdk.auth.fetchUsers(searchTag: searchTag);
    switch (r) {
      case IsometrikSuccess(:final data):
        return data;
      case IsometrikFailure(:final error):
        _logApi('fetchUsers failed: $error');
        return <IsometrikDirectoryUser>[];
    }
  }

  Future<IsometrikMeeting?> createMeetingWithMembers({
    required List<String> memberIds,
    required String meetingTitle,
    required IsometrikLiveCallType callType,
  }) async {
    final r = await sdk.createMeetingWithMembers(
      memberIds: memberIds,
      meetingDescription: meetingTitle,
      callType: callType,
    );
    switch (r) {
      case IsometrikSuccess(:final data):
        return data;
      case IsometrikFailure(:final error):
        _logApi('createMeetingWithMembers failed: $error');
        return null;
    }
  }

  @override
  void dispose() {
    unawaited(sdk.dispose());
    super.dispose();
  }
}
