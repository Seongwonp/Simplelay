// 자리 비움 화면(10/26 실패널 점검) — 까만 화면은 꺼진 것처럼 보였고, 안쪽만 어두워 바깥 가장자리가 밝게 남았다.
// 이제: 짙은 회색에 시계·날짜가 계속 보이고, 패널 가장자리까지 같은 색.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/room_sleep.dart';

void main() {
  testWidgets('쉬는 화면에 시계와 날짜가 보인다', (tester) async {
    var woke = 0;
    await tester.pumpWidget(MaterialApp(
        home: KioskRoomSleep(onWake: () => woke++, now: () => DateTime(2026, 10, 26, 21, 5))));
    expect(find.text('9:05'), findsOneWidget);
    expect(find.text('오후'), findsOneWidget);
    expect(find.text('10월 26일 월요일'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('room-sleep')));
    expect(woke, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('쉬는 동안 패널 가장자리도 같은 회색', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: KioskCanvas(blackout: true, child: SizedBox())));
    final edge = tester.widgetList<ColoredBox>(
        find.descendant(of: find.byType(KioskCanvas), matching: find.byType(ColoredBox))).first;
    expect(edge.color, KioskRoomSleep.sleepColor);
  });

  testWidgets('돌아왔을 때 인사는 날짜와 메뉴 사이 빈자리에 들어갈 만큼 작다(10/26 실패널: 날짜·메뉴를 가렸다)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: KioskWelcomeBack(text: '내일부터 또 한 주예요. 오늘은 푹 쉬세요.')))));
    // 본문 글자(21)였을 때 날짜·메뉴를 덮었다 — 작은 글자(caption)로.
    final text = tester.widget<Text>(find.text('내일부터 또 한 주예요. 오늘은 푹 쉬세요.'));
    expect(text.style?.fontSize, KioskType.caption);
  });

  testWidgets('화면 틀 밖에 놓여도 글자에 노란 밑줄이 없다(10/26 실패널)', (tester) async {
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: KioskRoomSleep(onWake: () {}, now: () => DateTime(2026, 10, 26, 22, 3))));
    final style = DefaultTextStyle.of(tester.element(find.text('10:03'))).style;
    expect(style.decoration, isNot(TextDecoration.underline));
    expect(find.byType(Material), findsOneWidget);
  });
}
