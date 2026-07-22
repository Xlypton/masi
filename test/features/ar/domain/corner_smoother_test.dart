import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/features/ar/domain/corner_smoother.dart';

void main() {
  group('CornerSmoother', () {
    const baseQuad = <Offset>[
      Offset(100, 100),
      Offset(300, 100),
      Offset(300, 300),
      Offset(100, 300),
    ];

    /// Generates [count] synthetic noisy corner-quad frames: [baseQuad] plus
    /// independent per-corner, per-axis uniform noise in
    /// `[-noiseMagnitude, noiseMagnitude]`, seeded for determinism.
    List<List<Offset>> noisyFrames(
      int count, {
      double noiseMagnitude = 15,
      int seed = 42,
    }) {
      final rnd = Random(seed);
      return List<List<Offset>>.generate(count, (_) {
        return <Offset>[
          for (final corner in baseQuad)
            Offset(
              corner.dx + (rnd.nextDouble() * 2 - 1) * noiseMagnitude,
              corner.dy + (rnd.nextDouble() * 2 - 1) * noiseMagnitude,
            ),
        ];
      });
    }

    /// The mean per-corner Euclidean distance between consecutive frames --
    /// a proxy for "how much does this sequence visibly jitter frame to
    /// frame".
    double meanFrameToFrameDelta(List<List<Offset>> frames) {
      double total = 0;
      int count = 0;
      for (var i = 1; i < frames.length; i++) {
        for (var c = 0; c < 4; c++) {
          total += (frames[i][c] - frames[i - 1][c]).distance;
          count++;
        }
      }
      return total / count;
    }

    test(
      'smoothing materially reduces frame-to-frame jitter vs. the raw noisy '
      'input',
      () {
        final rawFrames = noisyFrames(40);
        final smoother = CornerSmoother();
        final smoothedFrames = <List<Offset>>[
          for (final frame in rawFrames) smoother.smooth(frame),
        ];

        final rawJitter = meanFrameToFrameDelta(rawFrames);
        final smoothedJitter = meanFrameToFrameDelta(smoothedFrames);

        expect(
          smoothedJitter,
          lessThan(rawJitter * 0.5),
          reason:
              'EMA smoothing (alpha=$kCornerSmoothingAlpha) should '
              'meaningfully damp frame-to-frame jitter -- raw=$rawJitter, '
              'smoothed=$smoothedJitter',
        );
      },
    );

    test(
      'the first sample after construction is returned unchanged (nothing '
      'to blend against yet)',
      () {
        final smoother = CornerSmoother();

        final result = smoother.smooth(baseQuad);

        expect(result, baseQuad);
      },
    );

    test(
      'the second sample is blended with the first via the documented EMA '
      'formula (alpha * raw + (1 - alpha) * previous), independently per '
      'coordinate',
      () {
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
        const alpha = 0.35;
        final smoother = CornerSmoother(alpha: alpha);

        smoother.smooth(first);
        final result = smoother.smooth(second);

        for (var i = 0; i < 4; i++) {
          final expectedX = alpha * second[i].dx + (1 - alpha) * first[i].dx;
          final expectedY = alpha * second[i].dy + (1 - alpha) * first[i].dy;
          expect(result[i].dx, closeTo(expectedX, 1e-9), reason: 'corner $i dx');
          expect(result[i].dy, closeTo(expectedY, 1e-9), reason: 'corner $i dy');
        }
      },
    );

    test(
      'reset() clears the running state -- the next smooth() call is a '
      'fresh passthrough, not blended against pre-reset corners',
      () {
        final smoother = CornerSmoother();
        smoother.smooth(const <Offset>[
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
        ]);
        // A corner quad far away from the one fed above: if reset() failed
        // to clear state, blending would pull the result noticeably toward
        // the pre-reset quad instead of passing this one through untouched.
        const farAwayQuad = <Offset>[
          Offset(1000, 1000),
          Offset(1010, 1000),
          Offset(1010, 1010),
          Offset(1000, 1010),
        ];

        smoother.reset();
        final afterReset = smoother.smooth(farAwayQuad);

        expect(
          afterReset,
          farAwayQuad,
          reason:
              'after reset(), smooth() must behave exactly like a brand-new '
              'CornerSmoother -- pure passthrough, no blending with corners '
              'fed before the reset',
        );
      },
    );

    test(
      'alpha=1.0 disables smoothing entirely -- every call passes through '
      'unchanged',
      () {
        final smoother = CornerSmoother(alpha: 1.0);
        const a = <Offset>[
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
        ];
        const b = <Offset>[
          Offset(5, 5),
          Offset(15, 5),
          Offset(15, 15),
          Offset(5, 15),
        ];

        expect(smoother.smooth(a), a);
        expect(smoother.smooth(b), b);
      },
    );

    test('the constructor asserts alpha is within (0, 1]', () {
      expect(() => CornerSmoother(alpha: 0), throwsA(isA<AssertionError>()));
      expect(() => CornerSmoother(alpha: 1.5), throwsA(isA<AssertionError>()));
      expect(() => CornerSmoother(alpha: -0.1), throwsA(isA<AssertionError>()));
    });

    test('smooth() asserts exactly 4 points', () {
      final smoother = CornerSmoother();
      expect(
        () => smoother.smooth(const <Offset>[Offset(0, 0), Offset(1, 1)]),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
