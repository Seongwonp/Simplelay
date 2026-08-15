import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

Widget _buildStatus(ExecutionStatus status) => buildScreen(
      const StatusScreen(),
      overrides: withExecutionStatus(status),
    );

void main() {
  group('StatusScreen — idle 상태', () {
    testWidgets('기본 안내 텍스트 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(const ExecutionStatus()));
      await tester.pump();
      expect(find.text('실행 중인 작업 없음'), findsOneWidget);
      expect(find.text('승인한 동작의 진행 상황이 여기에 표시됩니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (idle)', (tester) async {
      await tester.pumpWidget(_buildStatus(const ExecutionStatus()));
      await tester.pump();
      expect(find.text('긴급 정지'), findsNothing);
    });

    testWidgets('센서값 -- 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(const ExecutionStatus()));
      await tester.pump();
      expect(find.text('--'), findsNWidgets(2));
    });
  });

  group('StatusScreen — running 상태', () {
    const runningStatus = ExecutionStatus(
      phase: ExecutionPhase.running,
      label: '우유 데우기',
      sequenceId: 's1',
      steps: ['BT-08', 'BT-03', 'BT-05'],
      completedSteps: 1,
      currentMa: 320,
      soundDb: 42,
    );

    testWidgets('라벨 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(runningStatus));
      await tester.pump();
      expect(find.text('우유 데우기'), findsOneWidget);
    });

    testWidgets('센서 mA / dB 값 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(runningStatus));
      await tester.pump();
      expect(find.text('320 mA'), findsOneWidget);
      expect(find.text('42 dB'), findsOneWidget);
    });

    testWidgets('완료된 단계 check_circle 아이콘 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(runningStatus));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('현재 단계 pending 아이콘 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(runningStatus));
      await tester.pump();
      expect(find.byIcon(Icons.pending), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(runningStatus));
      await tester.pump();
      expect(find.text('긴급 정지'), findsOneWidget);
    });
  });

  group('StatusScreen — retrying 상태', () {
    const retryingStatus = ExecutionStatus(
      phase: ExecutionPhase.retrying,
      label: '재시도 중',
      sequenceId: 's2',
      steps: ['BT-01', 'BT-05'],
      completedSteps: 0,
    );

    testWidgets('버튼 동작 재시도 카드 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(retryingStatus));
      await tester.pump();
      expect(find.text('버튼 동작 재시도 중'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(retryingStatus));
      await tester.pump();
      expect(find.text('긴급 정지'), findsOneWidget);
    });
  });

  group('StatusScreen — completed 상태', () {
    const completedStatus = ExecutionStatus(
      phase: ExecutionPhase.completed,
      label: '우유 데우기',
      sequenceId: 's3',
      steps: ['BT-08', 'BT-03', 'BT-05'],
      completedSteps: 3,
      message: '실행이 완료되었습니다.',
    );

    testWidgets('완료 메시지 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(completedStatus));
      await tester.pump();
      expect(find.text('실행이 완료되었습니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (완료)', (tester) async {
      await tester.pumpWidget(_buildStatus(completedStatus));
      await tester.pump();
      expect(find.text('긴급 정지'), findsNothing);
    });

    testWidgets('모든 단계 check_circle 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(completedStatus));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
    });
  });

  group('StatusScreen — failed 상태', () {
    const failedStatus = ExecutionStatus(
      phase: ExecutionPhase.failed,
      label: '실행 실패',
      sequenceId: 's4',
      steps: ['BT-02', 'BT-05'],
      completedSteps: 0,
      message: '실행에 실패했습니다.',
    );

    testWidgets('실패 메시지 표시', (tester) async {
      await tester.pumpWidget(_buildStatus(failedStatus));
      await tester.pump();
      expect(find.text('실행에 실패했습니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (실패)', (tester) async {
      await tester.pumpWidget(_buildStatus(failedStatus));
      await tester.pump();
      expect(find.text('긴급 정지'), findsNothing);
    });
  });
}
