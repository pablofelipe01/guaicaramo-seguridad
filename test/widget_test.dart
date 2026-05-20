import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guaicaramo_control/main.dart';

void main() {
  testWidgets('App builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const GuaicaramoControlApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
