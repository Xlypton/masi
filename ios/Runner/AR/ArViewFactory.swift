import Flutter
import UIKit

/// Factory for the native AR camera + Vision-homography platform view,
/// registered under view type "masi/ar" (see `AppDelegate.swift`),
/// matching the Dart-side `UiKitView(viewType: 'masi/ar')`.
///
/// One instance is created in `AppDelegate` and handed to
/// `FlutterPluginRegistrar.register(_:withId:)`. It threads the same
/// `FlutterBinaryMessenger` used for plugin registration through to each
/// `ArPlatformView` it creates, so the `masi/ar` MethodChannel and
/// `masi/ar/alignment` EventChannel (created inside `ArPlatformView`
/// via `ArChannelHandler`) talk to the same Flutter engine instance.
final class ArViewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        ArPlatformView(frame: frame, viewId: viewId, messenger: messenger, args: args)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
