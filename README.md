# isometrik_flutter_call

Production-style Flutter calling SDK aligned with the iOS `LiveKitCall` / `ISMSwiftCall` modules:

| Concern | Swift reference | Dart |
|--------|-----------------|------|
| Config | `ISMCallConfiguration` | `IsometrikCallConfiguration` |
| REST meetings | `ISMCallMeetingViewModel` | `IsometrikMeetingRepository` |
| Auth / search | `authenticate`, `fetchUsers` | `IsometrikAuthRepository` |
| MQTT | `ISMMQTTManager` | `IsometrikMqttService` |
| CallKit / PushKit | `ISMCallManager` | `IsometrikFlutterCall` (native) |
| Facade | `IsometrikCall` app wiring | **`IsometrikCallSdk`** |

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for layer diagram and extension points.

**Integration steps for host apps:** **[INTEGRATION.md](INTEGRATION.md)**.

## Features

- **REST** — same endpoints and headers as Swift (`https://apis.isometrik.io`).
- **MQTT** — same broker credentials and topics as `ISMMQTTManager`.
- **PushKit token sync** — mirrors `ISMPushKitToken` + `updatePushRegisteryApnsToken`.
- **iOS CallKit** — outgoing/incoming, mute, speaker, no-answer hangup, `canMakeOutgoingCall`.
- **LiveKit** — `IsometrikLiveKitSessionManager` for room connect (UI stays in your app).

## Recommended usage (`IsometrikCallSdk`)

```dart
final sdk = IsometrikCallSdk();

await sdk.initialize(const IsometrikCallConfiguration(
  accountId: '…',
  projectId: '…',
  keysetId: '…',
  licenseKey: '…',
  appSecret: '…',
  userSecret: '…',
));

// After login (or use sdk.login(email:, password:))
await sdk.updateUserSession(userId: userId, userToken: userToken);
await sdk.registerForVoipPushes();
await sdk.connectMqtt();

// REST
final meetings = await sdk.meetings.getMeetings();

// Full outgoing (createMeeting + CallKit + hangup timer) — mirrors Swift `createCall`
await sdk.createOutgoingCall(
  memberId: calleeMemberId,
  displayUser: IsometrikCallDisplayUser(userId: calleeMemberId, userName: 'Jane'),
  callType: IsometrikLiveCallType.videoCall,
);

// Native-only (testing)
await sdk.native.reportIncomingCall(callerName: 'Bob', callId: 'id', hasVideo: false);

sdk.native.events.listen((e) {
  // voipTokenUpdated, callAnswered, callEnded, …
});

// MQTT payloads (same JSON as Swift `ISMMeeting`)
sdk.mqtt.meetingEvents.listen((meeting) {
  // handle IsometrikMeetingAction like Swift `handleTheMeetingEvents`
});
```

## Direct repository access (advanced)

Use when you do not want the facade:

```dart
final client = IsometrikHttpClient(
  baseUrl: 'https://apis.isometrik.io',
  meetingHeaders: () => { 'appSecret': '…', 'userToken': token, 'licenseKey': '…' },
  authHeaders: () => { 'appSecret': '…', 'userSecret': '…', 'licenseKey': '…' },
);
final repo = IsometrikMeetingRepository(client);
```

## iOS host app setup

- Capabilities: **Push Notifications**, **Background Modes** (VoIP, Remote notifications).
- `Info.plist`: microphone / camera usage strings for video calls.

## LiveKit

```dart
final session = IsometrikLiveKitSessionManager();
await session.connect(url: 'wss://…', token: rtcToken);
await session.disconnect();
```

## Example

```bash
cd example && flutter run
```

## pub.dev checklist

- Fill `repository`, `issue_tracker`, and real `homepage` in `pubspec.yaml`.
- Add changelog and API docs for each release.
