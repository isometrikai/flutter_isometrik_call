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

If you use `permission_handler` (the SDK does), also enable iOS permission
handlers in `ios/Podfile` `post_install`:

```ruby
target.build_configurations.each do |config|
  config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
    '$(inherited)',
    'PERMISSION_CAMERA=1',
    'PERMISSION_MICROPHONE=1',
  ]
end
```

Then run `flutter clean && flutter pub get && cd ios && pod install`.

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

### 6.1 Background / terminated / locked device (watchdog safety)

If incoming VoIP works in the foreground but you see `EXC_CRASH (SIGKILL)` with **`Termination Reason: FRONTBOARD 0xBAADCA11`** on a cold launch, that is typically iOS killing the process for **watchdog / lifecycle deadlines**, not a Dart exception.

**Native guarantees (PushKit)**

- Every VoIP push schedules handling on the **main queue** (CallKit requirement), even if the delegate callback arrives off the main thread.
- PushKit’s **`completion` handler is invoked exactly once** per push: normally right after CallKit’s `reportNewIncomingCall` completion; if that callback never runs (should be rare), an emergency fallback fires after several seconds so iOS never waits indefinitely.
- **`completion` is never delayed behind Flutter** — the plugin calls PushKit completion before sending `incomingVoipPush` on the EventChannel (cold start can delay the channel; that must not block PushKit).
- **Missing payload fields** still produce a valid CallKit report: display name falls back to `"Incoming Call"`; if no `callId` / `call_id` / `meetingId` is present, a **new UUID** is used so reporting always completes.

**Host app expectations**

- Call `initialize`, then `updateUserSession`, then `registerForVoipPushes()` as early as your product allows after login (same order as this doc).
- Avoid blocking the main thread during app startup when a VoIP push can wake the app (heavy sync I/O, large JSON parsing on the main isolate, etc.).
- In **Xcode → Devices**, inspect console lines prefixed with **`[ISMCall]`**: `VoIP push handling …`, `reportNewIncomingCall finished …`, `VoIP PushKit completion() after …s`. If you see **`VoIP PushKit completion FALLBACK`**, CallKit did not finish within the safety window — investigate CallKit errors or main-thread contention.

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
