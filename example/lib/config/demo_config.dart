import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';

// -----------------------------------------------------------------------------
// Demo credentials for the Flutter example app — loaded from `example/.env`.
// Aligned with Swift [LiveKitCall/ISMCallConfiguration/ISMCallConfiguration.swift] statics.
//
// Reuse / moderation:
// - **Git:** add real values only in `.env` (gitignored). Commit `.env.example` with
//   placeholders so clones know which keys to set.
// - **Runtime:** [loadDemoEnv] must run in [main] before [runApp]. Widget tests use
//   [ExampleAppController.forWidgetTest] and never touch these getters.
// - **Release builds:** `.env` is still packaged as a Flutter asset, so values ship in
//   the binary. For production, inject config at build time (e.g. `--dart-define`) or
//   a secure backend instead of committing or embedding long-lived secrets.
//
// These values feed:
// - REST `meetingHeaders`: appSecret, userToken (after login), licenseKey
// - REST `authHeaders`:    appSecret, userSecret, licenseKey
// - MQTT: accountId, projectId, licenseKey + keysetId (see [IsometrikMqttService])
// - Native plugin: full map via [IsometrikCallConfiguration.toNativeMap]
// -----------------------------------------------------------------------------

/// Loads `example/.env` into [dotenv]. Call once from [main] after
/// `WidgetsFlutterBinding.ensureInitialized()`.
Future<void> loadDemoEnv() async {
  await dotenv.load(fileName: '.env');
}

String _requireEnv(String name) {
  final v = dotenv.env[name]?.trim();
  if (v == null || v.isEmpty) {
    throw StateError(
      'Missing environment variable "$name". '
      'Copy example/.env.example to example/.env and set all required keys.',
    );
  }
  return v;
}

String _optionalEnv(String name, String fallback) {
  final v = dotenv.env[name]?.trim();
  if (v == null || v.isEmpty) {
    return fallback;
  }
  return v;
}

bool _envBool(String name, {required bool fallback}) {
  final raw = dotenv.env[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) {
    return fallback;
  }
  return raw == 'true' || raw == '1' || raw == 'yes';
}

/// `accountId`
String get kDemoAccountId => _requireEnv('ISOMETRIK_ACCOUNT_ID');

/// `projectId`
String get kDemoProjectId => _requireEnv('ISOMETRIK_PROJECT_ID');

/// `keysetId`
String get kDemoKeysetId => _requireEnv('ISOMETRIK_KEYSET_ID');

/// `licenseKey` — sent on every API call with app / user secrets.
String get kDemoLicenseKey => _requireEnv('ISOMETRIK_LICENSE_KEY');

/// `appSecret` — meeting + auth REST headers (`ISMLKMeetingEndPoints` / `ISMLKAuthEndpoints`).
String get kDemoAppSecret => _requireEnv('ISOMETRIK_APP_SECRET');

/// `userSecret` — auth-only REST (login, `fetchUsers`, etc.).
String get kDemoUserSecret => _requireEnv('ISOMETRIK_USER_SECRET');

/// Environment URLs — override in `.env` or keep defaults (same as [IsometrikCallConfiguration] / Swift).
String get kDemoApiBaseUrl =>
    _optionalEnv('ISOMETRIK_API_BASE_URL', 'https://apis.isometrik.io');

String get kDemoMqttHost =>
    _optionalEnv('ISOMETRIK_MQTT_HOST', 'connections.isometrik.io');

int get kDemoMqttPort {
  final raw = dotenv.env['ISOMETRIK_MQTT_PORT']?.trim();
  if (raw == null || raw.isEmpty) {
    return 2052;
  }
  return int.tryParse(raw) ?? 2052;
}

String get kDemoStreamingUrl =>
    _optionalEnv('ISOMETRIK_STREAMING_URL', 'wss://streaming.isometrik.io');

/// When **true**, HTTP debug logs include full secrets and tokens. Prefer **false**
/// for release; default **false** when the key is omitted in `.env`.
bool get kDemoHttpLogFullSecrets =>
    _envBool('DEMO_HTTP_LOG_FULL_SECRETS', fallback: false);

/// Full SDK bootstrap used by [ExampleAppController] (`usesPushKit: false` matches Swift Example).
IsometrikCallConfiguration get kDemoIsometrikCallConfiguration =>
    IsometrikCallConfiguration(
      accountId: kDemoAccountId,
      projectId: kDemoProjectId,
      keysetId: kDemoKeysetId,
      licenseKey: kDemoLicenseKey,
      appSecret: kDemoAppSecret,
      userSecret: kDemoUserSecret,
      usePushKit: true,
      apiBaseUrl: kDemoApiBaseUrl,
      mqttHost: kDemoMqttHost,
      mqttPort: kDemoMqttPort,
      callHangupTimeOnNoAnswerSeconds: 60,
      streamingUrl: kDemoStreamingUrl,
      videoCallOption: true,
    );
