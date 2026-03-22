/// Public API for the Isometrik Flutter calling package.
///
/// **Architecture (recommended usage):**
/// - [IsometrikCallSdk] — single entry: REST + MQTT + native CallKit/PushKit orchestration.
/// - [IsometrikMeetingRepository] / [IsometrikAuthRepository] — direct API access if needed.
/// - [IsometrikFlutterCall] — native bridge only (CallKit / PushKit).
library;

export 'src/api/isometrik_api_error.dart';
export 'src/api/isometrik_http_client.dart' show IsometrikHttpDebugLog;
export 'src/configuration/isometrik_call_configuration.dart';
export 'src/models/models.dart';
export 'src/platform/isometrik_flutter_call_facade.dart';
export 'src/repositories/auth_repository.dart';
export 'src/repositories/meeting_repository.dart';
export 'src/router/isometrik_meeting_router.dart';
export 'src/sdk/isometrik_call_sdk.dart';
export 'src/services/isometrik_device_id.dart';
export 'src/services/isometrik_mqtt_service.dart';
export 'src/services/isometrik_pushkit_token_store.dart';
export 'src/services/isometrik_session_state.dart';
export 'src/livekit_session_manager.dart';
export 'src/ui/isometrik_call_controller.dart';
export 'src/ui/isometrik_call_page.dart';
