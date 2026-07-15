import 'package:climbtopo/features/ar/application/ar_channel.dart';
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
