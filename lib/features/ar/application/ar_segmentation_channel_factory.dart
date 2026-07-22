// Facade for constructing the platform-appropriate [ArSegmentationChannel].
// Conditional export picks the right backend, exactly like
// `ar_channel_factory.dart`:
//  - native (iOS/Android/desktop): a real ArSegmentationChannel backed by the
//    actual `masi/arSegmentation` platform channel.
//  - web (and anything else without dart:io): ArSegmentationChannel.noop() —
//    no native `masi/arSegmentation` handler exists on web, so a real channel
//    would throw MissingPluginException on every call.
export 'ar_segmentation_channel_factory_native.dart'
    if (dart.library.js_interop) 'ar_segmentation_channel_factory_web.dart';
