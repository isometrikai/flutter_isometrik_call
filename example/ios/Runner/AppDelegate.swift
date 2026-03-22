import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Do not call GeneratedPluginRegistrant.register(with: self) here: with
    // FlutterImplicitEngineDelegate, plugins must register only via
    // didInitializeImplicitFlutterEngine. Registering in both places causes
    // "This FlutterEngine was already invoked" and unstable plugin state.
    // The example app retries SharedPreferences until native channels are ready.
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
