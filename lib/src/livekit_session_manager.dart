import 'package:livekit_client/livekit_client.dart';

/// Small wrapper over LiveKit room lifecycle to keep host apps simple.
class IsometrikLiveKitSessionManager {
  Room? _room;

  Room? get currentRoom => _room;

  Future<Room> connect({
    required String url,
    required String token,
    RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
  }) async {
    final room = Room(roomOptions: roomOptions ?? RoomOptions());
    await room.connect(
      url,
      token,
      fastConnectOptions: fastConnectOptions ?? FastConnectOptions(),
    );
    _room = room;
    return room;
  }

  Future<void> disconnect() async {
    await _room?.disconnect();
    _room = null;
  }
}
