import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/offline_banner_dismissal.dart';
import 'package:masi/features/backup/application/reachability_providers.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';

/// Minimal scripted [ConnectivityService] — same shape as
/// `reachability_providers_test.dart`'s, so `refresh()` drives a real verdict
/// through the real controller rather than a stubbed provider.
class _ScriptedConnectivity implements ConnectivityService {
  _ScriptedConnectivity(this.reachable);

  bool reachable;

  @override
  Future<bool> isBackendReachable() async => reachable;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

ProviderContainer _makeContainer(ConnectivityService connectivity) {
  final container = ProviderContainer(
    overrides: [connectivityServiceProvider.overrideWithValue(connectivity)],
  );
  addTearDown(container.dispose);
  return container;
}

/// What a screen computes before rendering: the banner shows unless the stored
/// dismissal is for exactly this message.
bool _showsBanner(ProviderContainer c, String signature) =>
    c.read(syncBannerDismissalProvider) != signature;

String _errorSignature(String detail) =>
    SyncBannerDismissalController.signature('syncFailed', detail);

const _offlineSignature = 'offline|';

void main() {
  group('signature identity', () {
    test('a kind plus its reason is what a dismissal is scoped to', () {
      expect(
        SyncBannerDismissalController.signature('syncFailed', 'boom'),
        isNot(SyncBannerDismissalController.signature('syncFailed', 'bang')),
      );
      expect(
        SyncBannerDismissalController.signature('syncFailed', null),
        isNot(SyncBannerDismissalController.signature('syncFailed', 'boom')),
      );
      expect(
        SyncBannerDismissalController.signature('offline', null),
        isNot(SyncBannerDismissalController.signature('syncFailed', null)),
      );
      // Same message twice is the SAME acknowledgement — otherwise a rebuild
      // would resurrect a banner the user just closed.
      expect(
        SyncBannerDismissalController.signature('syncFailed', 'boom'),
        SyncBannerDismissalController.signature('syncFailed', 'boom'),
      );
    });
  });

  group('nothing is dismissed to begin with', () {
    test('the initial state is null — no banner starts out acknowledged', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      expect(container.read(syncBannerDismissalProvider), isNull);
    });
  });

  group('an ERROR dismissal re-arms when the error identity changes', () {
    test('THE LOAD-BEARING ONE: acknowledging a deferred-rows message does NOT '
        'suppress a later, DIFFERENT failure', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      const first = 'Sync failed: 3 rows deferred';
      const second = 'Sync failed: own rows push rejected (401)';

      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_errorSignature(first), endsWithOfflineEpisode: false);

      expect(_showsBanner(container, _errorSignature(first)), isFalse);
      expect(
        _showsBanner(container, _errorSignature(second)),
        isTrue,
        reason: 'a bare "I closed A sync banner" bool would swallow this one',
      );
    });

    test('absent -> present re-arms it too', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      // The banner with no reason at all (`detail == null`) is a different
      // message from the same kind carrying one.
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(
            SyncBannerDismissalController.signature('syncFailed', null),
            endsWithOfflineEpisode: false,
          );

      expect(
        _showsBanner(container, _errorSignature('Sync failed: boom')),
        isTrue,
      );
    });

    test('the SAME error stays dismissed across arbitrarily many rebuilds', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      const detail = 'Sync failed: boom';
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_errorSignature(detail), endsWithOfflineEpisode: false);

      for (var i = 0; i < 5; i++) {
        expect(_showsBanner(container, _errorSignature(detail)), isFalse);
      }
    });

    test('a reachability probe flipping does NOT clear an ERROR dismissal — on '
        'these screens a probe runs on every mount, which would resurrect an '
        'identical message the user just closed', () async {
      final connectivity = _ScriptedConnectivity(true);
      final container = _makeContainer(connectivity);
      const detail = 'Sync failed: boom';
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_errorSignature(detail), endsWithOfflineEpisode: false);

      connectivity.reachable = false;
      await container.read(reachabilityProvider.notifier).refresh();
      connectivity.reachable = true;
      await container.read(reachabilityProvider.notifier).refresh();

      expect(_showsBanner(container, _errorSignature(detail)), isFalse);
    });
  });

  group('an OFFLINE dismissal expires with its offline episode', () {
    test(
      'offline -> online -> offline shows it again: a dismissal that survived '
      'that would recreate the bug the banner exists for',
      () async {
        final connectivity = _ScriptedConnectivity(false);
        final container = _makeContainer(connectivity);
        // The screens keep a listener on this provider alive; read it once so
        // the controller is built and its `ref.listen` is armed.
        expect(container.read(syncBannerDismissalProvider), isNull);
        await container.read(reachabilityProvider.notifier).refresh();

        container
            .read(syncBannerDismissalProvider.notifier)
            .dismiss(_offlineSignature, endsWithOfflineEpisode: true);
        expect(_showsBanner(container, _offlineSignature), isFalse);

        connectivity.reachable = true;
        await container.read(reachabilityProvider.notifier).refresh();

        expect(
          _showsBanner(container, _offlineSignature),
          isTrue,
          reason: 'the acknowledgement covers THIS episode and no other',
        );
      },
    );

    test(
      'staying offline keeps it dismissed — one episode, one dismissal',
      () async {
        final connectivity = _ScriptedConnectivity(false);
        final container = _makeContainer(connectivity);
        expect(container.read(syncBannerDismissalProvider), isNull);
        await container.read(reachabilityProvider.notifier).refresh();

        container
            .read(syncBannerDismissalProvider.notifier)
            .dismiss(_offlineSignature, endsWithOfflineEpisode: true);

        await container.read(reachabilityProvider.notifier).refresh();
        await container.read(reachabilityProvider.notifier).refresh();

        expect(_showsBanner(container, _offlineSignature), isFalse);
      },
    );
  });

  group('session-scoped and in-memory', () {
    test('a fresh container starts un-dismissed — nothing is persisted, so a '
        'relaunch never inherits "do not tell me I am offline"', () {
      final first = _makeContainer(_ScriptedConnectivity(true));
      first
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_offlineSignature, endsWithOfflineEpisode: true);
      expect(first.read(syncBannerDismissalProvider), _offlineSignature);

      final second = _makeContainer(_ScriptedConnectivity(true));
      expect(
        second.read(syncBannerDismissalProvider),
        isNull,
        reason:
            'a persisted dismissal would be a setting, and "do not tell '
            'me I am offline" is not one anyone means to make permanent',
      );
    });

    test('no dismissal state survives a rebuild of the provider itself', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_offlineSignature, endsWithOfflineEpisode: true);

      container.invalidate(syncBannerDismissalProvider);

      expect(container.read(syncBannerDismissalProvider), isNull);
    });
  });

  group('one acknowledgement, every reader', () {
    test('both feeds read the SAME provider, so closing it on one closes it on '
        'the other — it is one condition, acknowledged once', () {
      final container = _makeContainer(_ScriptedConnectivity(true));
      final seen = <String?>[];
      final sub = container.listen<String?>(
        syncBannerDismissalProvider,
        (previous, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_offlineSignature, endsWithOfflineEpisode: true);

      expect(seen, [null, _offlineSignature]);
    });
  });
}
