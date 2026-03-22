import 'package:flutter_test/flutter_test.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call_platform_interface.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call_method_channel.dart';

void main() {
  final IsometrikFlutterCallPlatform initialPlatform =
      IsometrikFlutterCallPlatform.instance;

  test('$MethodChannelIsometrikFlutterCall is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelIsometrikFlutterCall>());
  });
}
