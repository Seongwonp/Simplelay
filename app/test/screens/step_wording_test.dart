// '단계' 말의 구분과 줄바꿈(외부 평가 2026-10-13 L3).
//
// 루틴 목록·홈의 "전자레인지 3단계"는 **루틴 단계 수**이고, 실행 상태 화면의 진행은 이 실행의 **조작 진행**
// (서버 total_steps — 버튼 하나 또는 명령 한 묶음)이다. 같은 '단계'라는 말로 두 축을 부르지 않는다.
// 큰 글씨에서 숫자와 단위가 다른 줄로 떨어지지 않게 둘 사이에 단어 결합 문자(U+2060)를 둔다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

const _routine = Routine(
  id: 'rt-1',
  name: '아침 데우기',
  when: '평일 07:30',
  steps: [
    RoutineStep.press('microwave', ['즉석밥']),
    RoutineStep.wait('microwave'),
    RoutineStep.press('microwave', ['시작']),
  ],
);

/// [text]를 [width]로 줄을 나눴을 때 숫자 [digitAt]과 단위 첫 글자 [unitAt]이 같은 줄인가.
bool _sameLine(String text, int digitAt, int unitAt, double width) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 28)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  final a = tp.getBoxesForSelection(
      TextSelection(baseOffset: digitAt, extentOffset: digitAt + 1));
  final b = tp.getBoxesForSelection(
      TextSelection(baseOffset: unitAt, extentOffset: unitAt + 1));
  tp.dispose();
  return a.isNotEmpty && b.isNotEmpty && (a.first.top - b.first.top).abs() < 1;
}

void _expectNeverSplit(String text, String unit) {
  final unitAt = text.indexOf(unit);
  expect(unitAt, greaterThan(0));
  var digitAt = unitAt - 1;
  while (digitAt >= 0 && !RegExp(r'\d').hasMatch(text[digitAt])) {
    digitAt--;
  }
  expect(digitAt, greaterThanOrEqualTo(0));
  for (var w = 600.0; w >= 60; w -= 2) {
    expect(_sameLine(text, digitAt, unitAt, w), isTrue,
        reason: '폭 $w에서 숫자와 "$unit"이 다른 줄로 나뉘었다: $text');
  }
}

void main() {
  // 평가 5차 10/18: 단위는 '누를 버튼 N개'(누를 버튼 합 — '버튼 N번'은 한 버튼을 N번 누르는 말로 읽혔다).
  test('루틴 부제의 "누를 버튼 N개"는 누를 버튼 수이고 화면에서 숫자와 단위가 붙어 다닌다', () {
    final s = routineSubtitle(_routine, const {'microwave': '전자레인지'});
    expect(s, '평일 오전 7:30 · 전자레인지 · 누를 버튼 2개'); // 오전/오후 표기(평가 7차 10/18)
    _expectNeverSplit(keepWordsTogether(s), '개');
  });

  testWidgets('실행 상태 화면의 진행은 "조작 N개 중 K개" — 루틴의 "단계"와 다른 말', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: const ExecutionStatus(
        label: '아침 데우기',
        phase: ExecutionPhase.running,
        currentButton: '1분 추가',
        totalSteps: 3,
        completedSteps: 1,
      ),
    ));
    await tester.pump();
    expect(find.text('3⁠개 중 1⁠개 했어요'), findsOneWidget);
    expect(find.textContaining('단계'), findsNothing);
    _expectNeverSplit('3⁠개 중 1⁠개 했어요', '개');
  });
}
