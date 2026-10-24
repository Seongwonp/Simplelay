// 첫 사용 평가 2차(10/24): 설정 '사용 방법'의 '멈추는 방법' 토막이 접근성 트리(uiautomator 덤프)에 없었다 — 화면 밖 토막은
// 목록이 아직 만들지 않아 화면 읽기가 건너뛰었다. 토막마다 제목+본문을 한 덩어리로, 다섯 토막 모두 늘 트리에 있어야 한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/screens/help_screen.dart';

void main() {
  testWidgets('사용 방법 다섯 토막 모두 화면 읽기에 나온다(작은 화면·큰 글씨에서도)', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(2.0)),
        child: HelpScreen(),
      ),
    ));
    await tester.pump();
    for (final (_, title, body) in HelpScreen.sections) {
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(title)}')), findsOneWidget, reason: title);
      expect(find.bySemanticsLabel(RegExp(RegExp.escape(body))), findsOneWidget, reason: '$title 본문');
    }
    handle.dispose();
  });
}
