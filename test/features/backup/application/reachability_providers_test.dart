import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/reachability_providers.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';

/// Minimal [ConnectivityService] whose probe answer is scripted, and which
/// counts probes so a test can prove `refresh()` does not stampede.
///
/// [statusChanges] degrades to a never-emitting stream, exactly as the
/// abstract contract on `ConnectivityService.statusChanges` requires of an
/// implementation with no platform signal behind it.
class _ScriptedConnectivity implements ConnectivityService {
  _ScriptedConnectivity(this.reachable);

  bool reachable;
  int probeCount = 0;

  /// When non-null, [isBackendReachable] waits on this instead of returning
  /// immediately — lets a test hold a probe open across a container disposal.
  Completer<void>? gate;

  @override
  Future<bool> isBackendReachable() async {
    probeCount++;
    if (gate != null) await gate!.future;
    return reachable;
  }

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

/// A probe that violates `isBackendReachable`'s never-throws contract, to
/// prove the controller absorbs it rather than propagating to the UI.
class _ThrowingConnectivity implements ConnectivityService {
  @override
  Future<bool> isBackendReachable() async => throw StateError('probe blew up');

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

void main() {
  group('Reachability', () {
    test('unknown is neither known-online nor known-offline', () {
      expect(Reachability.unknown.isKnownOffline, isFalse);
      expect(Reachability.unknown.isKnownOnline, isFalse);
    });

    test('online and offline each report exactly their own verdict', () {
      expect(Reachability.online.isKnownOnline, isTrue);
      expect(Reachability.online.isKnownOffline, isFalse);
      expect(Reachability.offline.isKnownOffline, isTrue);
      expect(Reachability.offline.isKnownOnline, isFalse);
    });
  });

  group('reachabilityProvider', () {
    test('starts unknown and never probes until asked', () {
      final connectivity = _ScriptedConnectivity(true);
      final container = _makeContainer(connectivity);

      expect(container.read(reachabilityProvider), Reachability.unknown);
      expect(connectivity.probeCount, 0);
    });

    test('refresh() reports online when the backend answers', () async {
      final connectivity = _ScriptedConnectivity(true);
      final container = _makeContainer(connectivity);

      await container.read(reachabilityProvider.notifier).refresh();

      expect(container.read(reachabilityProvider), Reachability.online);
      expect(connectivity.probeCount, 1);
    });

    test('refresh() reports offline when the probe fails', () async {
      final connectivity = _ScriptedConnectivity(false);
      final container = _makeContainer(connectivity);

      await container.read(reachabilityProvider.notifier).refresh();

      expect(container.read(reachabilityProvider), Reachability.offline);
    });

    test('refresh() returns the verdict it just recorded', () async {
      final connectivity = _ScriptedConnectivity(false);
      final container = _makeContainer(connectivity);

      final verdict = await container
          .read(reachabilityProvider.notifier)
          .refresh();

      expect(verdict, Reachability.offline);
      expect(verdict, container.read(reachabilityProvider));
    });

    test('a probe that throws is absorbed as offline', () async {
      final container = _makeContainer(_ThrowingConnectivity());

      final verdict = await container
          .read(reachabilityProvider.notifier)
          .refresh();

      expect(verdict, Reachability.offline);
      expect(container.read(reachabilityProvider), Reachability.offline);
    });

    test('concurrent refreshes share one in-flight probe', () async {
      final connectivity = _ScriptedConnectivity(false);
      final container = _makeContainer(connectivity);
      final notifier = container.read(reachabilityProvider.notifier);

      await Future.wait([
        notifier.refresh(),
        notifier.refresh(),
        notifier.refresh(),
      ]);

      expect(connectivity.probeCount, 1);
      expect(container.read(reachabilityProvider), Reachability.offline);
    });

    test('a later refresh flips the verdict back', () async {
      final connectivity = _ScriptedConnectivity(false);
      final container = _makeContainer(connectivity);
      final notifier = container.read(reachabilityProvider.notifier);

      await notifier.refresh();
      expect(container.read(reachabilityProvider), Reachability.offline);

      connectivity.reachable = true;
      await notifier.refresh();
      expect(container.read(reachabilityProvider), Reachability.online);
      expect(connectivity.probeCount, 2);
    });

    test('a probe that resolves after disposal never throws', () async {
      final connectivity = _ScriptedConnectivity(false)
        ..gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [connectivityServiceProvider.overrideWithValue(connectivity)],
      );
      final notifier = container.read(reachabilityProvider.notifier);
      final pending = notifier.refresh();

      container.dispose();
      connectivity.gate!.complete();

      await expectLater(pending, completion(Reachability.offline));
    });
  });
}
