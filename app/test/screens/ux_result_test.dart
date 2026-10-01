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
      expect(find.text('닫기'), findsOneWidget);
      expect(find.text('정지'), findsNothing);
      await tester.tap(find.text(failed ? '다시 시도' : '확인'));
      await tester.pumpAndSettle();
      expect(find.text('가전 상세'), findsOneWidget);
      expect(find.byType(StatusScreen), findsNothing);
    });
  }

  testWidgets('미확인 결과는 재실행을 권하지 않아요', (tester) async {
    await tester.pumpWidget(buildScreen(const StatusScreen(),
      executionStatus: const ExecutionStatus(phase: ExecutionPhase.unconfirmed)));
    expect(find.text('다시 시도'), findsNothing);
    expect(find.text('확인'), findsOneWidget);
  });
}
