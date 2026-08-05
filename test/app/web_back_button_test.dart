import 'package:masi/app/theme.dart';
import 'package:masi/app/web_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers `webBackLeading` — the shared, MasiIcon-branded back control this
/// task adds to WEB, on pushed routes that had no explicit back affordance
/// of their own (see `crud_list_scaffold.dart`, `logbook_screen.dart`,
/// `ar_screen.dart`). See that function's doc for the full rationale (the
/// #76 Safari `routerNeglect` trade-off, and installed-standalone-PWA having
/// no browser chrome at all on any engine).
///
/// `isWeb` is the seam that lets these tests force the web branch: real
/// `kIsWeb` is a compile-time constant that is permanently `false` under
/// `flutter test` (always the Dart VM, never web/wasm).
void main() {
  /// A first screen with a button that pushes a second screen whose AppBar
  /// `leading` is `webBackLeading(context, isWeb: isWeb)` — the shape every
  /// real call site (CrudListScaffold/LogbookScreen/ArScreen) uses.
  Widget harness({bool? isWeb}) {
    return MaterialApp(
      theme: MasiTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          key: const Key('first-screen'),
          body: Center(
            child: ElevatedButton(
              key: const Key('push-second'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (pushedContext) => Scaffold(
                    key: const Key('second-screen'),
                    appBar: AppBar(
                      leading: webBackLeading(pushedContext, isWeb: isWeb),
                      title: const Text('Second'),
                    ),
                  ),
                ),
              ),
              child: const Text('Push'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'W1: isWeb:true + a genuinely pushed route -> the web-back-button '
    'appears, and tapping it pops back to the first screen',
    (tester) async {
      await tester.pumpWidget(harness(isWeb: true));
      await tester.tap(find.byKey(const Key('push-second')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('second-screen')), findsOneWidget);
      expect(find.byKey(const Key('web-back-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('web-back-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('first-screen')), findsOneWidget);
      expect(find.byKey(const Key('second-screen')), findsNothing);
    },
  );

  testWidgets(
    'W2: isWeb:true but nothing to pop (rendered as the FIRST/only route, '
    'like a top-level shell tab or a directly-landed-on route) -> absent',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MasiTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(
                leading: webBackLeading(context, isWeb: true),
                title: const Text('Only route'),
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('web-back-button')), findsNothing);
    },
  );

  testWidgets(
    'W3: default (isWeb omitted -> real kIsWeb, false under flutter test) '
    'on an otherwise-poppable route -> absent, regardless of canPop — this '
    'is the native no-op guarantee: the real AppBar leading stays null so '
    "Flutter's own automatic back arrow (unaffected by this change) is what "
    'shows on native, never a second control next to it',
    (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.byKey(const Key('push-second')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('second-screen')), findsOneWidget);
      expect(find.byKey(const Key('web-back-button')), findsNothing);
      // The framework's own default back arrow still renders (leading was
      // left null, not suppressed) — BackButtonIcon is what AppBar mounts
      // for its automatic leading.
      expect(find.byType(BackButtonIcon), findsOneWidget);
    },
  );
}
