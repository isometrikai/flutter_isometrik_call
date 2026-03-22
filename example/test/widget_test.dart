// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:isometrik_flutter_call_example/app/example_app_controller.dart';
import 'package:isometrik_flutter_call_example/main.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('renders login title', (WidgetTester tester) async {
    // Mirrors [main] — [IsometrikExampleApp] depends on [ExampleAppController].
    // Use [ExampleAppController.forWidgetTest] so tests do not depend on plugins.
    await tester.pumpWidget(
      ChangeNotifierProvider<ExampleAppController>(
        create: (_) => ExampleAppController.forWidgetTest(),
        child: const IsometrikExampleApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Isometrik Call'), findsOneWidget);
  });
}
