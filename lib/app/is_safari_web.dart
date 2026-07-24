import 'package:web/web.dart' as web;

/// True only for Apple Safari (desktop or iOS), where the native interactive
/// edge-swipe back gesture composites a cached snapshot of the previous
/// history entry before Flutter re-rasterizes the live frame — the #74/#76
/// "flash". Excludes Chromium/Gecko/other engines whose UA also carries the
/// "Safari" token (Chrome, Edge, Opera, Firefox-iOS, Samsung, Android WebView,
/// Chrome-iOS/CriOS). Requires Apple's `navigator.vendor` as the positive
/// signal so Chromium desktop (vendor "Google Inc.") can never match.
bool isSafariBrowser() {
  final navigator = web.window.navigator;
  final ua = navigator.userAgent;
  final hasSafariToken = ua.contains('Safari');
  final isOtherEngine = ua.contains('Chrome') ||
      ua.contains('Chromium') ||
      ua.contains('CriOS') ||
      ua.contains('FxiOS') ||
      ua.contains('EdgiOS') ||
      ua.contains('Edg') ||
      ua.contains('OPiOS') ||
      ua.contains('OPR') ||
      ua.contains('SamsungBrowser') ||
      ua.contains('Android');
  final appleVendor = navigator.vendor.contains('Apple');
  return hasSafariToken && !isOtherEngine && appleVendor;
}
