import 'dart:async';
import 'dart:ui' as ui;

import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/domain/corner_smoother.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decodes a tiny 1x1 RGBA image, for tests that need a real (non-null)
/// `ui.Image` to stand in for a decoded rock mask.
Future<ui.Image> _createTinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(<int>[0, 229, 255, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArState', () {
    test('copyWith overrides only the given fields', () {
      const initial = ArState(mode: ArMode.auto, active: false);
      final alignment = ArAlignment(
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

    group('rockQuadPercent', () {
      const quad = <Offset>[
        Offset(0.1, 0.1),
        Offset(0.9, 0.1),
        Offset(0.9, 0.9),
        Offset(0.1, 0.9),
      ];

      test('defaults to null', () {
        const state = ArState(mode: ArMode.auto, active: false);
        expect(state.rockQuadPercent, isNull);
      });

      test('copyWith sets it when given a value', () {
        const state = ArState(mode: ArMode.auto, active: false);
        final withQuad = state.copyWith(rockQuadPercent: quad);
        expect(withQuad.rockQuadPercent, quad);
      });

      test(
        'equality/hashCode treat two states with equal (but distinct) '
        'quad lists as equal, and a differing quad as unequal',
        () {
          const a = ArState(
            mode: ArMode.auto,
            active: false,
            rockQuadPercent: quad,
          );
          const b = ArState(
            mode: ArMode.auto,
            active: false,
            rockQuadPercent: <Offset>[
              Offset(0.1, 0.1),
              Offset(0.9, 0.1),
              Offset(0.9, 0.9),
              Offset(0.1, 0.9),
            ],
          );
          const c = ArState(mode: ArMode.auto, active: false);

          expect(a, b);
          expect(a.hashCode, b.hashCode);
          expect(a, isNot(c));
        },
      );
    });
  });

  group('ArController', () {
    const method = MethodChannel('masi/ar');
    const event = EventChannel('masi/ar/alignment');

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
      expect(state.rockQuadPercent, isNull);
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

    test(
      'setMode always resets arLockedProvider back to unlocked, so '
      'switching modes never leaves a stale lock behind',
      () {
        container.read(arLockedProvider.notifier).toggle();
        expect(container.read(arLockedProvider), isTrue);

        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        expect(container.read(arLockedProvider), isFalse);
      },
    );

    test('A4: onAlignment(a) sets state.latest', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{
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

    group('B1/B3: setRockSegmentation', () {
      const quad = <Offset>[
        Offset(0.1, 0.1),
        Offset(0.9, 0.1),
        Offset(0.9, 0.9),
        Offset(0.1, 0.9),
      ];

      test('setRockSegmentation(quadPercent: quad) sets state.rockQuadPercent', () {
        container.read(arControllerProvider.notifier).setRockSegmentation(quadPercent: quad);

        expect(container.read(arControllerProvider).rockQuadPercent, quad);
      });

      test(
        'setRockSegmentation(quadPercent: null) after a previously-set quad '
        'ACTUALLY resets it back to null -- the copyWith-style `?? this.field` '
        'idiom every other nullable ArState field uses can never null out '
        'an already-set field, so this must not go through a naive '
        'state.copyWith(rockQuadPercent: null) call',
        () {
          container
              .read(arControllerProvider.notifier)
              .setRockSegmentation(quadPercent: quad);
          expect(container.read(arControllerProvider).rockQuadPercent, quad);

          container.read(arControllerProvider.notifier).setRockSegmentation(quadPercent: null);

          expect(
            container.read(arControllerProvider).rockQuadPercent,
            isNull,
          );
        },
      );

      test('setRockSegmentation(mask: img) sets state.rockMask', () async {
        final mask = await _createTinyImage();
        addTearDown(mask.dispose);

        container
            .read(arControllerProvider.notifier)
            .setRockSegmentation(mask: mask);

        expect(container.read(arControllerProvider).rockMask, same(mask));
      });

      test(
        'setRockSegmentation() with NO args resets BOTH quadPercent and mask '
        'back to null (the wall-switch reset path)',
        () async {
          final mask = await _createTinyImage();
          addTearDown(mask.dispose);
          container
              .read(arControllerProvider.notifier)
              .setRockSegmentation(quadPercent: quad, mask: mask);
          expect(container.read(arControllerProvider).rockQuadPercent, quad);
          expect(container.read(arControllerProvider).rockMask, same(mask));

          container.read(arControllerProvider.notifier).setRockSegmentation();

          expect(container.read(arControllerProvider).rockQuadPercent, isNull);
          expect(container.read(arControllerProvider).rockMask, isNull);
        },
      );

      test(
        'setRockSegmentation leaves every other ArState field untouched',
        () {
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);
          container.read(arControllerProvider.notifier).markActive(true);
          final alignment = ArAlignment.fromMap(<String, Object?>{
            'confidence': 0.7,
            'tracking': true,
          });
          container.read(arControllerProvider.notifier).onAlignment(alignment);

          container
              .read(arControllerProvider.notifier)
              .setRockSegmentation(quadPercent: quad);

          final state = container.read(arControllerProvider);
          expect(state.mode, ArMode.manual);
          expect(state.active, isTrue);
          expect(state.latest, alignment);
          expect(state.rockQuadPercent, quad);
        },
      );
    });

    group('A1: EMA corner smoothing (onAlignment)', () {
      const first = <Offset>[
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
      ];
      const second = <Offset>[
        Offset(20, 20),
        Offset(120, 20),
        Offset(120, 120),
        Offset(20, 120),
      ];

      test(
        'the first-ever tracked alignment stores its corners unchanged (no '
        'filter state to blend against yet)',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );

          expect(
            container.read(arControllerProvider).latest?.screenCorners,
            first,
          );
        },
      );

      test(
        'a second tracked alignment stores EMA-blended corners, not the raw '
        'new ones -- alpha * raw + (1 - alpha) * previous, per coordinate',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: second,
                ),
              );

          final smoothed = container
              .read(arControllerProvider)
              .latest!
              .screenCorners!;

          expect(smoothed, isNot(second));
          for (var i = 0; i < 4; i++) {
            final expectedX =
                kCornerSmoothingAlpha * second[i].dx +
                (1 - kCornerSmoothingAlpha) * first[i].dx;
            final expectedY =
                kCornerSmoothingAlpha * second[i].dy +
                (1 - kCornerSmoothingAlpha) * first[i].dy;
            expect(smoothed[i].dx, closeTo(expectedX, 1e-9), reason: 'corner $i dx');
            expect(smoothed[i].dy, closeTo(expectedY, 1e-9), reason: 'corner $i dy');
          }
        },
      );

      test(
        'other ArAlignment fields (confidence/tracking/trackingState/'
        'limitedReason) pass through unchanged alongside the smoothed '
        'corners',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: second,
                  trackingState: ArTrackingState.limited,
                  limitedReason: 'excessiveMotion',
                ),
              );

          final latest = container.read(arControllerProvider).latest!;
          expect(latest.tracking, isTrue);
          expect(latest.trackingState, ArTrackingState.limited);
          expect(latest.limitedReason, 'excessiveMotion');
        },
      );

      test(
        'A1: setMode resets the corner-smoothing filter -- an AR mode '
        'change is a documented discontinuity, so the next alignment after '
        'a mode switch is a fresh passthrough, not blended with pre-switch '
        'corners',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );

          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: second,
                ),
              );

          expect(
            container.read(arControllerProvider).latest?.screenCorners,
            second,
            reason:
                'after a mode change, the filter must have been reset, so '
                'this alignment passes through raw',
          );
        },
      );

      test(
        'A1: a tracking:false update resets the corner-smoothing filter, so '
        'a later re-acquisition starts fresh rather than blending against '
        'pre-loss corners',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );
          container
              .read(arControllerProvider.notifier)
              .onAlignment(const ArAlignment(confidence: 0.0, tracking: false));
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: second,
                ),
              );

          expect(
            container.read(arControllerProvider).latest?.screenCorners,
            second,
            reason:
                'tracking loss must have reset the filter, so the '
                're-acquired alignment passes through raw',
          );
        },
      );

      test(
        'resetCornerSmoothing() clears filter state directly (called by '
        'ArAlignmentStage on a fresh manual lock and by ArScreen on every '
        'wall entry)',
        () {
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: first,
                ),
              );

          container.read(arControllerProvider.notifier).resetCornerSmoothing();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: second,
                ),
              );

          expect(
            container.read(arControllerProvider).latest?.screenCorners,
            second,
          );
        },
      );
    });
  });

  group('ArLockedController', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('build() starts unlocked', () {
      expect(container.read(arLockedProvider), isFalse);
    });

    test('toggle() flips locked <-> unlocked', () {
      final notifier = container.read(arLockedProvider.notifier);

      notifier.toggle();
      expect(container.read(arLockedProvider), isTrue);

      notifier.toggle();
      expect(container.read(arLockedProvider), isFalse);
    });

    test('reset() returns to unlocked from either state', () {
      final notifier = container.read(arLockedProvider.notifier);

      notifier.reset();
      expect(container.read(arLockedProvider), isFalse);

      notifier.toggle();
      expect(container.read(arLockedProvider), isTrue);

      notifier.reset();
      expect(container.read(arLockedProvider), isFalse);
    });
  });

  group('ArRockHighlightController', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('build() starts off (false)', () {
      expect(container.read(arRockHighlightProvider), isFalse);
    });

    test('toggle() flips on <-> off', () {
      final notifier = container.read(arRockHighlightProvider.notifier);

      notifier.toggle();
      expect(container.read(arRockHighlightProvider), isTrue);

      notifier.toggle();
      expect(container.read(arRockHighlightProvider), isFalse);
    });
  });
}
