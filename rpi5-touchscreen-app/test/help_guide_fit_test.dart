// 사용 방법 여섯 장(UX 문구 기준 10/19) — 800x480 큰 글씨에서도 스크롤 없이 '다음'·'다 봤어요'가 보여야 한다.
// 처음 쓰는 어르신은 카드 안을 끌어 올려야 단추가 나온다는 것을 모른다(한 장 네 문장일 때 단추가 화면 밖으로 밀렸다).
// 줄 수는 글꼴 폭에 달려 있다 — 시험 기본 글꼴(모든 글자가 정사각형)은 한글 글꼴보다 훨씬 넓어 실제 줄 수를 말하지 못한다.
// 그래서 골든과 같은 한글 글꼴(맑은 고딕)을 싣고 재며, 골든처럼 screenshot 태그로 둔다. 글꼴 차이를 생각해 아래 8px을 남긴다.
@Tags(['screenshot'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/help_guide.dart';

import 'support/golden_fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);

  for (final scale in [1.0, 1.22]) {
    testWidgets('사용 방법 모든 장 — 글씨 x$scale에서 스크롤 없이 다음 단추가 화면 안에 있다', (tester) async {
      tester.view.physicalSize = const Size(800, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: KioskHelpGuide(onClose: () {})),
        ),
      ));
      for (var i = 0; i < kHelpPages.length; i++) {
        final last = i == kHelpPages.length - 1;
        final button = find.byKey(ValueKey(last ? 'help-done' : 'help-next'));
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(480 - 8), reason: '${i + 1}장: 단추가 화면 아래로 밀렸다');
        final position = tester
            .state<ScrollableState>(
                find.descendant(of: find.byKey(const ValueKey('help-guide')), matching: find.byType(Scrollable)))
            .position;
        expect(position.maxScrollExtent, lessThanOrEqualTo(1), reason: '${i + 1}장: 스크롤해야 다 보인다');
        if (!last) {
          await tester.tap(button);
          await tester.pump();
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
