import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

Widget _buildStatus(ExecutionStatus status) => buildScreen(
      const StatusScreen(),
      executionStatus: status,
    );

// StatusScreen 본문은 ListView라, 기본 테스트 뷰포트(800x600)보다 콘텐츠가 길면
// 긴급 정지 버튼처럼 스크롤해야 보이는 위젯은 Element 자체가 안 만들어져서
// find.text()/find.byIcon()이 "없음"으로 잘못 판정한다. 뷰포트를 넉넉히 키워서 방지.
Future<void> _pumpStatus(WidgetTester tester, ExecutionStatus status) async {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_buildStatus(status));
  await tester.pump();
}

void main() {
  group('StatusScreen — idle 상태', () {
    testWidgets('기본 안내 텍스트 표시', (tester) async {
      await _pumpStatus(tester, const ExecutionStatus());
      expect(find.text('실행 중인 작업 없음'), findsOneWidget);
      expect(find.text('실행을 시작하면 진행 상황이 여기에 표시돼요.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (idle)', (tester) async {
      await _pumpStatus(tester, const ExecutionStatus());
      expect(find.text('긴급 정지'), findsNothing);
    });

    testWidgets('원시 센서값이 없으면 센서 카드를 숨긴다', (tester) async {
      // HTTP 경로엔 mA/dB가 없다. 빈 차트에 '--'만 남기면 개발 도구처럼
      // 보이고, 정작 중요한 '눌림을 확인했는가'가 묻힌다.
      await _pumpStatus(tester, const ExecutionStatus());
      expect(find.text('센서 모니터'), findsNothing);
      expect(find.text('--'), findsNothing);
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
      await _pumpStatus(tester, runningStatus);
      expect(find.text('우유 데우기'), findsOneWidget);
    });

    // 폐루프 증거 -- 서버가 주는 현재 버튼·검증 근거가 화면에 도착해야 한다.
    // 없으면 사용자에겐 "빙글빙글 돌다 완료되는 앱"이고, 제품의 차별점이
    // 가장 중요한 경로에서 보이지 않는다.
    testWidgets('현재 누르는 버튼과 검증 근거를 보여준다', (tester) async {
      await _pumpStatus(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          currentButton: '1분 추가',
          totalSteps: 3,
          completedSteps: 1,
          verificationConfidence: 0.93,
          verificationDetail: '센서로 눌림 확인',
        ),
      );

      expect(find.text("'1분 추가' 버튼을 누르고 있어요."), findsOneWidget);
      expect(find.textContaining('센서로 눌림 확인'), findsOneWidget);
      expect(find.textContaining('센서 93%'), findsOneWidget);
      // steps 미리보기가 없어도 total_steps로 진행이 보인다(음성 실행 경로)
      expect(find.text('3단계 중 1단계'), findsOneWidget);
    });

    testWidgets('확인 불가에서는 정지와 다시 확인을 함께 제공한다', (tester) async {
      // 통신이 끊긴 것이지 가전이 멈춘 게 아니다 -- 가장 불안한 순간에
      // 조작 수단이 사라지면 안 된다.
      await _pumpStatus(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.unknown,
          label: '즉석밥 데워줘',
          message: '연결이 끊겨 동작을 확인할 수 없어요. 가전을 직접 확인해주세요.',
        ),
      );

      expect(find.text('긴급 정지'), findsOneWidget);
      expect(find.text('다시 확인'), findsOneWidget);
      expect(find.textContaining('가전을 직접 확인'), findsOneWidget);
    });

    testWidgets('검증 결과가 아직 없으면 확인 중임을 알린다', (tester) async {
      await _pumpStatus(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.running,
          currentButton: '시작',
          totalSteps: 2,
        ),
      );
      expect(find.text('버튼 눌림을 확인하고 있어요.'), findsOneWidget);
    });

    testWidgets('센서 mA / dB 값 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.text('320 mA'), findsOneWidget);
      expect(find.text('42 dB'), findsOneWidget);
    });

    testWidgets('완료된 단계 check_circle 아이콘 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('현재 단계 pending 아이콘 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.byIcon(Icons.pending), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
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
      await _pumpStatus(tester, retryingStatus);
      // 실제 위젯 텍스트는 말줄임표(…)가 붙어 있음 — _RetryBanner 참고.
      expect(find.text('버튼 동작 재시도 중…'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await _pumpStatus(tester, retryingStatus);
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
      await _pumpStatus(tester, completedStatus);
      expect(find.text('실행이 완료되었습니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (완료)', (tester) async {
      await _pumpStatus(tester, completedStatus);
      expect(find.text('긴급 정지'), findsNothing);
    });

    testWidgets('모든 단계 check_circle 표시', (tester) async {
      await _pumpStatus(tester, completedStatus);
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
      await _pumpStatus(tester, failedStatus);
      expect(find.text('실행에 실패했습니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (실패)', (tester) async {
      await _pumpStatus(tester, failedStatus);
      expect(find.text('긴급 정지'), findsNothing);
    });
  });
}
