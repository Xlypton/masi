import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_synthesis.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';

/// The acceptance tests from the Face Layout spec §7, plus the properties §5
/// promises the resolver holds.
///
/// Everything here is pure Dart against hand-built inputs — no Drift, no
/// widgets, no `Future`. That is the point of workstream B being split out:
/// the rules that decide where a photo sits are checkable without booting an
/// app, so a regression in them fails in milliseconds rather than in a driven
/// browser test.
void main() {
  const double centreLat = 47.0;
  const double centreLon = 12.0;
  const double metresPerDegreeLat = 111320.0;

  double lonPerMetre(double lat) =>
      1 / (metresPerDegreeLat * math.cos(lat * math.pi / 180.0));

  /// A camera standing [radius] m from the centre at compass angle [angle],
  /// pointing back at it — i.e. one face of a boulder.
  FaceInput cameraAround({
    required String id,
    required int order,
    required double angle,
    double radius = 6,
    double accuracy = 4,
    bool gps = true,
    bool bearing = true,
    double latOffsetMetres = 0,
  }) {
    final radians = angle * math.pi / 180.0;
    final east = math.sin(radians) * radius;
    final north = math.cos(radians) * radius + latOffsetMetres;
    return FaceInput(
      id: id,
      captureOrder: order,
      latitude: gps ? centreLat + north / metresPerDegreeLat : null,
      longitude: gps ? centreLon + east * lonPerMetre(centreLat) : null,
      gpsAccuracyMeters: gps ? accuracy : null,
      // Looking at the centre is the reciprocal of where you stand.
      bearingDegrees: bearing ? (angle + 180) % 360 : null,
    );
  }

  /// A camera on a straight walking line, looking north at the wall.
  FaceInput cameraAlongWall({
    required String id,
    required int order,
    required double eastMetres,
    double accuracy = 4,
    bool gps = true,
    bool bearing = true,
  }) => FaceInput(
    id: id,
    captureOrder: order,
    latitude: gps ? centreLat : null,
    longitude: gps ? centreLon + eastMetres * lonPerMetre(centreLat) : null,
    gpsAccuracyMeters: gps ? accuracy : null,
    bearingDegrees: bearing ? 0 : null,
  );

  List<FaceInput> boulder({int sides = 4, bool gps = true, bool bearing = true}) => [
    for (var i = 0; i < sides; i++)
      cameraAround(
        id: 'f$i',
        order: i,
        angle: 360.0 * i / 4,
        gps: gps,
        bearing: bearing,
      ),
  ];

  /// Asserts the faces advance forward along the line without ever going
  /// backwards relative to capture order — §5's monotonicity invariant.
  void expectForwardOrder(LayoutResult result) {
    final faces = result.faces;
    for (var i = 1; i < faces.length; i++) {
      final delta = result.baseline.closed
          ? (faces[i].t - faces[i - 1].t) % 1.0
          : faces[i].t - faces[i - 1].t;
      expect(
        delta,
        greaterThanOrEqualTo(-1e-9),
        reason: 'face ${faces[i].id} sits before its predecessor',
      );
    }
  }

  group('Baseline geometry', () {
    test('parameterises an open line by arc length', () {
      final line = Baseline(const [
        LayoutPoint(0, 0),
        LayoutPoint(10, 0),
        LayoutPoint(10, 10),
      ]);
      expect(line.totalLength, closeTo(20, 1e-9));
      expect(line.pointAt(0).x, closeTo(0, 1e-9));
      expect(line.pointAt(0.5).x, closeTo(10, 1e-9));
      expect(line.pointAt(0.5).y, closeTo(0, 1e-9));
      expect(line.pointAt(1).y, closeTo(10, 1e-9));
    });

    test('wraps t on a closed line and clamps it on an open one', () {
      final ring = Baseline(const [
        LayoutPoint(0, 0),
        LayoutPoint(10, 0),
        LayoutPoint(10, 10),
      ], closed: true);
      expect(ring.closed, isTrue);
      expect(ring.normalizeT(1.25), closeTo(0.25, 1e-9));
      expect(ring.normalizeT(-0.25), closeTo(0.75, 1e-9));
      // The short way round from 0.9 to 0.1 is forwards, not backwards.
      expect(ring.signedDelta(0.9, 0.1), closeTo(0.2, 1e-9));

      final strip = Baseline(const [LayoutPoint(0, 0), LayoutPoint(10, 0)]);
      expect(strip.normalizeT(1.25), 1.0);
      expect(strip.normalizeT(-0.25), 0.0);
    });

    test('a two-point stroke cannot be closed', () {
      final line = Baseline(const [
        LayoutPoint(0, 0),
        LayoutPoint(10, 0),
      ], closed: true);
      expect(line.closed, isFalse);
    });

    test('projects a point onto the nearest place on the line', () {
      final line = Baseline(const [LayoutPoint(0, 0), LayoutPoint(100, 0)]);
      final hit = line.project(const LayoutPoint(25, 7));
      expect(hit.t, closeTo(0.25, 1e-9));
      expect(hit.distance, closeTo(7, 1e-9));
    });

    test('round-trips through JSON and refuses anything else', () {
      final line = Baseline(const [
        LayoutPoint(1.5, -2.25),
        LayoutPoint(4, 8),
        LayoutPoint(-3, 6),
      ], closed: true);
      final back = Baseline.decode(line.encode())!;
      expect(back.closed, isTrue);
      expect(back.points.length, line.points.length);
      expect(back.points.first.x, closeTo(1.5, 1e-6));

      expect(Baseline.decode(null), isNull);
      expect(Baseline.decode(''), isNull);
      expect(Baseline.decode('not json'), isNull);
      expect(Baseline.decode('{"v":99,"pts":[[0,0],[1,1]]}'), isNull);
      expect(Baseline.decode('{"v":1,"pts":[[0,0]]}'), isNull);
      expect(Baseline.decode('{"v":1,"pts":[["a","b"],[1,1]]}'), isNull);
    });

    test('simplification drops points a stroke does not need', () {
      final wobbly = Baseline([
        for (var i = 0; i <= 100; i++) LayoutPoint(i.toDouble(), 0),
      ]);
      expect(wobbly.simplified(0.01).points.length, 2);
    });
  });

  group('§7.1 four photos of a boulder, good sensors', () {
    test('produces a closed line with four faces in order', () {
      final result = resolveLayout(faces: boulder());

      expect(result.isLoop, isTrue, reason: 'a walked-round boulder is a ring');
      expect(result.origin, BaselineOrigin.gpsTrack);
      expect(result.faces.map((f) => f.id), ['f0', 'f1', 'f2', 'f3']);
      expectForwardOrder(result);
    });

    test('classifies the cameras as looking inward', () {
      expect(resolveLayout(faces: boulder()).orientation,
          LayoutOrientation.inward);
    });

    test('cameras standing inside and looking out are an amphitheatre', () {
      final faces = [
        for (var i = 0; i < 6; i++)
          FaceInput(
            id: 'a$i',
            captureOrder: i,
            // Standing on a small ring in the middle, shooting outward.
            latitude: centreLat +
                math.cos(i * 60 * math.pi / 180) * 6 / metresPerDegreeLat,
            longitude: centreLon +
                math.sin(i * 60 * math.pi / 180) * 6 * lonPerMetre(centreLat),
            gpsAccuracyMeters: 4,
            bearingDegrees: (i * 60.0) % 360,
          ),
      ];
      expect(resolveLayout(faces: faces).orientation,
          LayoutOrientation.outward);
    });
  });

  group('§7.2 the same photos with every sensor stripped', () {
    test('still produces an ordered, usable strip', () {
      final result =
          resolveLayout(faces: boulder(gps: false, bearing: false));

      expect(result.isLoop, isFalse, reason: 'a strip is the safe default');
      expect(result.origin, BaselineOrigin.captureOrderStrip);
      expect(result.faces.map((f) => f.id), ['f0', 'f1', 'f2', 'f3']);
      expect(
        result.faces.every((f) => f.placement == FacePlacement.captureOrder),
        isTrue,
      );
      expectForwardOrder(result);
      // The ends of the strip are real positions, so the first and last
      // photos sit on them.
      expect(result.faces.first.t, closeTo(0, 1e-9));
      expect(result.faces.last.t, closeTo(1, 1e-9));
    });

    test('a lone photo sits mid-line rather than on the end', () {
      final result = resolveLayout(
        faces: [const FaceInput(id: 'only', captureOrder: 0)],
      );
      expect(result.faces.single.t, closeTo(0.5, 1e-9));
    });
  });

  group('§7.3 an 80-photo sector', () {
    test('lays out every photo in order', () {
      final faces = [
        for (var i = 0; i < 80; i++)
          cameraAlongWall(id: 'p$i', order: i, eastMetres: i * 3.0),
      ];
      final result = resolveLayout(faces: faces);

      expect(result.faces.length, 80);
      expect(result.isLoop, isFalse);
      expectForwardOrder(result);
    });
  });

  group('§7.5 a contributor drags one thumbnail', () {
    test('the pin holds exactly and its neighbours re-interpolate', () {
      final faces = [
        for (var i = 0; i < 5; i++)
          cameraAlongWall(
            id: 'p$i',
            order: i,
            eastMetres: i * 20.0,
            gps: false,
            bearing: false,
          ),
      ];
      final pinned = [...faces]..[2] = faces[2].copyWith(pinnedT: 0.8);
      final result = resolveLayout(faces: pinned);

      final third = result.positionOf('p2')!;
      expect(third.t, closeTo(0.8, 1e-12));
      expect(third.placement, FacePlacement.pinned);
      expectForwardOrder(result);
      // The two after it were pushed into the remaining fifth of the line.
      expect(result.positionOf('p3')!.t, greaterThan(0.8));
      expect(result.positionOf('p4')!.t, closeTo(1.0, 1e-9));
    });

    test('a pin survives recomputation and further photos', () {
      final base = [
        for (var i = 0; i < 4; i++)
          cameraAlongWall(id: 'p$i', order: i, eastMetres: i * 20.0),
      ];
      final pinned = [...base]..[1] = base[1].copyWith(pinnedT: 0.42);

      final once = resolveLayout(faces: pinned);
      final grown = resolveLayout(
        faces: [
          ...pinned,
          cameraAlongWall(id: 'p4', order: 4, eastMetres: 80),
        ],
      );

      expect(once.positionOf('p1')!.t, closeTo(0.42, 1e-12));
      expect(grown.positionOf('p1')!.t, closeTo(0.42, 1e-12));
    });
  });

  group('§7.6 a later contributor adds the missing side', () {
    test('three of four sides is still a strip; the fourth closes it', () {
      final threeSides = [
        for (var i = 0; i < 3; i++)
          cameraAround(id: 'f$i', order: i, angle: 360.0 * i / 4),
      ];
      expect(
        resolveLayout(faces: threeSides).isLoop,
        isFalse,
        reason: 'an unfinished lap must not be presented as a ring',
      );
      expect(resolveLayout(faces: boulder()).isLoop, isTrue);
    });

    test('nobody is asked anything — topology comes only from the data', () {
      // Same call, same arguments, different answer purely because a row
      // arrived. That is §5 step 5.
      final before = resolveLayout(faces: boulder(sides: 3));
      final after = resolveLayout(faces: boulder(sides: 4));
      expect(before.isLoop != after.isLoop, isTrue);
    });
  });

  group('§7.7 one photo with a wildly wrong fix', () {
    test('the outlier is dropped and the face keeps its captured place', () {
      final faces = [
        cameraAlongWall(id: 'p0', order: 0, eastMetres: 0),
        cameraAlongWall(id: 'p1', order: 1, eastMetres: 30),
        // 300 m north of the wall and reported as coarse: unusable.
        FaceInput(
          id: 'p2',
          captureOrder: 2,
          latitude: centreLat + 300 / metresPerDegreeLat,
          longitude: centreLon + 60 * lonPerMetre(centreLat),
          gpsAccuracyMeters: 45,
          bearingDegrees: 0,
        ),
        cameraAlongWall(id: 'p3', order: 3, eastMetres: 90),
      ];
      final result = resolveLayout(faces: faces);

      expect(result.faces.map((f) => f.id), ['p0', 'p1', 'p2', 'p3']);
      expect(
        result.positionOf('p2')!.placement,
        isNot(FacePlacement.gpsProjected),
        reason: 'a fix that coarse is never used to position a face',
      );
      expectForwardOrder(result);
    });

    test('a sensor value never reorders faces', () {
      // Accurate fixes, but the third photo was taken from a spot that would
      // sort it before the second.
      final faces = [
        cameraAlongWall(id: 'p0', order: 0, eastMetres: 0),
        cameraAlongWall(id: 'p1', order: 1, eastMetres: 60),
        cameraAlongWall(id: 'p2', order: 2, eastMetres: 20),
        cameraAlongWall(id: 'p3', order: 3, eastMetres: 90),
      ];
      expectForwardOrder(resolveLayout(faces: faces));
    });
  });

  group('resolver properties', () {
    test('every pin is honoured exactly, whatever else is present', () {
      final random = math.Random(20260828);
      for (var trial = 0; trial < 200; trial++) {
        final count = 2 + random.nextInt(8);
        final faces = <FaceInput>[];
        final pins = <String, double>{};
        for (var i = 0; i < count; i++) {
          final pin = random.nextInt(3) == 0 ? random.nextDouble() : null;
          if (pin != null) pins['p$i'] = pin;
          faces.add(
            FaceInput(
              id: 'p$i',
              captureOrder: i,
              latitude: random.nextBool()
                  ? centreLat + random.nextDouble() * 0.001
                  : null,
              longitude: random.nextBool()
                  ? centreLon + random.nextDouble() * 0.001
                  : null,
              gpsAccuracyMeters: random.nextBool() ? 5 : null,
              bearingDegrees:
                  random.nextBool() ? random.nextDouble() * 360 : null,
              pinnedT: pin,
            ),
          );
        }
        final result = resolveLayout(faces: faces);
        for (final entry in pins.entries) {
          expect(
            result.positionOf(entry.key)!.t,
            closeTo(result.baseline.normalizeT(entry.value), 1e-12),
            reason: 'trial $trial moved a pinned face',
          );
        }
        expect(result.faces.length, count);
        for (final f in result.faces) {
          expect(f.t.isFinite, isTrue);
          expect(f.t, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('is deterministic — the same rows always give the same layout', () {
      final faces = boulder();
      final a = resolveLayout(faces: faces);
      final b = resolveLayout(faces: faces.reversed.toList());
      expect(
        a.faces.map((f) => '${f.id}:${f.t.toStringAsFixed(9)}'),
        b.faces.map((f) => '${f.id}:${f.t.toStringAsFixed(9)}'),
      );
    });

    test('no faces means no layout, not a crash', () {
      final result = resolveLayout(faces: const []);
      expect(result.faces, isEmpty);
      expect(result.baseline.isDegenerate, isTrue);
    });

    test('an authored baseline is never replaced by a synthesised one', () {
      final authored = Baseline(const [
        LayoutPoint(0, 0),
        LayoutPoint(50, 0),
        LayoutPoint(50, 50),
      ]);
      final result = resolveLayout(
        faces: boulder(),
        baseline: authored,
        originLatitude: centreLat,
        originLongitude: centreLon,
      );
      expect(result.origin, BaselineOrigin.authored);
      expect(result.isProvisional, isFalse);
      expect(result.baseline.points.length, 3);
    });
  });

  group('baseline synthesis', () {
    test('headings that sweep right round make a ring without any GPS', () {
      final faces = [
        for (var i = 0; i < 6; i++)
          cameraAround(
            id: 'f$i',
            order: i,
            angle: 360.0 * i / 6,
            gps: false,
          ),
      ];
      final synthesized = synthesizeBaseline(faces);
      expect(synthesized.origin, BaselineOrigin.bearingRing);
      expect(synthesized.baseline.closed, isTrue);
    });

    test('headings clustered in one arc make a strip', () {
      final faces = [
        for (var i = 0; i < 5; i++)
          FaceInput(
            id: 'f$i',
            captureOrder: i,
            bearingDegrees: 10.0 + i * 4,
          ),
      ];
      final synthesized = synthesizeBaseline(faces);
      expect(synthesized.origin, BaselineOrigin.bearingStrip);
      expect(synthesized.baseline.closed, isFalse);
    });

    test('photos all taken from one spot do not become a track', () {
      final faces = [
        for (var i = 0; i < 5; i++)
          cameraAlongWall(id: 'f$i', order: i, eastMetres: i * 0.5),
      ];
      // Half a metre apart is inside the GPS error, not a walk.
      expect(synthesizeBaseline(faces).origin, isNot(BaselineOrigin.gpsTrack));
    });

    test('a provisional line is flagged, an authored one is not', () {
      expect(BaselineOrigin.gpsTrack.isProvisional, isTrue);
      expect(BaselineOrigin.captureOrderStrip.isProvisional, isTrue);
      expect(BaselineOrigin.authored.isProvisional, isFalse);
    });
  });
}
