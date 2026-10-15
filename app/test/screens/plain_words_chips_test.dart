// 2026-10-13 에뮬레이터: 기록 화면은 시스템 용어를 걷어냈는데, 승인 화면 칩
// "물리 버튼"과 실행 상태 화면 칩 "물리 버튼"·"모의 실행기 응답"이 그대로였다.
// 기록 문구 규칙(display_status.dart)과 같은 원칙 — 경로는 사람 말로, 결과 문장과
// 겹치는 칩은 빼고, 모의/실제 구분과 확인 수준은 줄이지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('경로·확인 수준 문구', () {
    test('물리 경로는 칩이 없다(2026-10-14), ThinQ는 그대로', () {
      expect(routeLabel('physical'), isNull);
      expect(routeLabel('thinq'), 'ThinQ');
    });

    test('모의 실행기 보고는 "연습(모의) 결과" — 모의임은 남긴다', () {
      expect(
          confirmationLabel(
              route: 'physical',
              confirmation: 'reported',
              kind: ResultKind.success,
              executionMode: 'mock'),
          '연습 결과');
      // 모의 눌림·동작 확인은 그대로(확인 수준을 줄이지 않는다).
      expect(
          confirmationLabel(
              route: 'physical',
              confirmation: 'press_confirmed',
              kind: ResultKind.success,
              executionMode: 'mock'),
          '연습 결과');
    });

    test('근거 없음은 시스템 말 대신 "확인하지 못했어요", 모의면 연습이라고', () {
      final real = confirmationLabel(
          route: 'physical',
          confirmation: 'none',
          kind: ResultKind.failed,
          executionMode: 'real');
      final mock = confirmationLabel(
          route: 'physical',
          confirmation: 'none',
          kind: ResultKind.failed,
          executionMode: 'mock');
      expect(real, '눌렸는지 확인하지 못했어요');
      expect(mock, '연습 · 눌렸는지 확인하지 못했어요');
    });
  });

  group('실행 상태 화면 결과 칩', () {
    testWidgets('모의 물리 실행: "물리 버튼"·"모의 실행기 응답" 대신 연습(모의) 결과',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(const StatusScreen(),
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.completed,
            outcome: 'success',
            route: 'physical',
            confirmation: 'reported',
            executionMode: 'mock',
            label: '아침 데우기',
          )));
      await tester.pump();

      expect(find.text('물리 버튼'), findsNothing);
      expect(find.text('모의 실행기 응답'), findsNothing);
      // 경로 칩은 결과 문장("모의 버튼 조작을 마쳤어요")과 겹치므로 두지 않는다.
      expect(find.text('버튼을 대신 눌러요'), findsNothing);
      expect(find.text('연습 결과'), findsOneWidget);
      expect(find.textContaining('연습을 마쳤어요'), findsWidgets);
    });

    testWidgets('실제 물리 실행: 확인 수준 칩은 그대로 남는다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(const StatusScreen(),
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.completed,
            outcome: 'success',
            route: 'physical',
            confirmation: 'press_confirmed',
            executionMode: 'real',
            label: '아침 데우기',
          )));
      await tester.pump();

      expect(find.text('물리 버튼'), findsNothing);
      expect(find.text('버튼을 눌렀어요'), findsOneWidget);
    });

    testWidgets('ThinQ 실행은 경로 칩 "ThinQ"를 남긴다', (tester) async {
      _tall(tester);
      await tester.pumpWidget(buildScreen(const StatusScreen(),
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.completed,
            outcome: 'success',
            route: 'thinq',
            receipt: 'accepted',
            confirmation: 'state_confirmed',
            executionMode: 'real',
            label: '저녁 쉬기',
          )));
      await tester.pump();

      expect(find.text('ThinQ'), findsOneWidget);
      expect(find.text('상태 확인됨'), findsOneWidget);
    });
  });
}
