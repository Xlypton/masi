
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart' show ArPlacementEngine;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArAlignment', () {
    test(
      'A2: fromMap parses a well-formed map into confidence/tracking',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'confidence': 0.8,
          'tracking': true,
        });

        expect(alignment.confidence, 0.8);
        expect(alignment.tracking, isTrue);
      },
    );

    test('A3: fromMap({}) defaults to 0.0/false, no throw', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{});

      expect(alignment.confidence, 0.0);
      expect(alignment.tracking, isFalse);
    });

    test(
      'NEW contract: a payload WITH corners+tracking parses both instead of '
      'collapsing to the full default',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'corners': <double>[50, 50, 350, 50, 350, 750, 50, 750],
        });

        expect(alignment.tracking, isTrue);
        expect(alignment.screenCorners, const <Offset>[
          Offset(50, 50),
          Offset(350, 50),
          Offset(350, 750),
          Offset(50, 750),
        ]);
        expect(
          alignment,
          isNot(ArAlignment.fromMap(const <String, Object?>{})),
          reason:
              'must not collapse to the fully-default alignment just '
              'because tracking/corners are the only fields present',
        );
      },
    );

    test('fromMap parses an 8-entry corners list into 4 screenCorners', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{
        'tracking': true,
        'corners': <double>[1, 2, 3, 4, 5, 6, 7, 8],
      });

      expect(alignment.screenCorners, const <Offset>[
        Offset(1, 2),
        Offset(3, 4),
        Offset(5, 6),
        Offset(7, 8),
      ]);
    });

    test('fromMap with no corners leaves screenCorners null', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{
        'tracking': false,
      });

      expect(alignment.screenCorners, isNull);
    });

    test(
      'fromMap with a corners list of the wrong length leaves screenCorners '
      'null, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'corners': <double>[1, 2, 3],
        });

        expect(alignment.screenCorners, isNull);
      },
    );

    test(
      'fromMap with a corners list containing a non-numeric entry leaves '
      'screenCorners null, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'corners': <Object?>[1, 2, 3, 4, 5, 6, 7, 'nope'],
        });

        expect(alignment.screenCorners, isNull);
      },
    );

    test(
      'fromMap with a non-list corners value leaves screenCorners null, no '
      'throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'corners': 'nope',
        });

        expect(alignment.screenCorners, isNull);
      },
    );

    test('equality/hashCode are value-based', () {
      final a = ArAlignment.fromMap(<String, Object?>{
        'confidence': 0.8,
        'tracking': true,
      });
      final b = ArAlignment.fromMap(<String, Object?>{
        'confidence': 0.8,
        'tracking': true,
      });
      final c = ArAlignment.fromMap(<String, Object?>{
        'confidence': 0.1,
        'tracking': true,
      });

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith overrides only the given fields', () {
      const original = ArAlignment(
        confidence: 0.5,
        tracking: true,
        screenCorners: <Offset>[
          Offset(1, 1),
          Offset(2, 2),
          Offset(3, 3),
          Offset(4, 4),
        ],
        trackingState: ArTrackingState.limited,
        limitedReason: 'excessiveMotion',
      );

      final withNewCorners = original.copyWith(
        screenCorners: const <Offset>[
          Offset(9, 9),
          Offset(9, 9),
          Offset(9, 9),
          Offset(9, 9),
        ],
      );

      expect(withNewCorners.confidence, 0.5);
      expect(withNewCorners.tracking, isTrue);
      expect(withNewCorners.trackingState, ArTrackingState.limited);
      expect(withNewCorners.limitedReason, 'excessiveMotion');
      expect(withNewCorners.screenCorners, const <Offset>[
        Offset(9, 9),
        Offset(9, 9),
        Offset(9, 9),
        Offset(9, 9),
      ]);
    });
  });

  group('ArTrackingState / derivedConfidence (A1 real-confidence contract)', () {
    test(
      'A1-A4: fromMap with no trackingState field defaults to normal -- '
      'backward-compatible with pre-A1 native payloads that never sent it',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'corners': <double>[50, 50, 350, 50, 350, 750, 50, 750],
        });

        expect(alignment.trackingState, ArTrackingState.normal);
        expect(alignment.limitedReason, isNull);
        expect(
          alignment.derivedConfidence,
          1.0,
          reason:
              'absent trackingState must behave exactly like today: full '
              'confidence whenever the payload has no opinion on tracking '
              'quality',
        );
      },
    );

    test('fromMap parses a well-formed trackingState + limitedReason', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{
        'tracking': true,
        'trackingState': 'limited',
        'limitedReason': 'insufficientFeatures',
      });

      expect(alignment.trackingState, ArTrackingState.limited);
      expect(alignment.limitedReason, 'insufficientFeatures');
    });

    test(
      'fromMap with an unrecognized trackingState string falls back to '
      'normal, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'trackingState': 'some-future-arkit-state-we-dont-know-about',
        });

        expect(alignment.trackingState, ArTrackingState.normal);
      },
    );

    test(
      'fromMap with a non-string trackingState falls back to normal, no '
      'throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'trackingState': 42,
        });

        expect(alignment.trackingState, ArTrackingState.normal);
      },
    );

    test(
      'fromMap with a non-string limitedReason leaves it null, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'tracking': true,
          'trackingState': 'limited',
          'limitedReason': 7,
        });

        expect(alignment.limitedReason, isNull);
      },
    );

    test(
      'A1-A3: confidenceForTrackingState maps every state per the documented '
      'contract',
      () {
        expect(confidenceForTrackingState(ArTrackingState.normal), 1.0);
        expect(confidenceForTrackingState(ArTrackingState.limited), 0.35);
        expect(confidenceForTrackingState(ArTrackingState.notAvailable), 0.1);
        expect(confidenceForTrackingState(ArTrackingState.initializing), 0.1);
        expect(confidenceForTrackingState(ArTrackingState.relocalizing), 0.1);
      },
    );

    test(
      'ArAlignment.derivedConfidence delegates to confidenceForTrackingState '
      'for every state',
      () {
        for (final state in ArTrackingState.values) {
          final alignment = ArAlignment(
            confidence: 0.0, // deliberately irrelevant -- derivedConfidence
            // must never read this dead field.
            tracking: true,
            trackingState: state,
          );
          expect(
            alignment.derivedConfidence,
            confidenceForTrackingState(state),
            reason: 'state=$state',
          );
        }
      },
    );

    test(
      'A1-A3: below-threshold states (limited/notAvailable/initializing/'
      'relocalizing) all produce a confidence under the painter\'s '
      'kLowConfidenceThreshold (0.4), so the low-confidence fade fires',
      () {
        for (final state in <ArTrackingState>[
          ArTrackingState.limited,
          ArTrackingState.notAvailable,
          ArTrackingState.initializing,
          ArTrackingState.relocalizing,
        ]) {
          expect(
            confidenceForTrackingState(state),
            lessThan(0.4),
            reason: 'state=$state',
          );
        }
        expect(confidenceForTrackingState(ArTrackingState.normal), greaterThanOrEqualTo(0.4));
      },
    );

    test(
      'ArTrackingState.fromWire parses every documented wire string',
      () {
        expect(ArTrackingState.fromWire('normal'), ArTrackingState.normal);
        expect(ArTrackingState.fromWire('limited'), ArTrackingState.limited);
        expect(
          ArTrackingState.fromWire('notAvailable'),
          ArTrackingState.notAvailable,
        );
        expect(
          ArTrackingState.fromWire('initializing'),
          ArTrackingState.initializing,
        );
        expect(
          ArTrackingState.fromWire('relocalizing'),
          ArTrackingState.relocalizing,
        );
      },
    );

    test(
      'ArTrackingState.fromWire falls back to normal for null/malformed '
      'input',
      () {
        expect(ArTrackingState.fromWire(null), ArTrackingState.normal);
        expect(ArTrackingState.fromWire(42), ArTrackingState.normal);
        expect(ArTrackingState.fromWire('nonsense'), ArTrackingState.normal);
      },
    );

    group('#66: numeric engine confidence lowers derivedConfidence', () {
      test(
        'confidence: 0 (the fromMap default/absent case) leaves the band '
        'value completely unchanged -- the ARKit path (which never sends '
        'confidence) must be byte-for-byte identical to before #66',
        () {
          final alignment = ArAlignment.fromMap(<String, Object?>{
            'tracking': true,
            'trackingState': 'normal',
          });

          expect(alignment.confidence, 0.0);
          expect(alignment.derivedConfidence, 1.0);
        },
      );

      test(
        'a low numeric confidence (0.2) pulls a normal band (1.0) DOWN to '
        'the reported confidence',
        () {
          const alignment = ArAlignment(
            confidence: 0.2,
            tracking: true,
            trackingState: ArTrackingState.normal,
          );

          expect(alignment.derivedConfidence, 0.2);
        },
      );

      test(
        'a high numeric confidence (0.9) can never raise a limited band '
        '(0.35) above what the tracking-state band already allows -- min() '
        'never lets confidence pull the value UP',
        () {
          const alignment = ArAlignment(
            confidence: 0.9,
            tracking: true,
            trackingState: ArTrackingState.limited,
          );

          expect(alignment.derivedConfidence, 0.35);
        },
      );

      test(
        'fromMap parses a numeric confidence field as a double',
        () {
          final alignment = ArAlignment.fromMap(<String, Object?>{
            'tracking': true,
            'confidence': 0.42,
          });

          expect(alignment.confidence, 0.42);
        },
      );

      test(
        'fromMap defaults a missing confidence field to 0.0',
        () {
          final alignment = ArAlignment.fromMap(<String, Object?>{
            'tracking': true,
          });

          expect(alignment.confidence, 0.0);
        },
      );
    });
  });

  group('ArChannel', () {
    const method = MethodChannel('masi/ar');
    const event = EventChannel('masi/ar/alignment');

    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (MethodCall call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(event, null);
    });

    test(
      'A1/#66: start() invokes "start" with the 3 original args plus '
      '"engine" (default arkit), no rockQuad when omitted',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
        );

        expect(calls, hasLength(1));
        expect(calls.single.method, 'start');
        expect(calls.single.arguments, <String, Object?>{
          'referenceImagePath': '/p.jpg',
          'refWidth': 1000,
          'refHeight': 800,
          'engine': 'arkit',
        });
      },
    );

    test(
      '#66: start() sends the non-default engine.name as the wire value',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
          engine: ArPlacementEngine.vision,
        );

        expect(calls.single.arguments, <String, Object?>{
          'referenceImagePath': '/p.jpg',
          'refWidth': 1000,
          'refHeight': 800,
          'engine': 'vision',
        });
      },
    );

    test(
      '#66: start() includes rockQuad only when it has exactly 8 entries',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
          engine: ArPlacementEngine.orb,
          rockQuad: const <double>[0.1, 0.1, 0.9, 0.1, 0.9, 0.9, 0.1, 0.9],
        );

        expect(calls.single.arguments, <String, Object?>{
          'referenceImagePath': '/p.jpg',
          'refWidth': 1000,
          'refHeight': 800,
          'engine': 'orb',
          'rockQuad': const <double>[0.1, 0.1, 0.9, 0.1, 0.9, 0.9, 0.1, 0.9],
        });
      },
    );

    test(
      '#66: start() omits rockQuad entirely (never sends it as null or a '
      'wrong-length list) when the quad is null',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
          rockQuad: null,
        );

        final args = calls.single.arguments as Map<Object?, Object?>;
        expect(args.containsKey('rockQuad'), isFalse);
      },
    );

    test(
      '#66: start() omits rockQuad when it does not have exactly 8 entries',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
          rockQuad: const <double>[0.1, 0.1, 0.9],
        );

        final args = calls.single.arguments as Map<Object?, Object?>;
        expect(args.containsKey('rockQuad'), isFalse);
      },
    );

    group('start() returns native\'s {success} bool', () {
      test('success: true -> returns true', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(method, (MethodCall call) async {
              calls.add(call);
              return <String, Object?>{'success': true};
            });
        final channel = ArChannel(method: method, event: event);

        final result = await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
        );

        expect(result, isTrue);
      });

      test('success: false -> returns false', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(method, (MethodCall call) async {
              calls.add(call);
              return <String, Object?>{'success': false};
            });
        final channel = ArChannel(method: method, event: event);

        final result = await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
        );

        expect(result, isFalse);
      });

      test(
        'a non-Map result (e.g. a legacy bare bool) -> false, no throw',
        () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(method, (MethodCall call) async {
                calls.add(call);
                return true;
              });
          final channel = ArChannel(method: method, event: event);

          final result = await channel.start(
            referenceImagePath: '/p.jpg',
            refWidth: 1000,
            refHeight: 800,
          );

          expect(result, isFalse);
        },
      );

      test(
        'a null result (the default mock handler in setUp) -> false, no '
        'throw',
        () async {
          final channel = ArChannel(method: method, event: event);

          final result = await channel.start(
            referenceImagePath: '/p.jpg',
            refWidth: 1000,
            refHeight: 800,
          );

          expect(result, isFalse);
        },
      );

      test('a Map with a non-bool success value -> false, no throw', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(method, (MethodCall call) async {
              calls.add(call);
              return <String, Object?>{'success': 'nope'};
            });
        final channel = ArChannel(method: method, event: event);

        final result = await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
        );

        expect(result, isFalse);
      });
    });

    test('A1: stop() invokes "stop"', () async {
      final channel = ArChannel(method: method, event: event);

      await channel.stop();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'stop');
    });

    test('rescan() invokes "rescan" with no args', () async {
      final channel = ArChannel(method: method, event: event);

      await channel.rescan();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'rescan');
      expect(calls.single.arguments, isNull);
    });

    test(
      'A1: setMode(manual) invokes "setMode" with {mode: manual}',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.setMode(ArMode.manual);

        expect(calls, hasLength(1));
        expect(calls.single.method, 'setMode');
        expect(calls.single.arguments, <String, Object?>{'mode': 'manual'});
      },
    );

    test(
      'A1: setMode(auto) invokes "setMode" with {mode: auto}',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.setMode(ArMode.auto);

        expect(calls, hasLength(1));
        expect(calls.single.method, 'setMode');
        expect(calls.single.arguments, <String, Object?>{'mode': 'auto'});
      },
    );

    test(
      'lockManual(corners) invokes "lockManual" with the 4 corners '
      'flattened into 8 doubles in order, and resolves to true when native '
      'reports a successful pin',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(method, (MethodCall call) async {
              calls.add(call);
              return true;
            });
        final channel = ArChannel(method: method, event: event);

        final ok = await channel.lockManual(const <Offset>[
          Offset(1, 2),
          Offset(3, 4),
          Offset(5, 6),
          Offset(7, 8),
        ]);

        expect(ok, isTrue);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'lockManual');
        expect(calls.single.arguments, <String, Object?>{
          'corners': <double>[1, 2, 3, 4, 5, 6, 7, 8],
        });
      },
    );

    test(
      'lockManual(corners) resolves to false when native reports it could '
      'not pin (returns false)',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(method, (MethodCall call) async {
              calls.add(call);
              return false;
            });
        final channel = ArChannel(method: method, event: event);

        final ok = await channel.lockManual(const <Offset>[
          Offset(1, 2),
          Offset(3, 4),
          Offset(5, 6),
          Offset(7, 8),
        ]);

        expect(ok, isFalse);
        expect(calls, hasLength(1));
      },
    );

    test(
      'lockManual(corners) resolves to false when native returns null '
      '(the default mock handler in setUp)',
      () async {
        final channel = ArChannel(method: method, event: event);

        final ok = await channel.lockManual(const <Offset>[
          Offset(1, 2),
          Offset(3, 4),
          Offset(5, 6),
          Offset(7, 8),
        ]);

        expect(ok, isFalse);
        expect(calls, hasLength(1));
      },
    );

    test('unlockManual() invokes "unlockManual" with no args', () async {
      final channel = ArChannel(method: method, event: event);

      await channel.unlockManual();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'unlockManual');
      expect(calls.single.arguments, isNull);
    });

    test(
      'alignments() maps well-formed broadcast events into ArAlignment',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              event,
              _StubStreamHandler(<Object?>[
                <String, Object?>{'confidence': 0.9, 'tracking': true},
              ]),
            );

        final channel = ArChannel(method: method, event: event);

        final alignment = await channel.alignments().first;

        expect(alignment.confidence, 0.9);
        expect(alignment.tracking, isTrue);
      },
    );

    test(
      'A3: alignments() guards a non-map event, defaulting instead of throwing',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              event,
              _StubStreamHandler(<Object?>['not-a-map']),
            );

        final channel = ArChannel(method: method, event: event);

        final alignment = await channel.alignments().first;

        expect(alignment.confidence, 0.0);
        expect(alignment.tracking, isFalse);
      },
    );
  });
}

/// A minimal [MockStreamHandler] that emits each of [events] in order to a
/// single listener, used to drive [EventChannel.receiveBroadcastStream] in
/// tests deterministically.
class _StubStreamHandler extends MockStreamHandler {
  _StubStreamHandler(this.events);

  final List<Object?> events;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) {
    for (final event in this.events) {
      events.success(event);
    }
  }

  @override
  void onCancel(Object? arguments) {}
}
