import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Resolves a stable per-install device id (iOS: `identifierForVendor`, Android: androidId).
class IsometrikDeviceId {
  IsometrikDeviceId._();

  static final IsometrikDeviceId instance = IsometrikDeviceId._();

  String? _cached;

  Future<String> resolve() async {
    if (_cached != null) {
      return _cached!;
    }
    final plugin = DeviceInfoPlugin();
    if (kIsWeb) {
      _cached = 'web-${DateTime.now().millisecondsSinceEpoch}';
      return _cached!;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final info = await plugin.iosInfo;
      _cached = info.identifierForVendor ?? 'ios-unknown';
      return _cached!;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final info = await plugin.androidInfo;
      _cached = info.id;
      return _cached!;
    }
    _cached = 'device-${defaultTargetPlatform.name}';
    return _cached!;
  }
}
