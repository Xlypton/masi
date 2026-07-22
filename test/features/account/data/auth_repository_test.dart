import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Web port Phase 4 (auth + sync on web), task 1: `emailRedirectTo` must be
/// platform-specific -- native keeps the `io.supabase.climbtopo://` custom
/// URL scheme (unchanged), web must redirect to this app's own origin
/// (there's no OS-level scheme handler in a browser). Exercises
/// [SupabaseAuthRepository.resolveMagicLinkRedirect] directly with its
/// `isWeb`/`origin` test seam, since the real `kIsWeb` is a compile-time
/// constant (always `false` under `flutter test`'s VM target) and `Uri.base`
/// isn't controllable from a VM test either.
void main() {
  group('SupabaseAuthRepository.resolveMagicLinkRedirect', () {
    test(
      'native (isWeb: false) returns the unchanged custom URL scheme, '
      'regardless of origin',
      () {
        expect(
          SupabaseAuthRepository.resolveMagicLinkRedirect(isWeb: false),
          SupabaseAuthRepository.magicLinkRedirect,
        );
        expect(
          SupabaseAuthRepository.magicLinkRedirect,
          'io.supabase.climbtopo://login-callback/',
        );
      },
    );

    test(
      'web (isWeb: true) returns the given origin verbatim -- prod',
      () {
        expect(
          SupabaseAuthRepository.resolveMagicLinkRedirect(
            isWeb: true,
            origin: Uri.parse('https://climbtopo.example.com/some/path'),
          ),
          'https://climbtopo.example.com',
        );
      },
    );

    test(
      'web (isWeb: true) returns the given origin verbatim -- local dev, '
      'preserving the port',
      () {
        expect(
          SupabaseAuthRepository.resolveMagicLinkRedirect(
            isWeb: true,
            origin: Uri.parse('http://localhost:54321/'),
          ),
          'http://localhost:54321',
        );
      },
    );

    test(
      'defaults (no isWeb/origin given) fall back to the real kIsWeb, which '
      'is false under flutter test\'s VM target -- so the default call site '
      'in sendMagicLink() never accidentally picks the web branch here',
      () {
        expect(
          SupabaseAuthRepository.resolveMagicLinkRedirect(),
          SupabaseAuthRepository.magicLinkRedirect,
        );
      },
    );
  });
}
