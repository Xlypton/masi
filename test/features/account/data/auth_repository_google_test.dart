import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// `signInWithGoogle` must not go through `url_launcher` on web.
///
/// Google is the ONLY working sign-in path in the iOS PWA (email OTP is
/// blocked on the Supabase free tier), and tapping "Continue with Google" did
/// nothing at all: `signInWithOAuth` -> `launchUrl(webOnlyWindowName: '_self')`
/// -> `url_launcher_web`'s `window.open(url, '_self', 'noopener,noreferrer')`,
/// whose `openNewWindow` hardcodes `return true` and so cannot report a
/// refused window. `signInWithGoogle` then discarded that `bool` too, leaving
/// two layers of swallowed failure and a total lockout that looked like a dead
/// button.
///
/// These tests drive the real [SupabaseAuthRepository] against a real
/// [SupabaseClient] (no network: `getOAuthSignInUrl` only builds a URL and
/// stores a PKCE verifier) with the platform redirect seam faked through the
/// constructor — the compile-time `dart.library.js_interop` condition behind
/// `oauth_redirect.dart` can't be flipped from a VM test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const authority = 'test-ref.supabase.co';

  late _MemoryPkceStorage pkceStorage;
  late SupabaseClient client;

  SupabaseClient buildClient() => SupabaseClient(
    'https://$authority',
    'test-anon-key',
    authOptions: AuthClientOptions(
      pkceAsyncStorage: pkceStorage,
      // Nothing here signs in, and a live refresh ticker would just leak a
      // pending timer into the test.
      autoRefreshToken: false,
    ),
  );

  setUp(() {
    pkceStorage = _MemoryPkceStorage();
    client = buildClient();
  });

  group('signInWithGoogle — web (top-level redirect available)', () {
    test('builds the authorize URL and hands it to the redirect seam', () async {
      String? redirectedTo;
      final repository = SupabaseAuthRepository(
        client,
        canRedirectTopLevel: () => true,
        redirectTopLevel: (url) async {
          redirectedTo = url;
          return true;
        },
      );

      await repository.signInWithGoogle();

      expect(
        redirectedTo,
        isNotNull,
        reason: 'the seam must be handed the URL, not url_launcher',
      );
      final uri = Uri.parse(redirectedTo!);
      expect(uri.host, authority);
      expect(uri.path, '/auth/v1/authorize');
      expect(uri.queryParameters['provider'], 'google');
    });

    test(
      'sends redirectTo exactly as resolveMagicLinkRedirect() returns it — it '
      'must keep matching the Supabase allow list character-for-character',
      () async {
        String? redirectedTo;
        final repository = SupabaseAuthRepository(
          client,
          canRedirectTopLevel: () => true,
          redirectTopLevel: (url) async {
            redirectedTo = url;
            return true;
          },
        );

        await repository.signInWithGoogle();

        expect(
          Uri.parse(redirectedTo!).queryParameters['redirect_to'],
          SupabaseAuthRepository.resolveMagicLinkRedirect(),
        );
      },
    );

    test('carries a PKCE challenge, so the return trip can complete', () async {
      String? redirectedTo;
      final repository = SupabaseAuthRepository(
        client,
        canRedirectTopLevel: () => true,
        redirectTopLevel: (url) async {
          redirectedTo = url;
          return true;
        },
      );

      await repository.signInWithGoogle();

      expect(
        Uri.parse(redirectedTo!).queryParameters['code_challenge'],
        isNotNull,
      );
      expect(pkceStorage.items.keys, anyElement(contains('code-verifier')));
    });

    test('never touches url_launcher', () async {
      final launcherCalls = <MethodCall>[];
      _mockUrlLauncher(launcherCalls, result: true);

      final repository = SupabaseAuthRepository(
        client,
        canRedirectTopLevel: () => true,
        redirectTopLevel: (url) async => true,
      );

      await repository.signInWithGoogle();

      expect(launcherCalls, isEmpty);
    });

    test(
      'THROWS when the redirect is refused — this is the regression that made '
      'a total lockout look like a dead button',
      () async {
        final repository = SupabaseAuthRepository(
          client,
          canRedirectTopLevel: () => true,
          redirectTopLevel: (url) async => false,
        );

        await expectLater(
          repository.signInWithGoogle(),
          throwsA(isA<AuthException>()),
        );
      },
    );

    test(
      'STAGE 1: the refusal message names the host it tried to redirect to, '
      'but never the query string (which carries the PKCE code_challenge)',
      () async {
        final repository = SupabaseAuthRepository(
          client,
          canRedirectTopLevel: () => true,
          redirectTopLevel: (url) async => false,
        );

        try {
          await repository.signInWithGoogle();
          fail('expected an AuthException');
        } catch (e) {
          expect(e, isA<AuthException>());
          final message = (e as AuthException).message;
          expect(
            message,
            contains(authority),
            reason: 'must name which host the redirect targeted',
          );
          expect(
            message,
            isNot(contains('code_challenge')),
            reason: 'must never leak the PKCE query string into a rendered '
                'error message',
          );
        }
      },
    );
  });

  group('signInWithGoogle — native (no top-level redirect)', () {
    test(
      'still routes through signInWithOAuth, i.e. url_launcher, with the same '
      'authorize URL and redirectTo as before',
      () async {
        final launcherCalls = <MethodCall>[];
        _mockUrlLauncher(launcherCalls, result: true);

        var seamCalls = 0;
        final repository = SupabaseAuthRepository(
          client,
          canRedirectTopLevel: () => false,
          redirectTopLevel: (url) async {
            seamCalls++;
            return true;
          },
        );

        await repository.signInWithGoogle();

        expect(seamCalls, 0, reason: 'native must not use the web seam');
        expect(launcherCalls, hasLength(1));
        expect(launcherCalls.single.method, 'launch');

        final launched = Uri.parse(
          (launcherCalls.single.arguments as Map)['url'] as String,
        );
        expect(launched.host, authority);
        expect(launched.path, '/auth/v1/authorize');
        expect(launched.queryParameters['provider'], 'google');
        expect(
          launched.queryParameters['redirect_to'],
          SupabaseAuthRepository.resolveMagicLinkRedirect(),
        );
      },
    );

    test('throws when url_launcher reports it launched nothing', () async {
      _mockUrlLauncher(<MethodCall>[], result: false);

      final repository = SupabaseAuthRepository(
        client,
        canRedirectTopLevel: () => false,
      );

      await expectLater(
        repository.signInWithGoogle(),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('default seam (no overrides)', () {
    test(
      'defaults to the stub backend under flutter test\'s VM target, so the '
      'production call site takes the native branch here',
      () async {
        final launcherCalls = <MethodCall>[];
        _mockUrlLauncher(launcherCalls, result: true);

        await SupabaseAuthRepository(client).signInWithGoogle();

        expect(launcherCalls, hasLength(1));
      },
    );
  });
}

/// Intercepts `url_launcher`'s method channel — in `flutter test` no plugin is
/// registered, so `UrlLauncherPlatform.instance` is the plain
/// `MethodChannelUrlLauncher` and this is the only place the native
/// `signInWithOAuth` path becomes observable. Records every call into [sink]
/// and answers `launch` with [result].
void _mockUrlLauncher(List<MethodCall> sink, {required bool result}) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        sink.add(call);
        return result;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

/// Minimal in-memory [GotrueAsyncStorage] so gotrue can persist the PKCE code
/// verifier `getOAuthSignInUrl` mints (it asserts on a null storage).
class _MemoryPkceStorage extends GotrueAsyncStorage {
  final Map<String, String> items = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => items[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    items[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    items.remove(key);
  }
}
