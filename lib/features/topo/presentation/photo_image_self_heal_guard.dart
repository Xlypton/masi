// Pure, platform-agnostic guard logic for the web `PlatformPhotoImage`'s
// error-driven self-heal (see `photo_image_source_web.dart`). Factored out
// of that file so it can be unit-tested directly on the Dart VM: the web
// backend transitively imports `package:web`, which does not compile under
// plain `flutter test` (VM) — see that file's doc — so nothing defined
// there is testable outside a real web compile. This file has zero
// web/js_interop dependencies, so it is.
//
// Context: on web, `PhotoImageCache` can evict and `URL.revokeObjectURL` an
// object URL a still-mounted widget is holding onto (e.g. an inactive
// `IndexedStack` tab under the nav shell), which makes `Image.network` fail
// with no built-in retry. The fix re-resolves through the cache once per
// key. These two pure functions decide (a) whether that one attempt should
// be made, and (b) whether its result counts as a successful heal — kept
// separate from all the stateful/DOM plumbing so the decision itself is
// trivially testable.

/// Whether a self-heal re-resolve attempt should be made for [failedUrl].
///
/// Only fires when [failedUrl] matches [currentUrl] (an error reported for a
/// URL that isn't even the one currently displayed is stale — ignore it) AND
/// no attempt has already been made for the current key
/// ([alreadyAttemptedUrl] is `null`). This caps self-heal at exactly one
/// attempt per key: once the caller records an attempted URL (after this
/// returns `true`), every subsequent call for that same key returns `false`,
/// so a URL that keeps failing degrades to the placeholder instead of
/// looping forever.
bool shouldAttemptPhotoSelfHeal({
  required String failedUrl,
  required String? currentUrl,
  required String? alreadyAttemptedUrl,
}) {
  return failedUrl == currentUrl && alreadyAttemptedUrl == null;
}

/// Whether re-resolving after a failure produced a usable, different URL to
/// swap in. `null` means the underlying bytes are genuinely gone (per
/// `PhotoImageCache.resolveUrl`'s contract: it returns `null` rather than
/// throwing when bytes can't be found). A [resolvedUrl] equal to
/// [failedUrl] would mean re-resolution somehow handed back the exact URL
/// that just failed — defensively treated as a non-heal too, so the caller
/// never re-renders the same already-broken URL.
bool isSuccessfulPhotoSelfHeal({
  required String? resolvedUrl,
  required String failedUrl,
}) {
  return resolvedUrl != null && resolvedUrl != failedUrl;
}
