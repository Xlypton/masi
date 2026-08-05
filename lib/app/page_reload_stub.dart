/// Non-web (native + `flutter test`, where `dart.library.js_interop` is
/// unavailable) stub: reloading a running native app is not a concept, so
/// this is a no-op. See [page_reload.dart].
///
/// REGRESSION GUARD (`storage_retry_banner_test.dart`): must return
/// normally — never throw, never hang — because the widget calls this seam
/// unconditionally through `pageReloadProvider`. `StorageRetryBanner`'s
/// escalated action is web-relevant today, but nothing about the widget or
/// its test should depend on that; a throwing/hanging stub would turn the
/// one working recovery into a crash everywhere the seam is exercised off
/// web, including every widget test.
void reloadPage() {}
