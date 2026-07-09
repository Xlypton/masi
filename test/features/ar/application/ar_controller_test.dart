import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/application/ar_controller.dart';
import 'package:climbtopo/features/ar/domain/homography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArState', () {
    test('copyWith overrides only the given fields', () {
      const initial = ArState(mode: ArMode.auto, active: false);
      final alignment = ArAlignment(
        homography: Homography.identity(),
        confidence: 0.5,
        tracking: true,
      );

      final updated = initial.copyWith(mode: ArMode.manual);
      expect(updated.mode, ArMode.manual);
      expect(updated.active, isFalse);
      expect(updated.latest, isNull);

      final withAlignment = updated.copyWith(latest: alignment, active: true);
      expect(withAlignment.mode, ArMode.manual);
      expect(withAlignment.latest, alignment);
      expect(withAlignment.active, isTrue);
    });

    test('equality/hashCode are value-based', () {
      final alignment = ArAlignment(
        homography: Homography.identity(),
        confidence: 0.5,
        tracking: true,
      );
      final a = ArState(mode: ArMode.auto, latest: alignment, active: true);
      final b = ArState(mode: ArMode.auto, latest: alignment, active: true);
      const c = ArState(mode: ArMode.manual, active: true);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ArController', () {
    const method = MethodChannel('climbtopo/ar');
    const event = EventChannel('climbtopo/ar/alignment');

    final List<MethodCall> calls = <MethodCall>[];

    late ProviderContainer container;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (MethodCall call) async {
            calls.add(call);
            return null;
          });

      container = ProviderContainer(
        overrides: [
          arChannelProvider.overrideWithValue(
            ArChannel(method: method, event: event),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
    });

    test('build() starts at mode auto, active false, no latest', () {
      final state = container.read(arControllerProvider);

      expect(state.mode, ArMode.auto);
      expect(state.active, isFalse);
      expect(state.latest, isNull);
    });

    test(
      'A4: setMode(manual) updates state.mode AND calls channel.setMode',
      () async {
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        expect(container.read(arControllerProvider).mode, ArMode.manual);

        // Let the fire-and-forget invokeMethod call settle.
        await Future<void>.delayed(Duration.zero);

        expect(calls, hasLength(1));
        expect(calls.single.method, 'setMode');
        expect(calls.single.arguments, <String, Object?>{'mode': 'manual'});
      },
    );

    test('A4: onAlignment(a) sets state.latest', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{
        'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        'confidence': 0.7,
        'tracking': true,
      });

      container.read(arControllerProvider.notifier).onAlignment(alignment);

      expect(container.read(arControllerProvider).latest, alignment);
    });

    test('A4: markActive(true) sets active', () {
      container.read(arControllerProvider.notifier).markActive(true);

      expect(container.read(arControllerProvider).active, isTrue);

      container.read(arControllerProvider.notifier).markActive(false);

      expect(container.read(arControllerProvider).active, isFalse);
    });
  });
}
