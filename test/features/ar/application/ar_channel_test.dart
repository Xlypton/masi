import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/domain/homography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArAlignment', () {
    test(
      'A2: fromMap parses a well-formed map into homography/confidence/tracking',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
          'confidence': 0.8,
          'tracking': true,
        });

        expect(alignment.homography.toRowMajor(), <double>[
          1,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
        ]);
        expect(alignment.confidence, 0.8);
        expect(alignment.tracking, isTrue);
      },
    );

    test('A3: fromMap({}) defaults to identity/0.0/false, no throw', () {
      final alignment = ArAlignment.fromMap(<String, Object?>{});

      expect(alignment.homography, Homography.identity());
      expect(alignment.confidence, 0.0);
      expect(alignment.tracking, isFalse);
    });

    test(
      'A3: fromMap with a short homography list defaults, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'homography': <double>[1, 2, 3],
          'confidence': 0.5,
          'tracking': true,
        });

        expect(alignment.homography, Homography.identity());
        expect(alignment.confidence, 0.0);
        expect(alignment.tracking, isFalse);
      },
    );

    test(
      'A3: fromMap with a non-numeric homography defaults, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'homography': 'x',
          'confidence': 0.5,
          'tracking': true,
        });

        expect(alignment.homography, Homography.identity());
        expect(alignment.confidence, 0.0);
        expect(alignment.tracking, isFalse);
      },
    );

    test(
      'A3: fromMap with a homography list containing non-numeric entries defaults, no throw',
      () {
        final alignment = ArAlignment.fromMap(<String, Object?>{
          'homography': <Object?>[1, 0, 0, 0, 1, 0, 0, 0, 'nope'],
          'confidence': 0.5,
          'tracking': true,
        });

        expect(alignment.homography, Homography.identity());
        expect(alignment.confidence, 0.0);
        expect(alignment.tracking, isFalse);
      },
    );

    test('equality/hashCode are value-based', () {
      final a = ArAlignment.fromMap(<String, Object?>{
        'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        'confidence': 0.8,
        'tracking': true,
      });
      final b = ArAlignment.fromMap(<String, Object?>{
        'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        'confidence': 0.8,
        'tracking': true,
      });
      final c = ArAlignment.fromMap(<String, Object?>{
        'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        'confidence': 0.1,
        'tracking': true,
      });

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ArChannel', () {
    const method = MethodChannel('climbtopo/ar');
    const event = EventChannel('climbtopo/ar/alignment');

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
      'A1: start() invokes "start" with exactly the 4 documented args',
      () async {
        final channel = ArChannel(method: method, event: event);

        await channel.start(
          referenceImagePath: '/p.jpg',
          refWidth: 1000,
          refHeight: 800,
          routesJson: '[]',
        );

        expect(calls, hasLength(1));
        expect(calls.single.method, 'start');
        expect(calls.single.arguments, <String, Object?>{
          'referenceImagePath': '/p.jpg',
          'refWidth': 1000,
          'refHeight': 800,
          'routesJson': '[]',
        });
      },
    );

    test('A1: stop() invokes "stop"', () async {
      final channel = ArChannel(method: method, event: event);

      await channel.stop();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'stop');
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
      'alignments() maps well-formed broadcast events into ArAlignment',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              event,
              _StubStreamHandler(<Object?>[
                <String, Object?>{
                  'homography': <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
                  'confidence': 0.9,
                  'tracking': true,
                },
              ]),
            );

        final channel = ArChannel(method: method, event: event);

        final alignment = await channel.alignments().first;

        expect(alignment.confidence, 0.9);
        expect(alignment.tracking, isTrue);
        expect(alignment.homography.toRowMajor(), <double>[
          1,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
        ]);
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

        expect(alignment.homography, Homography.identity());
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
