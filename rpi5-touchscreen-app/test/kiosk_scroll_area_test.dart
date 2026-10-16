// 스크롤 막대가 글자 위에 겹치지 않는다(UI 평가 2026-10-17 — 큰 글씨 실행 화면에서 '…먹을 준비'가 막대에 가렸다).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_scroll_area.dart';

void main() {
  testWidgets('막대 자리만큼 오른쪽을 비워 둔다 — 글자의 오른쪽 끝이 막대 앞에서 끝난다', (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
          key: const ValueKey('area'),
          width: 300,
          height: 120,
          child: KioskScrollArea(
            child: Column(children: [
              for (var i = 0; i < 8; i++)
                SizedBox(key: ValueKey('row-$i'), width: double.infinity, height: 40),
            ]),
          ),
        ),
        ),
      ),
    ));
    final area = tester.getRect(find.byKey(const ValueKey('area')));
    final row = tester.getRect(find.byKey(const ValueKey('row-0')));
    expect(row.right, lessThanOrEqualTo(area.right - 12), reason: '막대(6) + 간격');
  });
}
