import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Retains the always-registered stateless rock-segmentation channel
  /// handler ("masi/arSegmentation"). It must be held for the app's
  /// lifetime: `FlutterMethodChannel.setMethodCallHandler` does NOT keep the
  /// handler object alive, so without this stored property the handler would
  /// deallocate immediately after `didInitializeImplicitFlutterEngine`
  /// returns and every `segmentPreview` call would silently no-op.
  private var arSegmentationChannelHandler: ArSegmentationChannelHandler?

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

    // Stateless rock/wall segmentation channel ("masi/arSegmentation").
    // MUST be its own always-registered channel (not "masi/ar", which only
    // exists while a UiKitView is mounted -- see ArPlatformView.init), so a
    // segmentation preview can be requested before any AR view is on screen.
    // Retained via the stored property above so the handler outlives this
    // call.
    arSegmentationChannelHandler = ArSegmentationChannelHandler(messenger: registrar.messenger())
  }
}
