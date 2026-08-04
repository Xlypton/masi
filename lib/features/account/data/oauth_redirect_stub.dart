/// Fallback used on native (iOS/Android/desktop) and in plain Dart VM tests,
/// where there is no browsing context to redirect at all. See
/// `oauth_redirect.dart`.
///
/// Always `false`, which is what routes
/// `SupabaseAuthRepository.signInWithGoogle` down its unchanged native
/// `signInWithOAuth` branch. Mirrors `pwa_install_stub.dart`'s always-inert
/// shape.
bool canRedirectTopLevel() => false;

/// See [canRedirectTopLevel] — there is nothing to redirect off-web, so this
/// is never reached in practice. Reports failure (`false`) rather than
/// pretending to have navigated: silently claiming success is precisely the
/// bug `oauth_redirect.dart` documents.
Future<bool> redirectTopLevel(String url) async => false;
