import 'package:climbtopo/app/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders ClimbTopo title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: ClimbTopoApp()),
    );
    // Allow GoRouter and MaterialApp.router to settle.
    await tester.pumpAndSettle();

    expect(find.text('ClimbTopo'), findsOneWidget);
  });
}
