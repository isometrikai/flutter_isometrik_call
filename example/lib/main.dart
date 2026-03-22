import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/example_app_controller.dart';
import 'config/demo_config.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';

/// Global navigator key — shared with [ExampleAppController] so the SDK
/// can push the call page on incoming calls automatically.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDemoEnv();
  runApp(
    ChangeNotifierProvider<ExampleAppController>(
      create: (_) => ExampleAppController(navigatorKey: navigatorKey),
      child: const IsometrikExampleApp(),
    ),
  );
}

class IsometrikExampleApp extends StatelessWidget {
  const IsometrikExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Isometrik Flutter Call',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExampleAppController>();
    switch (c.gate) {
      case AuthGate.bootstrapping:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthGate.loggedOut:
        return const LoginPage();
      case AuthGate.loggedIn:
        return const HomeShell();
    }
  }
}
