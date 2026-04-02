import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../configuration/isometrik_call_configuration.dart';
import '../models/models.dart';

/// Mirrors Swift `ISMMQTTManager` + `handleTheMeetingEvents` decoding.
class IsometrikMqttService {
  IsometrikMqttService();

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  String _userClientId = '';
  IsometrikCallConfiguration? _config;
  final StreamController<IsometrikMeeting> _meetingController =
      StreamController<IsometrikMeeting>.broadcast();

  /// Decoded meeting events from MQTT payload (same JSON as Swift `ISMMeeting`).
  Stream<IsometrikMeeting> get meetingEvents => _meetingController.stream;

  bool hasConnected = false;

  /// Swift: `connect(clientId:)` uses `clientId + deviceId` as MQTT client id.
  Future<void> connect({
    required IsometrikCallConfiguration configuration,
    required String userClientId,
    required String deviceId,
  }) async {
    await disconnect();
    _config = configuration;
    _userClientId = userClientId;
    // final fullClientId = '$userClientId$deviceId';
    final fullClientId = '$userClientId{CALL}$deviceId';
    final username = '2${configuration.accountId}${configuration.projectId}';
    final password = '${configuration.licenseKey}${configuration.keysetId}';

    final client = MqttServerClient.withPort(
      configuration.mqttHost,
      fullClientId,
      configuration.mqttPort,
    );
    client.logging(on: false);
    client.keepAlivePeriod = 60;
    client.autoReconnect = true;

    _client = client;

    final status = await client.connect(username, password);
    if (status?.state != MqttConnectionState.connected) {
      hasConnected = false;
      throw StateError('MQTT connect failed: ${status?.state}');
    }

    final messageTopic =
        '/${configuration.accountId}/${configuration.projectId}/Message/$userClientId';
    final statusTopic =
        '/${configuration.accountId}/${configuration.projectId}/Status/$userClientId';
    client.subscribe(messageTopic, MqttQos.atMostOnce);
    client.subscribe(statusTopic, MqttQos.atMostOnce);
    hasConnected = true;

    _updatesSub = client.updates?.listen((
      List<MqttReceivedMessage<MqttMessage>> events,
    ) {
      if (events.isEmpty) {
        return;
      }
      final rec = events.first;
      final pub = rec.payload as MqttPublishMessage;
      // mqtt_client uses typed_data.Uint8Buffer for publish payloads, not Uint8List.
      // Reuse: any code reading MqttPublishMessage should use Uint8List.fromList(message).
      final Uint8List payload = Uint8List.fromList(pub.payload.message);
      _handlePayload(payload);
    });
  }

  void _handlePayload(Uint8List payload) {
    try {
      final text = utf8.decode(payload);
      final map = jsonDecode(text) as Map<String, dynamic>;
      final meeting = IsometrikMeeting.fromJson(map);
      _meetingController.add(meeting);
    } catch (_) {
      // Same as Swift: ignore malformed payloads
    }
  }

  /// Swift `unSubscribe`.
  Future<void> unsubscribe() async {
    final c = _client;
    final cfg = _config;
    if (c == null || cfg == null || _userClientId.isEmpty) {
      return;
    }
    final messageTopic =
        '/${cfg.accountId}/${cfg.projectId}/Message/$_userClientId';
    final statusTopic =
        '/${cfg.accountId}/${cfg.projectId}/Status/$_userClientId';
    try {
      c.unsubscribe(messageTopic);
      c.unsubscribe(statusTopic);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
    await unsubscribe();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    _config = null;
    _userClientId = '';
    hasConnected = false;
  }

  Future<void> dispose() async {
    await disconnect();
    await _meetingController.close();
  }
}
