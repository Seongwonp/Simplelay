// L3(가전 동작) 판정 표시와 '끝난 실행' 문장의 출처 표시(2026-09-29 서버 필드).
//
// 두 가지를 고정한다:
//   1. `last_operation_confirmed`가 true일 때만 동작을 확인했다고 말한다.
//      false는 확인하지 못했다고 말하고, null(판정기 없음)은 아무 말도 하지 않는다.
//   2. 완료 국면의 기본 문장이 실행 환경·확인 근거를 모르는 채로 "버튼 조작을
//      마쳤어요"라고 단정하지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

Future<void> _pump(WidgetTester tester, ExecutionStatus status) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(buildScreen(
    const StatusScreen(),
    executionStatus: status,
  ));
  await tester.pump();
}

void main() {
  testWidgets('L3 확인됨이면 가전 동작도 확인했다고 말하고 판정 입력을 밝힌다',
      (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '누름 장치가 응답했어요. 켜졌는지 가전을 확인해 주세요.',
        executionMode: 'real',
        outcome: 'success',
        route: 'physical',
        receipt: 'accepted',
        confirmation: 'operation_confirmed',
        operationConfirmed: true,
        operationSource: 'mock',
        operationDetail: '전력 파형에서 가열 시작을 확인했어요',
      ),
    );

    expect(find.text('가전 동작도 확인했어요'), findsOneWidget);
    // 모의 판정의 true는 실제 동작 근거가 아니다 — 그 사실을 같이 말한다.
    expect(find.textContaining('모의 판정'), findsOneWidget);
    expect(find.textContaining('전력 파형에서 가열 시작을 확인했어요'), findsOneWidget);
  });

  testWidgets('L3 미확인은 확인하지 못했다고 말한다(성공으로 올리지 않는다)',
      (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '누름 장치가 응답했어요. 켜졌는지 가전을 확인해 주세요.',
        executionMode: 'real',
        outcome: 'success',
        route: 'physical',
        confirmation: 'press_confirmed',
        operationConfirmed: false,
        operationSource: 'real',
        operationDetail: '전력 변화가 없었어요',
      ),
    );

    expect(find.text('가전 동작은 확인하지 못했어요'), findsOneWidget);
    expect(find.text('가전 동작도 확인했어요'), findsNothing);
  });

  testWidgets('L3 판정이 없으면(null) 동작 이야기를 새로 하지 않는다', (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '누름 장치가 응답했어요. 켜졌는지 가전을 확인해 주세요.',
        executionMode: 'real',
        outcome: 'success',
        route: 'physical',
        confirmation: 'press_confirmed',
      ),
    );

    expect(find.textContaining('가전 동작'), findsNothing);
  });

  testWidgets('완료 기본 문장은 실행 환경·확인 근거를 모르면 버튼 조작 완료라고 단정하지 않는다',
      (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        // 서버 문장이 없는 경로(BLE 폴백·복원 직후) — 화면 기본값이 나선다.
        outcome: 'success',
        confirmation: 'none',
      ),
    );

    expect(find.text('누름 장치가 응답했어요. 켜졌는지 가전을 확인해 주세요.'), findsNothing);
    expect(find.textContaining('실제 조작 여부는 확인하지 못했어요'), findsOneWidget);
  });
}
