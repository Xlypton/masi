import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_channel_factory.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArChannel.noop (web-safe no-op channel)', () {
    test('isNoop is true for a noop channel', () {
      final channel = ArChannel.noop();

      expect(channel.isNoop, isTrue);
    });

    test(
      'A1: alignments() completes as an empty stream instead of touching a '
      'real EventChannel',
      () async {
        final channel = ArChannel.noop();

        final events = await channel.alignments().toList();

        expect(events, isEmpty);
      },
    );

    test(
      'A2: lockManual(...) resolves to false without invoking a real '
      'MethodChannel',
      () async {
        final channel = ArChannel.noop();

        final ok = await channel.lockManual(const <Offset>[
          Offset.zero,
          Offset.zero,
          Offset.zero,
          Offset.zero,
        ]);

        expect(ok, isFalse);
      },
    );

    test(
      'start/stop/setMode/rescan/unlockManual all complete without throwing '
      'MissingPluginException',
      () async {
        final channel = ArChannel.noop();

        await channel.start(
          referenceImagePath: 'x',
          refWidth: 1,
          refHeight: 1,
        );
        await channel.stop();
        await channel.setMode(ArMode.manual);
        await channel.rescan();
        await channel.unlockManual();
      },
    );

    test(
      'start() resolves to false without invoking a real MethodChannel',
      () async {
        final channel = ArChannel.noop();

        final result = await channel.start(
          referenceImagePath: 'x',
          refWidth: 1,
          refHeight: 1,
        );

        expect(result, isFalse);
      },
    );
  });

  group('createArChannel (native/VM factory)', () {
    test('returns a non-noop ArChannel on the VM/native target', () {
      final channel = createArChannel();

      expect(channel.isNoop, isFalse);
    });
  });

  group('arSupportedProvider / arAutoTrackingProvider', () {
    test('arAutoTrackingProvider is overridable via ProviderContainer', () {
      final container = ProviderContainer(
        overrides: [arAutoTrackingProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      expect(container.read(arAutoTrackingProvider), isTrue);
    });

    test('arSupportedProvider is overridable via ProviderContainer', () {
      final container = ProviderContainer(
        overrides: [arSupportedProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      expect(container.read(arSupportedProvider), isTrue);
    });
  });
}
