import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/idle_menu.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/connection_status.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

void main() {
  testWidgets('모름은 느낌표 대신 회색 문구를 보여줘요', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KioskConnectionIcons(
      items: const [ConnectionItem(id: 'press', state: 'unknown', title: '확인 전', message: '')],
      onOpen: (_) {},
    ))));
    expect(find.text('모름'), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-badge-press')), findsNothing);
  });

  testWidgets('방해 금지는 보이는 버튼으로 열고 본문을 크게 읽어요', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KioskIdleView(
      now: DateTime(2026, 10, 1, 9), connected: true, appliances: const [],
      onSelectAppliance: (_) {}, onOpenConnection: (_) {}, onDndGesture: () => opened++,
    ))));
    // 꺼져 있을 때는 글자 없이 달 아이콘 단추(켜진 것으로 읽히지 않게, 10/5).
    expect(find.text('방해 금지'), findsNothing);
    await tapIdleMenuItem(tester, 'dnd-entry');
    expect(opened, 1);
    // 10/7 평소 화면 여백 정리로 인사말 33 → 28. 시계 다음 위계라 다른 글자보다 크고,
    // 14pt 하한(15.8형 캔버스 기준 약 13.2)보다 넉넉히 크다.
    expect(tester.widget<Text>(find.text('좋은 아침이에요')).style!.fontSize, greaterThanOrEqualTo(24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('흐른 시간을 남은 시간처럼 대신 보여주지 않아요', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KioskHoldView(
      appliance: null, holdState: 'hovering_stop', elapsed: const Duration(minutes: 3), onStop: () {},
    ))));
    expect(find.text('끝나는 시간은 확인하지 못했어요'), findsOneWidget);
    expect(find.text('시작한 지'), findsNothing);
    expect(find.text('3:00'), findsNothing);
    expect(find.text('정지'), findsOneWidget);
  });
}
