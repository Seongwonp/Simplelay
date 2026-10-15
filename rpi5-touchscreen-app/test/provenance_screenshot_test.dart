@Tags(['screenshot'])
library;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';

import 'support/golden_fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);
  for (final scale in [1.0, 1.6]) {
    for (final done in [false, true]) {
      testWidgets('mock provenance ${done ? "done" : "running"} $scale', (tester) async {
        tester.view.physicalSize = const Size(800, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final Widget view = done ? const KioskDoneView(success: true, label: '즉석밥 데우기', executionMode: 'mock')
          : KioskExecutingView(title: '즉석밥 데우기', executionMode: 'mock', lastButtons: null,
              currentButton: '시작', currentAttempt: 1, completedSteps: 1, totalSteps: 2,
              verificationConfidence: 1, verificationDetail: '모의 검증', onStop: () {});
        await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Malgun'),
          home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: Scaffold(body: view))));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.text('연습 모드'), findsOneWidget);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/provenance_${done ? "done" : "running"}_$scale.png'));
      });
    }
  }
}
