// 실패널 10/24 — 메뉴를 열면 아래 탭이 창 위에 밝게 남아 창의 마지막 줄을 가렸고, 막은 캔버스 안쪽만 덮어 가장자리 띠가 밝았다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

void main() {
  testWidgets('메뉴를 열면 아래 탭을 숨기고 가장자리 띠까지 어둡게, 닫으면 되돌린다', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeKioskApi()..applianceList = [kMicrowaveAppliance];
    await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsOneWidget);
    expect(tester.widget<KioskCanvas>(find.byType(KioskCanvas)).scrim, isFalse);

    await tester.tap(find.byKey(const ValueKey('idle-menu')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsNothing);
    expect(tester.widget<KioskCanvas>(find.byType(KioskCanvas)).scrim, isTrue);
    // 화면 바탕도 막 색 — 맨 위 3px(진행 막대 자리)가 밝은 선으로 남지 않게.
    final scaffold = tester.widget<Scaffold>(
        find.descendant(of: find.byType(KioskCanvas), matching: find.byType(Scaffold)).first);
    expect(scaffold.backgroundColor, isNot(KioskColors.bg));
    // 메뉴의 마지막 줄(사용 방법)이 화면 안에 다 보인다.
    final help = find.text('사용 방법');
    expect(help, findsOneWidget);
    expect(tester.getBottomLeft(help).dy, lessThan(1080 - KioskCanvas.edgeInset));

    await tester.tap(find.text('닫기'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('kiosk-tab-bar')), findsOneWidget);
    expect(tester.widget<KioskCanvas>(find.byType(KioskCanvas)).scrim, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
