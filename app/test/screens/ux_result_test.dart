import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  for (final failed in [false, true]) {
    testWidgets('결과 행동은 시작한 화면으로 돌아가요: $failed', (tester) async {
      await tester.pumpWidget(buildWithProviderState(
        executionStatus: ExecutionStatus(
          phase: failed ? ExecutionPhase.failed : ExecutionPhase.completed,
          outcome: failed ? 'safety_stop' : 'success',
        ),
        child: MaterialApp(home: Builder(builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('가전 상세'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const StatusScreen())),
          ),
        ))),
      ));
      await tester.tap(find.text('가전 상세'));
      await tester.pumpAndSettle();
      // 성공은 '확인' 하나, 실패는 '다시 하기'와 '닫기'(외부 평가 10/16 p08).
      expect(find.text('닫기'), failed ? findsOneWidget : findsNothing);
      expect(find.text('정지'), findsNothing);
      await tester.tap(find.text(failed ? '다시 하기' : '확인'));
      await tester.pumpAndSettle();
      expect(find.text('가전 상세'), findsOneWidget);
      expect(find.byType(StatusScreen), findsNothing);
    });
  }

  testWidgets('미확인 결과는 재실행을 권하지 않아요', (tester) async {
    await tester.pumpWidget(buildScreen(const StatusScreen(),
      executionStatus: const ExecutionStatus(phase: ExecutionPhase.unconfirmed)));
    expect(find.text('다시 하기'), findsNothing);
    expect(find.text('확인'), findsOneWidget);
  });

  // 외부 평가 2026-10-13 M4: 실패만으로 다시 시도를 권하지 않는다 — 미전송 근거가 있을 때만.
  for (final (receipt, retry) in [
    ('not_dispatched', true),
    ('accepted', false),
    ('unknown', false),
    (null, false),
  ]) {
    testWidgets('실패한 실행(receipt=${receipt ?? '없음'})의 아래 버튼: 다시 시도 ${retry ? '권함' : '권하지 않음'}',
        (tester) async {
      await tester.pumpWidget(buildScreen(const StatusScreen(),
          executionStatus: ExecutionStatus(
            phase: ExecutionPhase.failed,
            outcome: 'failed',
            route: 'physical',
            receipt: receipt,
          )));
      expect(find.text('다시 하기'), retry ? findsOneWidget : findsNothing);
      expect(find.textContaining('다시 해 주세요'),
          retry ? findsOneWidget : findsNothing);
      expect(find.text(retry ? '다시 하기' : '확인'), findsOneWidget);
    });
  }
}
