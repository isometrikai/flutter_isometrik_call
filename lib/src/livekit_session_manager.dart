import 'package:livekit_client/livekit_client.dart';

/// Small wrapper over LiveKit room lifecycle to keep host apps simple.
///
/// Defaults follow [LiveKit Flutter guidance](https://docs.livekit.io/transport/sdk-platforms/flutter/):
/// `adaptiveStream` / `dynacast`, and **microphone enabled on fast connect** — the SDK’s
/// [FastConnectOptions] defaults `microphone` to **false**, which breaks background / CallKit
/// answer flows if you never republish audio in time.
class IsometrikLiveKitSessionManager {
  Room? _room;

  Room? get currentRoom => _room;

  Future<Room> connect({
    required String url,
    required String token,
    RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
    /// When true, request camera during fast connect (video calls). Requires camera permission first.
    bool fastPublishCamera = false,
  }) async {
    final effectiveRoomOptions = roomOptions ??
        const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        );
    final effectiveFast = fastConnectOptions ??
        FastConnectOptions(
          microphone: const TrackOption(enabled: true),
          camera: TrackOption(enabled: fastPublishCamera),
        );
    final room = Room(roomOptions: effectiveRoomOptions);
    await room.connect(
      url,
      token,
      fastConnectOptions: effectiveFast,
    );
    _room = room;
    return room;
  }

  Future<void> disconnect() async {
    await _room?.disconnect();
    _room = null;
  }
}
