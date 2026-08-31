import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_set.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';

/// A wall can hold more than one rock. What is worth pinning here is the two
/// things that could quietly corrupt a topo drawn before it could: the stored
/// shape stays readable by builds that know nothing about several rocks, and
/// a pin written when there was one rock still means what it meant.
void main() {
  Baseline square(double cx, double cy, {double r = 5}) => Baseline(
    [
      LayoutPoint(cx - r, cy - r),
      LayoutPoint(cx + r, cy - r),
      LayoutPoint(cx + r, cy + r),
      LayoutPoint(cx - r, cy + r),
    ],
    closed: true,
  );

  final strip = Baseline(const [LayoutPoint(0, 0), LayoutPoint(20, 0)]);

  group('BaselineSet storage', () {
    test('one rock is written in the LEGACY shape, byte for byte', () {
      // The column syncs. An older build reading this row has to find
      // something it understands, and for the single-rock wall — nearly all
      // of them — it must be exactly what it used to write.
      expect(BaselineSet.one(strip).encode(), strip.encode());
    });

    test('a legacy string decodes as a set of one', () {
      final set = BaselineSet.decode(strip.encode());
      expect(set, isNotNull);
      expect(set!.length, 1);
      expect(set.primary.points, strip.points);
    });

    test('several rocks round-trip', () {
      final set = BaselineSet([square(0, 0), square(40, 0), strip]);
      final back = BaselineSet.decode(set.encode());
      expect(back, isNotNull);
      expect(back!.length, 3);
      expect(back.strokes[1].centroid.x, closeTo(40, 0.01));
      expect(back.strokes[2].closed, isFalse);
    });

    test('rubbish decodes to null rather than throwing', () {
      expect(BaselineSet.decode('{"nope":1}'), isNull);
      expect(BaselineSet.decode(''), isNull);
      expect(BaselineSet.decode(null), isNull);
    });

    test('a degenerate stroke is dropped, never stored', () {
      final set = BaselineSet([strip, Baseline(const [LayoutPoint(1, 1)])]);
      expect(set.length, 1);
    });
  });

  group('BaselineSet pins', () {
    test('a one-rock wall passes the pin through untouched', () {
      // The end of an open line is t == 1.0 exactly. Interpreting the integer
      // part of THAT as "rock 1" would move every pin a contributor ever
      // dropped at the far end of a wall.
      expect(BaselineSet.unpack(1, 1), (stroke: 0, t: 1.0));
      expect(BaselineSet.unpack(0.25, 1), (stroke: 0, t: 0.25));
    });

    test('a pin names a rock and a place on it', () {
      final packed = BaselineSet.pack(2, 0.75);
      final back = BaselineSet.unpack(packed, 4);
      expect(back.stroke, 2);
      expect(back.t, closeTo(0.75, 1e-9));
    });

    test('a pin can never land on the NEXT rock\'s zero', () {
      final packed = BaselineSet.pack(1, 1);
      expect(BaselineSet.unpack(packed, 3).stroke, 1);
      expect(BaselineSet.unpack(packed, 3).t, greaterThan(0.99));
    });

    test('a pin naming a rock that is gone lands on the last one', () {
      expect(BaselineSet.unpack(BaselineSet.pack(7, 0.5), 2).stroke, 1);
    });
  });

  group('resolveLayoutSet', () {
    FaceInput face(String id, int order, {double? pin, double? lat}) =>
        FaceInput(
          id: id,
          captureOrder: order,
          pinnedT: pin,
          latitude: lat,
          longitude: lat == null ? null : 12.0,
          gpsAccuracyMeters: lat == null ? null : 4,
        );

    test('with one rock it takes the OLD path exactly', () {
      final single = resolveLayout(
        faces: [face('a', 0), face('b', 1)],
        baseline: strip,
      );
      final viaSet = resolveLayoutSet(
        faces: [face('a', 0), face('b', 1)],
        strokes: BaselineSet.one(strip),
      );
      expect(viaSet.faces.map((f) => f.t), single.faces.map((f) => f.t));
      expect(viaSet.faces.every((f) => f.stroke == 0), isTrue);
    });

    test('a pinned face rides the rock its pin names', () {
      final layout = resolveLayoutSet(
        faces: [
          face('a', 0),
          face('b', 1, pin: BaselineSet.pack(1, 0.5)),
        ],
        strokes: BaselineSet([square(0, 0), square(40, 0)]),
      );
      expect(layout.positionOf('b')!.stroke, 1);
      expect(layout.positionOf('b')!.t, closeTo(0.5, 1e-9));
      expect(
        layout.positionOf('a')!.stroke,
        0,
        reason: 'nothing says otherwise, so it stays on the first rock',
      );
    });

    test('every rock survives, including one nobody has photographed', () {
      final layout = resolveLayoutSet(
        faces: [face('a', 0)],
        strokes: BaselineSet([square(0, 0), square(40, 0)]),
      );
      expect(
        layout.strokes.length,
        2,
        reason: 'a rock with no photos is still a rock — dropping it would '
            'make it vanish the moment its last photo moved away',
      );
      expect(layout.normalSigns.length, 2);
    });

    test('faces come back in CAPTURE order, not grouped by rock', () {
      final layout = resolveLayoutSet(
        faces: [
          face('a', 0),
          face('b', 1, pin: BaselineSet.pack(1, 0.5)),
          face('c', 2),
        ],
        strokes: BaselineSet([square(0, 0), square(40, 0)]),
      );
      expect(
        layout.faces.map((f) => f.id),
        ['a', 'b', 'c'],
        reason: 'the rail pages through this list, and it is the order the '
            'photos were taken in',
      );
    });

    test('each face reports the rock it rides, and strokeFor finds it', () {
      final strokes = BaselineSet([square(0, 0), square(40, 0)]);
      final layout = resolveLayoutSet(
        faces: [face('a', 0), face('b', 1, pin: BaselineSet.pack(1, 0.25))],
        strokes: strokes,
      );
      final b = layout.positionOf('b')!;
      expect(layout.strokeFor(b).centroid.x, closeTo(40, 0.01));
    });
  });
}
