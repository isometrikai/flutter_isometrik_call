import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelIsometrikFlutterCall platform =
      MethodChannelIsometrikFlutterCall();
  const MethodChannel channel = MethodChannel('isometrik_flutter_call');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          log.add(methodCall);
          return null;
        });
  });

  tearDown(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initialize delegates to method channel', () async {
    await platform.initialize(<String, dynamic>{'projectId': 'test-project'});
    expect(log.single.method, 'initialize');
    expect(log.single.arguments, <String, dynamic>{
      'projectId': 'test-project',
    });
  });

  test('wasCallKitReportedNatively delegates to method channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          log.add(methodCall);
          return true;
        });
    final v = await platform.wasCallKitReportedNatively();
    expect(v, isTrue);
    expect(log.single.method, 'wasCallKitReportedNatively');
  });
}
