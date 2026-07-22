import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

void main() {
  testWidgets('MasiIcon renders without error', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MasiIcon('search', color: Colors.red, size: 20)),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(MasiIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
