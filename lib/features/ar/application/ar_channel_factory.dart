// Facade for constructing the platform-appropriate [ArChannel]. Conditional
// export picks the right backend, exactly like `lib/core/platform/ar_support.dart`:
//  - native (iOS/Android/desktop): a real ArChannel backed by the actual
//    `climbtopo/ar` platform channels.
//  - web (and anything else without dart:io): ArChannel.noop() — no native
//    `climbtopo/ar` handler exists on web, so a real ArChannel would throw
//    MissingPluginException on every call.
export 'ar_channel_factory_native.dart'
    if (dart.library.js_interop) 'ar_channel_factory_web.dart';
