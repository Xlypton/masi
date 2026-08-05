import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/config/supabase_init_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';

/// Minimal signed-out [AuthRepository] — this file never exercises auth, it
/// only needs `authRepositoryProvider` to be OVERRIDABLE so a rebuild is
/// observable (see the invalidation test).
class _StubAuthRepository implements AuthRepository {
  @override
  Stream<AuthSessionState> authStateChanges() => const Stream.empty();

  @override
  AuthSessionState get currentSession => const AuthSessionState.signedOut();

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  /// [attempts] is consumed one entry per `initialize()` call: `null` = that
  /// attempt succeeds, an `Object` = that attempt throws it. Lets a test
  /// script "fails at boot, succeeds on retry" exactly.
  ({ProviderContainer container, int Function() calls}) makeContainer(
    List<Object?> attempts, {
    void Function()? onAuthBuild,
  }) {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        supabaseInitializerProvider.overrideWithValue(() async {
          final failure = calls < attempts.length ? attempts[calls] : null;
          calls++;
          if (failure != null) throw failure;
        }),
        authRepositoryProvider.overrideWith((ref) {
          onAuthBuild?.call();
          return _StubAuthRepository();
        }),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, calls: () => calls);
  }

  group('CloudInitController.initialize', () {
    test('starts pending — which must NOT read as "broken"', () {
      final (container: container, calls: _) = makeContainer(const []);

      final state = container.read(cloudInitProvider);
      expect(state.status, CloudInitStatus.pending);
      expect(
        state.isFailed,
        isFalse,
        reason: 'every unit/widget test that never initializes Supabase sits '
            'in this state; if pending counted as failed, the whole suite '
            'would be told the cloud is down',
      );
    });

    test('a successful init reports ready', () async {
      final (container: container, calls: calls) = makeContainer(const []);

      expect(await container.read(cloudInitProvider.notifier).initialize(), isTrue);
      expect(container.read(cloudInitProvider).status, CloudInitStatus.ready);
      expect(calls(), 1);
    });

    test(
      'a FAILED init is RECORDED, not merely logged — and never throws, so '
      'boot survives and local-first work keeps running',
      () async {
        final boom = StateError('no-network-at-boot');
        final (container: container, calls: _) = makeContainer([boom]);

        // Returning false rather than throwing is the whole contract: `main`'s
        // pre-first-frame `Future.wait` must not be taken down by a cloud
        // that isn't there.
        expect(
          await container.read(cloudInitProvider.notifier).initialize(),
          isFalse,
        );

        final state = container.read(cloudInitProvider);
        expect(state.status, CloudInitStatus.failed);
        expect(state.isFailed, isTrue);
        expect(
          state.error,
          same(boom),
          reason: 'the cause is the only clue a field report will carry',
        );
      },
    );

    test('already-ready is idempotent: the singleton is not touched again', () async {
      final (container: container, calls: calls) = makeContainer(const []);
      final controller = container.read(cloudInitProvider.notifier);

      await controller.initialize();
      await controller.initialize();
      await controller.initialize();

      expect(calls(), 1);
    });

    test(
      'a retry after a failure re-attempts the init and reports ready — a '
      'transient boot-time outage must not need an app restart',
      () async {
        final (container: container, calls: calls) = makeContainer([
          StateError('boot-outage'),
        ]);
        final controller = container.read(cloudInitProvider.notifier);

        expect(await controller.initialize(), isFalse);
        expect(container.read(cloudInitProvider).isFailed, isTrue);

        expect(await controller.initialize(), isTrue);
        expect(container.read(cloudInitProvider).status, CloudInitStatus.ready);
        expect(
          calls(),
          2,
          reason: 'the retry must actually re-run the initializer, not just '
              'flip a flag',
        );
      },
    );

    test(
      'a retry that SUCCEEDS invalidates the providers that cached '
      'cloud-less fallbacks — otherwise the retry is cosmetic',
      () async {
        var authBuilds = 0;
        final (container: container, calls: _) = makeContainer(
          [StateError('boot-outage')],
          onAuthBuild: () => authBuilds++,
        );
        final controller = container.read(cloudInitProvider.notifier);

        await controller.initialize();
        // Build it while the cloud is down, exactly as `syncServiceProvider`
        // does when it swaps in `_SignedOutAuthRepository`.
        container.read(authRepositoryProvider);
        expect(authBuilds, 1);

        await controller.initialize();
        container.read(authRepositoryProvider);

        expect(
          authBuilds,
          2,
          reason: 'without the invalidation, supabaseClientProvider keeps its '
              'cached LateInitializationError and syncServiceProvider keeps '
              'its cached _UnavailableSyncRemote for the whole app run',
        );
      },
    );

    group('a HUNG init is bounded (B1)', () {
      // `Supabase.initialize` is a network round trip with no timeout of its
      // own. A stall left this `pending` for the rest of the run, and `pending`
      // deliberately means "not broken" downstream — `SyncOrchestrator` reads
      // it as fine — so a cloud that never came up was presented to the user as
      // a healthy, synced app whose topos existed on exactly one device.
      //
      // A container whose initializer never completes. `tiny` keeps the wait
      // deterministic (the initializer NEVER completes, so the timeout always
      // wins) without a real 15s sleep.
      const tiny = Duration(milliseconds: 20);

      ({ProviderContainer container, Completer<void> init}) makeHung() {
        final init = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            supabaseInitializerProvider.overrideWithValue(() => init.future),
            authRepositoryProvider.overrideWith(
              (ref) => _StubAuthRepository(),
            ),
          ],
        );
        addTearDown(() {
          if (!init.isCompleted) init.complete();
          container.dispose();
        });
        return (container: container, init: init);
      }

      test(
        'it RESOLVES instead of hanging boot, and records a failure the sync '
        'layer can actually see',
        () async {
          final (container: container, init: _) = makeHung();

          expect(
            await container
                .read(cloudInitProvider.notifier)
                .initialize(timeout: tiny),
            isFalse,
            reason: 'unbounded, this await never returned at all',
          );

          final state = container.read(cloudInitProvider);
          expect(
            state.isFailed,
            isTrue,
            reason: 'THE fix: `pending` is treated as "not broken" everywhere '
                'downstream, so a stall used to be invisible',
          );
          expect(state.error, isA<TimeoutException>());
          expect(
            cloudUnavailableMessage(state),
            contains("couldn't connect to the cloud"),
            reason: 'and the user is told, in the existing sync-banner words',
          );
        },
      );

      test(
        'the attempt is BOUNDED, not abandoned: a late success still recovers '
        'the cloud rather than leaving it dead for the run',
        () async {
          var authBuilds = 0;
          final init = Completer<void>();
          final container = ProviderContainer(
            overrides: [
              supabaseInitializerProvider.overrideWithValue(() => init.future),
              authRepositoryProvider.overrideWith((ref) {
                authBuilds++;
                return _StubAuthRepository();
              }),
            ],
          );
          addTearDown(container.dispose);

          await container
              .read(cloudInitProvider.notifier)
              .initialize(timeout: tiny);
          expect(container.read(cloudInitProvider).isFailed, isTrue);
          container.read(authRepositoryProvider);
          expect(authBuilds, 1);

          // The round trip finally lands, seconds after we gave up on it.
          init.complete();
          await Future<void>.delayed(Duration.zero);

          expect(
            container.read(cloudInitProvider).status,
            CloudInitStatus.ready,
            reason: 'a merely-SLOW init must not be branded permanently dead — '
                '`Supabase.instance.client` really does exist now',
          );
          container.read(authRepositoryProvider);
          expect(
            authBuilds,
            2,
            reason: 'and the providers that cached a cloud-less fallback have '
                'to be dropped, exactly as after a manual retry',
          );
        },
      );

      test('the bound is under boot\'s storage deadline, so the cloud names '
          'its own failure first', () {
        expect(kCloudInitTimeout < const Duration(seconds: 30), isTrue);
        expect(
          kCloudInitTimeout >= const Duration(seconds: 10),
          isTrue,
          reason: 'one HTTPS round trip on bad mobile data must not be called '
              'broken',
        );
      });
    });

    test('a first-attempt success does NOT invalidate anything', () async {
      var authBuilds = 0;
      final (container: container, calls: _) = makeContainer(
        const [],
        onAuthBuild: () => authBuilds++,
      );

      container.read(authRepositoryProvider);
      await container.read(cloudInitProvider.notifier).initialize();
      container.read(authRepositoryProvider);

      expect(
        authBuilds,
        1,
        reason: 'boot initializes before anything cloud-derived is built, so '
            'the ordinary path must not churn the provider graph',
      );
    });
  });

  group('cloudUnavailableMessage', () {
    test('leads with the consequence and carries the cause', () {
      final message = cloudUnavailableMessage(
        const CloudInitState.failed('kaboom'),
      );

      // Phrased to slot into the existing #72 surface, which renders
      // "Couldn't sync — $detail." (see `SyncBanner.messageFor`), so the
      // sentence must start lowercase and read as a reason.
      expect(message, startsWith("the app couldn't connect to the cloud"));
      expect(
        message,
        contains('safe on this device'),
        reason: 'the honest reassurance: local-first work is intact',
      );
      expect(message, contains('kaboom'));
      expect(
        "Couldn't sync — $message.",
        contains("Couldn't sync — the app couldn't connect"),
      );
    });

    test('omits the parenthetical when there is no error object', () {
      expect(
        cloudUnavailableMessage(const CloudInitState.ready()),
        isNot(contains('(')),
      );
    });
  });
}
