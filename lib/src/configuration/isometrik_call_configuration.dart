/// Configuration used to bootstrap the calling SDK (mirrors Swift `ISMCallConfiguration` fields).
class IsometrikCallConfiguration {
  const IsometrikCallConfiguration({
    required this.accountId,
    required this.projectId,
    required this.keysetId,
    required this.licenseKey,
    required this.appSecret,
    required this.userSecret,
    this.usePushKit = true,
    this.apiBaseUrl = 'https://apis.isometrik.io',
    this.mqttHost = 'connections.isometrik.io',
    this.mqttPort = 2052,
    this.callHangupTimeOnNoAnswerSeconds = 60,
    this.streamingUrl = 'wss://streaming.isometrik.io',
    this.videoCallOption = true,
    this.androidIncomingRingtoneUri,
    this.blurIncomingUi = false,
  });

  final String accountId;
  final String projectId;
  final String keysetId;
  final String licenseKey;
  final String appSecret;
  final String userSecret;
  final bool usePushKit;

  /// REST base (Swift hard-coded `https://apis.isometrik.io`).
  final String apiBaseUrl;

  /// MQTT broker host (Swift `ISMCallConfiguration.MQTTHost`).
  final String mqttHost;

  /// MQTT port (Swift `ISMCallConfiguration.MQTTPort`).
  final int mqttPort;

  /// No-answer timeout (Swift `callHangupTimeOnNoAnswer`).
  final double callHangupTimeOnNoAnswerSeconds;

  /// LiveKit / streaming URL for documentation and host apps.
  final String streamingUrl;

  final bool videoCallOption;

  final bool blurIncomingUi;

  /// Optional custom ringtone URI for Android incoming calls.
  ///
  /// Example values:
  /// - `content://media/internal/audio/media/105`
  /// - `android.resource://com.example.app/raw/incoming_call`
  ///
  /// If null/empty/invalid, SDK falls back to device default ringtone.
  final String? androidIncomingRingtoneUri;

  Map<String, dynamic> toNativeMap() {
    return <String, dynamic>{
      'accountId': accountId,
      'projectId': projectId,
      'keysetId': keysetId,
      'licenseKey': licenseKey,
      'appSecret': appSecret,
      'userSecret': userSecret,
      'usePushKit': usePushKit,
      'apiBaseUrl': apiBaseUrl,
      'mqttHost': mqttHost,
      'mqttPort': mqttPort,
      'callHangupTimeOnNoAnswerSeconds': callHangupTimeOnNoAnswerSeconds,
      'streamingUrl': streamingUrl,
      'videoCallOption': videoCallOption,
      'androidIncomingRingtoneUri': androidIncomingRingtoneUri,
      'blurIncomingUi': blurIncomingUi,
    };
  }
}
