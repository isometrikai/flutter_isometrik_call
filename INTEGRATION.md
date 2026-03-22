# Integrating `isometrik_flutter_call`

Step-by-step guide to add this package to a Flutter app and wire calling, MQTT, and (on iOS) CallKit / PushKit.

---

## 1. Add the dependency

### From pub.dev (when published)

```yaml
# pubspec.yaml
dependencies:
  isometrik_flutter_call: ^0.0.1
```

### From a path (monorepo / local checkout)

```yaml
dependencies:
  isometrik_flutter_call:
    path: ../isometrik_flutter_call
```

Then:

```bash
flutter pub get
```

---

## 2. iOS capabilities (VoIP / CallKit)

In **Xcode** → your **Runner** target → **Signing & Capabilities**:

1. **+ Capability** → **Push Notifications**
2. **+ Capability** → **Background Modes** → enable:
   - **Voice over IP**
   - **Remote notifications**

Add **Privacy** strings in `ios/Runner/Info.plist` as needed, for example:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Needed for voice and video calls</string>
<key>NSCameraUsageDescription</key>
<string>Needed for video calls</string>
```

> **Note:** Android does not use CallKit/PushKit. REST + MQTT work; native call UI is your responsibility (e.g. ConnectionService) if you need system-level calls.

---

## 3. Minimal Dart bootstrap

Create a single long-lived **`IsometrikCallSdk`** instance (e.g. register in `GetIt`, `Provider`, or a top-level `app_sdk.dart`).

```dart
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';

final IsometrikCallSdk callSdk = IsometrikCallSdk();

Future<void> initCallingSdk() async {
  await callSdk.initialize(
    const IsometrikCallConfiguration(
      accountId: 'YOUR_ACCOUNT_ID',
      projectId: 'YOUR_PROJECT_ID',
      keysetId: 'YOUR_KEYSET_ID',
      licenseKey: 'YOUR_LICENSE_KEY',
      appSecret: 'YOUR_APP_SECRET',
      userSecret: 'YOUR_USER_SECRET',
    ),
  );
}
```

After your user logs in and you have **user id** + **user token** (same as Swift `UserDefaults` / `IsometrikCall`):

```dart
await callSdk.updateUserSession(
  userId: userId,
  userToken: userToken,
);

await callSdk.registerForVoipPushes(); // iOS PushKit; safe no-op elsewhere
await callSdk.connectMqtt();
```

---

## 4. Meeting router (MQTT → typed events)

This mirrors Swift **`MQTT+ISMCall.swift`**: raw MQTT JSON becomes **`IsometrikRoutedMeetingEvent`** instances so your UI can react without re-implementing the `switch`.

### 4.1 Attach the router

After MQTT is connected:

```dart
callSdk.attachMeetingRouterToMqtt();

callSdk.meetingRouter.events.listen((event) async {
  switch (event) {
    case IsometrikRoutedMeetingCreated(:final meeting):
      // Swift: callDetails = meeting
      break;
    case IsometrikRoutedMeetingEnded(:final meeting):
      // Disconnect LiveKit UI + end native call
      await callSdk.endNativeCall();
      break;
    case IsometrikRoutedMemberLeftOrRejected():
      await callSdk.endNativeCall();
      break;
    case IsometrikRoutedRemotePublishingStarted():
      await callSdk.markOutgoingConnected();
      break;
    case IsometrikRoutedLocalSessionSuperseded():
      await callSdk.endNativeCall();
      break;
    case IsometrikRoutedCallRinging():
      // Update UI: ringing
      break;
    case IsometrikRoutedVideoUpgradeRequest(:final meeting):
      // Show “upgrade to video?” dialog
      break;
    case IsometrikRoutedVideoUpgradeRejected():
    case IsometrikRoutedVideoUpgradeAccepted():
      break;
    case IsometrikRoutedIgnored(:final reason):
      // Optional: debug log — `reason`
      break;
  }
});
```

> Use `unawaited(...)` from `dart:async` if your linter forbids unawaited futures on `listen`.

### 4.2 Keep `meetingRouterContext` in sync

The router compares MQTT payloads to **your** current call state. Update these from your in-call screen (see also **`IsometrikMeetingRouterContext`** dartdoc):

| Field | When to set | Swift analogue |
|--------|-------------|----------------|
| `currentUserId` | After login | Set automatically by `updateUserSession` on the SDK |
| `uiMeetingId` | When call UI opens for a meeting | `ISMLiveCallView.shared.meetingId` |
| `callDetailsMeetingId` | Often set by SDK on outgoing/incoming; override if needed | `callDetails?.meetingId` |
| `outgoingCallPending` | Set `true` during outgoing ring; SDK sets after `createOutgoingCall` | `outgoingCallID != nil` |
| `nativeCallActive` | `true` while CallKit considers you in a call | Active `callIDs` |
| `callAnsweredByDeviceId` | Your device id when **this** device answers | `callAnsweredByDeviceId` |

Example when your call page opens:

```dart
callSdk.meetingRouterContext.uiMeetingId = activeMeetingId;
```

When this device answers (use the same stable id you use server-side, e.g. from `device_info_plus` / your own id):

```dart
callSdk.meetingRouterContext.callAnsweredByDeviceId = myDeviceIdString;
```

On teardown:

```dart
callSdk.endNativeCall(); // also clears most router fields via SDK
```

### 4.3 Detach on logout / dispose

```dart
callSdk.detachMeetingRouter();
// or full logout:
await callSdk.logout();
```

---

## 5. REST + outgoing call (full flow)

```dart
final result = await callSdk.createOutgoingCall(
  memberId: remoteMemberId,
  displayUser: IsometrikCallDisplayUser(
    userId: remoteMemberId,
    userName: remoteDisplayName,
  ),
  callType: IsometrikLiveCallType.videoCall,
);

switch (result) {
  case IsometrikSuccess(:final data):
    final token = data.rtcToken!;
    final url = callSdk.configuration!.streamingUrl;
    // Connect LiveKit with IsometrikLiveKitSessionManager
    break;
  case IsometrikFailure(:final error):
    break;
}
```

---

## 6. VoIP push → incoming call

Listen to native events:

```dart
callSdk.native.events.listen((e) {
  if (e.type == 'incomingVoipPush') {
    final raw = e.payload['payload'];
    if (raw is Map) {
      final meeting = IsometrikCallSdk.meetingFromVoipPayload(
        Map<String, dynamic>.from(raw),
      );
      if (meeting != null) {
        unawaited(callSdk.reportIncomingCallFromMeeting(meeting));
      }
    }
  }
});
```

---

## 7. Login API (optional)

```dart
final auth = await callSdk.login(email: email, password: password);
```

---

## 8. Checklist

- [ ] `initialize` + `updateUserSession` before REST/MQTT that need user token  
- [ ] iOS capabilities + plist usage strings  
- [ ] `registerForVoipPushes` on iOS  
- [ ] `connectMqtt` after session ready  
- [ ] `attachMeetingRouterToMqtt` + listen to `meetingRouter.events`  
- [ ] Set `uiMeetingId` / `callAnsweredByDeviceId` from your call UI  
- [ ] `logout` or `detachMeetingRouter` when signing out  

For layer details, see **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.
