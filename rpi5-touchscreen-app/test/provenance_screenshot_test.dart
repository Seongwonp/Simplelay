@Tags(['screenshot'])
library;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

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
              // 연습 실행은 근거 숫자를 싣지 않는다 — 실제 화면에 나올 값만(2026-10-15 §3-2, 예전 '모의 검증'은 시험이 넣은 값).
              verificationConfidence: null, verificationDetail: null, onStop: () {});
        await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Malgun'),
          home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: Scaffold(body: view))));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        // 연습은 맨 위 띠로 말한다(2026-10-15 1·2단계).
        expect(find.text(kPracticeBandText), findsOneWidget);
        expect(find.text('연습 모드'), findsNothing);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/provenance_${done ? "done" : "running"}_$scale.png'));
      });
    }
  }
}
