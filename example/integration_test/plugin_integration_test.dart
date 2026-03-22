// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialize API test', (WidgetTester tester) async {
    final IsometrikFlutterCall plugin = IsometrikFlutterCall();
    await plugin.initialize(
      const IsometrikCallConfiguration(
        accountId: 'a',
        projectId: 'p',
        keysetId: 'k',
        licenseKey: 'l',
        appSecret: 'as',
        userSecret: 'us',
      ),
    );
    expect(true, isTrue);
  });
}
