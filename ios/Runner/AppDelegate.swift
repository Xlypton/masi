import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Native AR camera + Vision-homography PlatformView (see
    // ios/Runner/AR/). ArViewFactory threads this registrar's messenger
    // through to each ArPlatformView it creates; ArPlatformView is where
    // the "masi/ar" MethodChannel and "masi/ar/alignment"
    // EventChannel are actually instantiated (via ArChannelHandler),
    // against this same messenger, matching the Dart contract exactly.
    let registrar = engineBridge.applicationRegistrar
    registrar.register(ArViewFactory(messenger: registrar.messenger()), withId: "masi/ar")
  }
}
