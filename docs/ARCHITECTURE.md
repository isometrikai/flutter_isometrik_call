# Isometrik Flutter Call — architecture

This package mirrors the iOS `LiveKitCall` / `ISMSwiftCall` layering. Use this document when extending APIs so new code stays consistent.

## Layers

| Layer | Dart location | Responsibility |
|-------|----------------|----------------|
| **Configuration** | `lib/src/configuration/` | Static keys, URLs, MQTT host/port (Swift `ISMCallConfiguration`). |
| **Domain models** | `lib/src/models/` | Codable REST/MQTT payloads (`ISMMeeting`, `ISMCallMember`, enums). |
| **API (HTTP)** | `lib/src/api/` | `IsometrikHttpClient`, endpoints, `IsometrikResult` / errors (Swift `ISMCallAPIManager`). |
| **Repositories** | `lib/src/repositories/` | One class per remote area: meetings, auth (Swift `ISMCallMeetingViewModel`). |
| **Services** | `lib/src/services/` | Device id, session, PushKit token store, MQTT client (Swift `ISMMQTTManager`). |
| **SDK facade** | `lib/src/sdk/isometrik_call_sdk.dart` | Orchestrates REST + MQTT + native bridge + token sync (app entry point). |
| **Meeting router** | `lib/src/router/isometrik_meeting_router.dart` | MQTT → typed events (Swift `MQTT+ISMCall.handleTheMeetingEvents`). |
| **Native bridge** | `lib/src/platform/isometrik_flutter_call_facade.dart` | CallKit / PushKit only (Swift `ISMCallManager` UI-adjacent parts). |
| **LiveKit helper** | `lib/src/livekit_session_manager.dart` | Room connect/disconnect (Swift `ISMLiveCallView` LiveKit portion). |

## Meeting router

- **`IsometrikMeetingRouterContext`** — host app mirrors Swift globals (`callDetails`, `outgoingCallID`, `meetingId` on UI, etc.).
- **`IsometrikMeetingRouter.route(IsometrikMeeting)`** — pure logic for tests.
- **`bind(IsometrikMqttService)`** — subscribe to `meetingEvents` and push to **`events`** stream.
- **`IsometrikCallSdk.attachMeetingRouterToMqtt()`** — one-line wiring after `connectMqtt()`.

See **[INTEGRATION.md](../INTEGRATION.md)** for field-by-field setup.

## What stays in the host app (Flutter UI)

- **In-call UI** (video tiles, controls): Swift `ISMLiveCallView` / `ISMCallControlsView` → build with Flutter + `livekit_client` using `IsometrikLiveKitSessionManager`.
- **Complex MQTT side-effects** (e.g. multi-device “answered elsewhere”): Swift `MQTT+ISMCall.swift` — listen to `IsometrikMqttService.meetingEvents` and apply your product rules.

## iOS native (`ios/Classes/`)

Implements CallKit + PushKit parity with `ISMCallManager`:

- VoIP token lifecycle → forwarded to Dart (`voipTokenUpdated` / `voipTokenInvalidated`).
- Outgoing/incoming call UI (`CXStartCallAction`, `reportNewIncomingCall`).
- No-answer hangup (`scheduleHangup` / `cancelScheduledHangup`).
- `canMakeOutgoingCall` via `CXCallObserver`.

## Android

REST + MQTT work on Android. CallKit/PushKit are iOS-only; the plugin returns no-op / permissive defaults for native call methods so the same Dart API runs everywhere.

## Extension points

- **Custom `apiBaseUrl`**: `IsometrikCallConfiguration.apiBaseUrl`.
- **Testing**: inject a mock `http.Client` by extending `IsometrikHttpClient` (add optional `httpClient` param if needed) or mock repositories.
- **Platform interface**: swap `IsometrikFlutterCallPlatform.instance` in tests (`plugin_platform_interface` pattern).
