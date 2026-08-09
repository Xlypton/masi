import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/application/offline_banner_dismissal.dart';

ProviderContainer _makeContainer() {
  final container = ProviderContainer();
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
const _sharedPhotosWithheldSignature = 'sharedPhotosWithheld|';

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
      final container = _makeContainer();
      expect(container.read(syncBannerDismissalProvider), isNull);
    });
  });

  group('an ERROR dismissal re-arms when the error identity changes '
      '(rule 1: a different signature never matches)', () {
    test('THE LOAD-BEARING ONE: acknowledging a deferred-rows message does NOT '
        'suppress a later, DIFFERENT failure', () {
      final container = _makeContainer();
      const first = 'Sync failed: 3 rows deferred';
      const second = 'Sync failed: own rows push rejected (401)';

      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_errorSignature(first));

      expect(_showsBanner(container, _errorSignature(first)), isFalse);
      expect(
        _showsBanner(container, _errorSignature(second)),
        isTrue,
        reason: 'a bare "I closed A sync banner" bool would swallow this one',
      );
    });

    test('absent -> present re-arms it too', () {
      final container = _makeContainer();
      // The banner with no reason at all (`detail == null`) is a different
      // message from the same kind carrying one.
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(SyncBannerDismissalController.signature('syncFailed', null));

      expect(
        _showsBanner(container, _errorSignature('Sync failed: boom')),
        isTrue,
      );
    });

    test('the SAME error stays dismissed across arbitrarily many rebuilds '
        '(reportCurrent with a non-null signature never clears it)', () {
      final container = _makeContainer();
      const detail = 'Sync failed: boom';
      final notifier = container.read(syncBannerDismissalProvider.notifier);
      notifier.dismiss(_errorSignature(detail));

      for (var i = 0; i < 5; i++) {
        notifier.reportCurrent(_errorSignature(detail));
        expect(_showsBanner(container, _errorSignature(detail)), isFalse);
      }
    });
  });

  group('rule 2: reportCurrent(null) ends the episode — the same message '
      'recurring after a genuine clear must not stay silenced', () {
    test('reportCurrent(null) clears a stale dismissal', () {
      final container = _makeContainer();
      final notifier = container.read(syncBannerDismissalProvider.notifier);
      notifier.dismiss(_offlineSignature);
      expect(container.read(syncBannerDismissalProvider), _offlineSignature);

      notifier.reportCurrent(null);

      expect(
        container.read(syncBannerDismissalProvider),
        isNull,
        reason: 'nothing is showing any more, so an old acknowledgement of '
            'it is stale and must not outlive the condition',
      );
    });

    test('reportCurrent is a no-op when nothing is dismissed', () {
      final container = _makeContainer();
      final notifier = container.read(syncBannerDismissalProvider.notifier);

      notifier.reportCurrent(null);
      expect(container.read(syncBannerDismissalProvider), isNull);

      notifier.reportCurrent(_offlineSignature);
      expect(
        container.read(syncBannerDismissalProvider),
        isNull,
        reason: 'reportCurrent only ever CLEARS — dismiss() is the only way '
            'to set a dismissal',
      );
    });

    test(
      'THE LOAD-BEARING ONE for `syncFailed`: a dismissal re-arms once the '
      'pull clears the error, even when the NEXT failure has the IDENTICAL '
      'text — rule 1 alone cannot catch this because the message really is '
      'the same; only knowing the condition actually cleared in between can',
      () {
        final container = _makeContainer();
        final notifier = container.read(syncBannerDismissalProvider.notifier);
        const detail = 'Sync failed: boom';

        notifier.dismiss(_errorSignature(detail));
        expect(_showsBanner(container, _errorSignature(detail)), isFalse);

        // A clean pull lands — genuinely nothing is wrong any more.
        notifier.reportCurrent(null);
        expect(container.read(syncBannerDismissalProvider), isNull);

        // A SECOND, unrelated outage happens to produce byte-identical
        // wording (realistic: network errors have stock messages).
        expect(
          _showsBanner(container, _errorSignature(detail)),
          isTrue,
          reason: 'a dismissal that survived the clear would permanently '
              'silence every future failure sharing this wording',
        );
      },
    );

    test(
      'THE LOAD-BEARING ONE for `sharedPhotosWithheld`: its signature is a '
      'CONSTANT (SyncBanner.detail is always null for this kind), so only '
      'reportCurrent(null) can ever re-arm it — rule 1 (a changed signature) '
      'never fires for this kind at all',
      () {
        final container = _makeContainer();
        final notifier = container.read(syncBannerDismissalProvider.notifier);

        notifier.dismiss(_sharedPhotosWithheldSignature);
        expect(
          _showsBanner(container, _sharedPhotosWithheldSignature),
          isFalse,
        );

        // Still under pressure on the next few pulls — reportCurrent reports
        // the SAME signature, which must not disturb the dismissal.
        notifier.reportCurrent(_sharedPhotosWithheldSignature);
        notifier.reportCurrent(_sharedPhotosWithheldSignature);
        expect(
          _showsBanner(container, _sharedPhotosWithheldSignature),
          isFalse,
        );

        // A pull comes back within budget.
        notifier.reportCurrent(null);
        expect(container.read(syncBannerDismissalProvider), isNull);

        // Storage fills up again on a LATER pull — same fixed signature.
        expect(
          _showsBanner(container, _sharedPhotosWithheldSignature),
          isTrue,
          reason: 'THE BUG: because this signature never varies, the old '
              '(offline-only) reset could never re-arm this kind at all — a '
              'permanent, session-long suppression the first time it fired',
        );
      },
    );

    test(
      'an offline dismissal re-arms once reachability comes back and the '
      'signal drops again',
      () {
        final container = _makeContainer();
        final notifier = container.read(syncBannerDismissalProvider.notifier);

        notifier.dismiss(_offlineSignature);
        expect(_showsBanner(container, _offlineSignature), isFalse);

        notifier.reportCurrent(null);
        expect(container.read(syncBannerDismissalProvider), isNull);

        expect(
          _showsBanner(container, _offlineSignature),
          isTrue,
          reason: 'the acknowledgement covers THIS episode and no other',
        );
      },
    );

    test('staying under the same condition keeps it dismissed — one episode, '
        'one dismissal', () {
      final container = _makeContainer();
      final notifier = container.read(syncBannerDismissalProvider.notifier);

      notifier.dismiss(_offlineSignature);
      notifier.reportCurrent(_offlineSignature);
      notifier.reportCurrent(_offlineSignature);

      expect(_showsBanner(container, _offlineSignature), isFalse);
    });
  });

  group('session-scoped and in-memory', () {
    test('a fresh container starts un-dismissed — nothing is persisted, so a '
        'relaunch never inherits "do not tell me I am offline"', () {
      final first = _makeContainer();
      first.read(syncBannerDismissalProvider.notifier).dismiss(_offlineSignature);
      expect(first.read(syncBannerDismissalProvider), _offlineSignature);

      final second = _makeContainer();
      expect(
        second.read(syncBannerDismissalProvider),
        isNull,
        reason:
            'a persisted dismissal would be a setting, and "do not tell '
            'me I am offline" is not one anyone means to make permanent',
      );
    });

    test('no dismissal state survives a rebuild of the provider itself', () {
      final container = _makeContainer();
      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_offlineSignature);

      container.invalidate(syncBannerDismissalProvider);

      expect(container.read(syncBannerDismissalProvider), isNull);
    });
  });

  group('one acknowledgement, every reader', () {
    test('both feeds read the SAME provider, so closing it on one closes it on '
        'the other — it is one condition, acknowledged once', () {
      final container = _makeContainer();
      final seen = <String?>[];
      final sub = container.listen<String?>(
        syncBannerDismissalProvider,
        (previous, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      container
          .read(syncBannerDismissalProvider.notifier)
          .dismiss(_offlineSignature);

      expect(seen, [null, _offlineSignature]);
    });
  });
}
