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
  // 외부 평가 2026-10-13 M5: 실물 모션 + 모의 L3(L3_MODE=mock)를 "가전이 전기를 쓰기 시작한 것도 확인했어요"로 말하던 기대를
  // 정직한 규칙으로 고쳤다 — 실측(real) 판정만 실제 동작 확인이다.
  testWidgets('실물 모션이라도 L3가 모의 판정이면 실제 동작 확인이라고 말하지 않고 판정 입력을 밝힌다',
      (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '버튼을 다 눌렀어요. 움직이는지는 집에서 봐 주세요.',
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

    expect(find.text('가전이 전기를 쓰기 시작한 것도 확인했어요'), findsNothing);
    expect(find.text('가전 동작은 연습 값으로 봤어요. 실제로 확인한 건 아니에요'), findsOneWidget);
    // 모의 판정의 true는 실제 동작 근거가 아니다 — 위 문장이 한 번 말한다(같은 말 두 번 금지, 2026-10-17).
    expect(find.textContaining('연습 판정'), findsNothing);
    expect(find.textContaining('전력 파형에서 가열 시작을 확인했어요'), findsOneWidget);
  });

  testWidgets('L3 미확인은 확인하지 못했다고 말한다(성공으로 올리지 않는다)',
      (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '버튼을 다 눌렀어요. 움직이는지는 집에서 봐 주세요.',
        executionMode: 'real',
        outcome: 'success',
        route: 'physical',
        confirmation: 'press_confirmed',
        operationConfirmed: false,
        operationSource: 'real',
        operationDetail: '전력 변화가 없었어요',
      ),
    );

    expect(find.text('가전이 움직였는지 확인하지 못했어요'), findsOneWidget);
    expect(find.text('가전이 전기를 쓰기 시작한 것도 확인했어요'), findsNothing);
  });

  testWidgets('L3 판정이 없으면(null) 동작 이야기를 새로 하지 않는다', (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        message: '버튼을 다 눌렀어요. 움직이는지는 집에서 봐 주세요.',
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

    expect(find.text('버튼을 다 눌렀어요. 움직이는지는 집에서 봐 주세요.'), findsNothing);
    // 실행 환경을 모르면 실제로 눌렀는지 사람에게 확인을 맡긴다.
    expect(findPlainText('움직이는지는 집에서 봐 주세요', contains: true), findsOneWidget);
    expect(find.textContaining('마쳤어요'), findsNothing);
  });

  // 10/6 Copilot 리뷰(66990be): 모의 실행의 L3 true를 실제 가전 확인처럼 말했다.
  testWidgets('모의 실행의 L3 확인은 모의 판정이라고 말한다', (tester) async {
    await _pump(
      tester,
      const ExecutionStatus(
        label: '즉석밥 데워줘',
        phase: ExecutionPhase.completed,
        executionMode: 'mock',
        outcome: 'success',
        route: 'physical',
        confirmation: 'operation_confirmed',
        operationConfirmed: true,
        operationSource: 'mock',
      ),
    );

    expect(find.text('가전이 전기를 쓰기 시작한 것도 확인했어요'), findsNothing);
    expect(find.text('연습이라 실제 가전은 보지 않았어요'), findsOneWidget);
  });

  group('L3 판정 출처 × 모션 실행 모드 (평가 M5)', () {
    const realSentence = '가전이 전기를 쓰기 시작한 것도 확인했어요';
    const mockMotion = '연습이라 실제 가전은 보지 않았어요';
    const mockL3 = '가전 동작은 연습 값으로 봤어요. 실제로 확인한 건 아니에요';
    const unknownL3 = '가전이 움직였는지 확인하지 못했어요. 집에서 가전을 확인해야 해요';
    final cases = <(String, String?, String)>[
      ('real', 'real', realSentence),
      ('real', 'mock', mockL3),
      ('real', null, unknownL3),
      ('unknown', 'real', realSentence),
      ('unknown', 'mock', mockL3),
      ('unknown', null, unknownL3),
      ('mock', 'real', mockMotion),
      ('mock', 'mock', mockMotion),
      ('mock', null, mockMotion),
    ];
    for (final (mode, source, expected) in cases) {
      testWidgets('모션 $mode · L3 출처 ${source ?? '모름'} → $expected', (tester) async {
        await _pump(
          tester,
          ExecutionStatus(
            label: '즉석밥 데워줘',
            phase: ExecutionPhase.completed,
            executionMode: mode,
            outcome: 'success',
            route: 'physical',
            operationConfirmed: true,
            operationSource: source,
          ),
        );
        expect(find.text(expected), findsOneWidget);
        if (expected != realSentence) {
          expect(find.text(realSentence), findsNothing);
          // 확인 아이콘(verified)은 실측 확인에만 쓴다.
          expect(find.byIcon(Icons.verified_outlined), findsNothing);
        }
      });
    }
  });
}
