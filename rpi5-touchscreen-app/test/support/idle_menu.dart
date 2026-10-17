// 평소 화면 위쪽이 상태 칩 + 메뉴로 바뀐 뒤(화면 구조 개편 10/18) 잠시 쉬기·설정·연결 목록을 여는 시험 도우미.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 메뉴 창의 항목('dnd-entry' · 'settings-entry')을 누른다 — 창이 닫혀 있으면 먼저 '메뉴'를 연다.
Future<void> tapIdleMenuItem(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('idle-menu')));
    await tester.pump();
  }
  await tester.tap(find.byKey(ValueKey(key)));
}

/// 상태 칩을 눌러 연결 목록 창을 연다(문제가 하나뿐이면 칩이 그 연결 창을 바로 연다).
Future<void> openIdleConnections(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('idle-status-chip')));
  await tester.pump();
}
