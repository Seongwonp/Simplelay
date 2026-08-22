import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

void main() {
  testWidgets('idle screen renders without crashing', (tester) async {
    // 실제 네트워크(SSE 재접속 타이머)·espeak 프로세스를 만들지 않도록
    // fake를 주입한 스모크 — 앱 셸(SimpleLayKioskApp)은 KioskScreen을
    // 기본 생성하므로 여기서는 화면을 직접 렌더한다.
    await tester.pumpWidget(
      MaterialApp(
        home: KioskScreen(
          api: FakeKioskApi(),
          tts: FakeTts(),
          events: FakeEventStream(),
        ),
      ),
    );
    await tester.pump();

    // 탁상시계 스타일 대기화면(idle_view.dart) — 날짜는 항상 "...요일"로 끝난다.
    expect(find.textContaining('요일'), findsOneWidget);
  });
}
