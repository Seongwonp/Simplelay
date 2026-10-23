// 어절 단위 줄바꿈 도우미(2026-10-16 디자인 규격 §1-3) — 그리는 글자에만 보이지 않는 잇기 문자가 들어가고,
// 화면 읽기·글 찾기는 원문 그대로다. 화면 전체의 줄바꿈 판정은 kiosk_design_test.dart '어절 단위 줄바꿈'.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_text.dart';

void main() {
  test('낱말 안 글자 사이에만 잇기 문자, 띄어쓰기는 그대로', () {
    const wj = '⁠';
    expect(keepWords('멈췄는지 확인하지 못했어요'), ['멈', '췄', '는', '지 확', '인', '하', '지 못', '했', '어', '요'].join(wj));
    // 잇기 문자를 빼면 원문과 같다 — 끝의 짧은 두 낱말('눌러 주세요')만 줄 바꾸지 않는 띄어쓰기로 묶는다(UI 평가 3차 10/17).
    const s = '지금 전자레인지의 \'취소\' 버튼을 직접 눌러 주세요';
    expect(keepWords(s).replaceAll(wj, ''), s.replaceFirst('눌러 주세요', '눌러 주세요'));
  });

  test('문단 끝 한 글자 낱말은 앞 낱말과 묶는다(줄 바꾸지 않는 띄어쓰기)', () {
    expect(keepWords('확인하는 중').replaceAll('⁠', ''), '확인하는 중');
    // 둘째 문단은 끝 두 낱말 합이 6자라 함께 넘긴다(UI 평가 4차).
    expect(keepWords('누르는 중\n둘째 줄이에요').replaceAll('⁠', ''), '누르는 중\n둘째 줄이에요');
    expect(keepWords('정지').replaceAll('⁠', ''), '정지');
  });

  testWidgets('찾기·화면 읽기는 원문, 그리는 글자만 바뀐다', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: KioskText('가전이 멈췄는지 확인하지 못했어요', textKey: ValueKey('t'))),
    ));
    expect(find.text('가전이 멈췄는지 확인하지 못했어요'), findsOneWidget);
    expect(find.bySemanticsLabel('가전이 멈췄는지 확인하지 못했어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('t')), findsOneWidget);
    handle.dispose();
  });
}
