import 'package:climbtopo/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MasiTheme', () {
    testWidgets(
      'A1: light and dark ThemeData build without throwing and expose a '
      'MasiColors extension via Theme.of / themeData.extension<MasiColors>()',
      (tester) async {
        expect(MasiTheme.light.extension<MasiColors>(), isNotNull);
        expect(MasiTheme.dark.extension<MasiColors>(), isNotNull);

        MasiColors? capturedLight;
        MasiColors? capturedDark;

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            darkTheme: MasiTheme.dark,
            themeMode: ThemeMode.light,
            home: Builder(
              builder: (context) {
                capturedLight = MasiColors.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(capturedLight, isNotNull);
        expect(capturedLight!.accent, MasiColors.light.accent);

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            darkTheme: MasiTheme.dark,
            themeMode: ThemeMode.dark,
            home: Builder(
              builder: (context) {
                capturedDark = Theme.of(context).extension<MasiColors>();
                return const SizedBox();
              },
            ),
          ),
        );
        // Rebuilding the same MaterialApp element with a new themeMode
        // animates via AnimatedTheme rather than snapping instantly —
        // pumpAndSettle lets that transition finish before reading the
        // resolved theme.
        await tester.pumpAndSettle();
        expect(capturedDark, isNotNull);
        expect(capturedDark!.accent, MasiColors.dark.accent);
      },
    );

    test(
      'A2: MasiColors.light.accent and .dark.accent match the DESIGN.md '
      'tokens',
      () {
        expect(MasiColors.light.accent, const Color(0xFF6E56C6));
        expect(MasiColors.dark.accent, const Color(0xFFB7A2F0));
      },
    );

    test('A3: MasiColors.lerp returns a non-null instance and interpolates', () {
      final mid = MasiColors.light.lerp(MasiColors.dark, 0.5);
      expect(mid, isNotNull);
      expect(mid.accent, isNot(MasiColors.light.accent));
      expect(mid.accent, isNot(MasiColors.dark.accent));

      final atStart = MasiColors.light.lerp(MasiColors.dark, 0.0);
      expect(atStart.accent, MasiColors.light.accent);

      final atEnd = MasiColors.light.lerp(MasiColors.dark, 1.0);
      expect(atEnd.accent, MasiColors.dark.accent);
    });
  });
}
