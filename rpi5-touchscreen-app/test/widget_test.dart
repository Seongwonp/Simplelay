import 'package:flutter_test/flutter_test.dart';

import 'package:simplelay_touchscreen/main.dart';

void main() {
  testWidgets('idle screen renders without crashing', (tester) async {
    await tester.pumpWidget(const SimpleLayKioskApp());
    await tester.pump();

    // 탁상시계 스타일 대기화면(idle_view.dart) — 날짜는 항상 "...요일"로 끝난다.
    expect(find.textContaining('요일'), findsOneWidget);
  });
}
