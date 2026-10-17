import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/widgets/button_map_grid.dart';

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
      expect(find.text('지금 하는 일이 없어요'), findsOneWidget);
      expect(findPlainText('실행하면 여기서 진행을 볼 수 있어요.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (idle)', (tester) async {
      await _pumpStatus(tester, const ExecutionStatus());
      expect(find.text('정지'), findsNothing);
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
      label: '즉석밥 데우기',
      sequenceId: 's1',
      steps: ['BT-08', 'BT-03', 'BT-05'],
      completedSteps: 1,
      currentMa: 320,
      soundDb: 42,
    );

    testWidgets('라벨 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.text('즉석밥 데우기'), findsOneWidget);
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

      // 버튼 이름이 가장 크고, 그 아래 지금 상태가 온다.
      expect(find.text("'1분 추가'"), findsOneWidget);
      expect(findPlainText('눌렸는지 보는 중'), findsOneWidget);
      expect(find.textContaining('센서로 눌림 확인'), findsOneWidget);
      // 센서 %는 일반 화면에 내지 않는다(2026-10-17 쉬운 말 규칙 6).
      expect(find.textContaining('93%'), findsNothing);
      // steps 미리보기가 없어도 total_steps로 진행이 보인다(음성 실행 경로).
      // 퍼센트가 아니라 '조작 N개 중 K개'다 -- 남은 시간을 아는 척하지 않는다.
      // 루틴의 'N단계'와 다른 축이라 다른 말(외부 평가 L3).
      expect(find.text('3\u2060개 중 1\u2060개 했어요'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('확인 불가에서는 정지와 다시 확인을 함께 제공한다', (tester) async {
      // 통신이 끊긴 것이지 가전이 멈춘 게 아니다 -- 가장 불안한 순간에
      // 조작 수단이 사라지면 안 된다.
      await _pumpStatus(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.unknown,
          label: '즉석밥 데워줘',
          message: '연결이 끊겨 어떻게 됐는지 몰라요. 가전을 봐 주세요.',
        ),
      );

      expect(find.text('정지'), findsOneWidget);
      expect(find.text('새로 보기'), findsOneWidget);
      expect(findPlainText('가전을 봐 주세요', contains: true), findsOneWidget);
      // 큰 문장은 어절 단위로 줄을 바꾼다('동/작을' 방지, UI 평가 10/17).
      final headline = tester.widget<Text>(findPlainText('가전을 봐 주세요', contains: true));
      expect(headline.data, contains(kWordJoiner));
      expect(headline.semanticsLabel, '연결이 끊겨 어떻게 됐는지 몰라요. 가전을 봐 주세요.');
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
      expect(findPlainText('누르는 중'), findsOneWidget);
      expect(find.text('버튼이 눌렸는지 보고 있어요.'), findsOneWidget);
    });

    testWidgets('실행 중에는 idle 안내 문구를 쓰지 않는다', (tester) async {
      // 골든에서 잡혔던 결함: BLE 경로는 message가 비어 있어서, 실행 중인데
      // 부제가 '실행하면 여기서 진행을 볼 수 있어요.'였다.
      await _pumpStatus(tester, runningStatus);
      expect(find.text('실행하면 여기서 진행을 볼 수 있어요.'), findsNothing);
    });

    testWidgets('실행 대상 가전을 위에 말한다', (tester) async {
      // 지금 고른 가전이 아니라 **이 실행의 대상**을 설치 목록에서 찾는다.
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildScreen(
        const StatusScreen(),
        executionStatus: const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          applianceId: 'microwave',
          totalSteps: 2,
        ),
        overrides: installedOverrides([kTestAppliance]),
      ));
      await tester.pump();
      expect(find.text('전자레인지'), findsOneWidget);
    });

    Future<void> pumpWithTarget(
        WidgetTester tester, ExecutionStatus status) async {
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildScreen(
        const StatusScreen(),
        executionStatus: status,
        overrides: installedOverrides([kTestAppliance]),
      ));
      await tester.pump();
    }

    testWidgets('실제 버튼판 위에 끝난 버튼과 지금 누르는 버튼을 보여준다', (tester) async {
      // 이름 목록만 있으면 '앱이 돌다 끝나는 화면'과 구별되지 않는다.
      await pumpWithTarget(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.running,
          label: '즉석밥 데워줘',
          applianceId: 'microwave',
          steps: ['BT-08', 'BT-03', 'BT-05'],
          completedSteps: 1,
        ),
      );

      expect(find.text('전자레인지 버튼판'), findsOneWidget);
      final grid = tester.widget<ButtonMapGrid>(find.byType(ButtonMapGrid));
      expect(grid.stateOf('BT-08'), ButtonMapStepState.done);
      expect(grid.stateOf('BT-03'), ButtonMapStepState.current);
      expect(grid.stateOf('BT-05'), ButtonMapStepState.pending);
      // 끝난 버튼은 번호 대신 체크 -- 색을 빼도 구분된다.
      expect(
        find.descendant(
          of: find.byType(ButtonMapGrid),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
    });

    testWidgets('대상 가전을 모르면 버튼 배치를 지어내지 않는다', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.byType(ButtonMapGrid), findsNothing);
      expect(find.text('누르는 순서'), findsOneWidget);
    });

    testWidgets('실패한 실행의 버튼판에는 지금 누르는 버튼이 없다', (tester) async {
      await pumpWithTarget(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.failed,
          label: '즉석밥 데워줘',
          applianceId: 'microwave',
          steps: ['BT-08', 'BT-03', 'BT-05'],
          completedSteps: 1,
        ),
      );
      final grid = tester.widget<ButtonMapGrid>(find.byType(ButtonMapGrid));
      expect(grid.stateOf('BT-03'), ButtonMapStepState.pending);
    });

    testWidgets('센서 수치는 펼쳐야 보인다', (tester) async {
      // 실행 중에 판단해야 하는 것은 mA·dB 값이 아니라 **눌림을 확인했는가**다.
      // 수치를 위에 크게 두면 화면이 기술 데모 대시보드가 되고, 이 제품의
      // 논지가 숫자 뒤로 밀린다. 근거가 필요한 사람은 펼쳐서 본다.
      await _pumpStatus(tester, runningStatus);
      expect(find.text('320 mA'), findsNothing);
      expect(findPlainText('전기와 소리 기록'), findsOneWidget);

      await tester.tap(findPlainText('전기와 소리 기록'));
      // 실행 화면은 진행 표시가 계속 돌아서 pumpAndSettle이 끝나지 않는다.
      await tester.pump();

      expect(find.text('320 mA'), findsOneWidget);
      expect(find.text('42 dB'), findsOneWidget);
    });

    testWidgets('완료된 단계 check_circle 아이콘 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('현재 단계는 모양과 글자로 구분한다', (tester) async {
      // 색을 빼도 지금 단계가 보여야 한다: 채운 원 + '지금'.
      await _pumpStatus(tester, runningStatus);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.text('지금'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await _pumpStatus(tester, runningStatus);
      expect(find.text('정지'), findsOneWidget);
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

    testWidgets('재시도는 실패가 아니라 보정으로 말한다', (tester) async {
      await _pumpStatus(tester, retryingStatus);
      expect(findPlainText('자리를 맞춰 다시 누르는 중'), findsOneWidget);
      expect(find.text('눌렸는지 몰라서 자리를 맞추고 다시 눌러요.'),
          findsOneWidget);
      expect(find.textContaining('못 했어요'), findsNothing);
    });

    testWidgets('긴급 정지 버튼 표시', (tester) async {
      await _pumpStatus(tester, retryingStatus);
      expect(find.text('정지'), findsOneWidget);
    });
  });

  group('StatusScreen — completed 상태', () {
    const completedStatus = ExecutionStatus(
      phase: ExecutionPhase.completed,
      label: '즉석밥 데우기',
      sequenceId: 's3',
      steps: ['BT-08', 'BT-03', 'BT-05'],
      completedSteps: 3,
      message: '실행이 완료되었습니다.',
    );

    testWidgets('완료 메시지 표시', (tester) async {
      await _pumpStatus(tester, completedStatus);
      expect(findPlainText('실행이 완료되었습니다.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (완료)', (tester) async {
      await _pumpStatus(tester, completedStatus);
      expect(find.text('정지'), findsNothing);
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
      message: '실행을 시작하지 못했어요. 연결 상태를 확인하고 다시 시도해 주세요.',
    );

    testWidgets('실패 메시지 표시', (tester) async {
      await _pumpStatus(tester, failedStatus);
      expect(findPlainText('실행을 시작하지 못했어요. 연결 상태를 확인하고 다시 시도해 주세요.'), findsOneWidget);
    });

    testWidgets('긴급 정지 버튼 없음 (실패)', (tester) async {
      await _pumpStatus(tester, failedStatus);
      expect(find.text('정지'), findsNothing);
    });

    testWidgets('실패는 모양으로도 구분한다', (tester) async {
      await _pumpStatus(tester, failedStatus);
      expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    });
  });

  group('StatusScreen — 긴급 정지의 모양', () {
    testWidgets('정지 기호와 두꺼운 외곽선을 가진다 — 색만으로 구분하지 않는다',
        (tester) async {
      await _pumpStatus(
        tester,
        const ExecutionStatus(
          phase: ExecutionPhase.unknown,
          label: '즉석밥 데워줘',
          message: '연결이 끊겨 동작을 확인할 수 없어요.',
        ),
      );
      // 흑백에서 '다시 확인'과 같은 회색 막대 둘로 보이면 안 된다.
      expect(find.byIcon(Icons.stop), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('정지'),
          matching: find.byType(FilledButton),
        ),
      );
      final shape = button.style!.shape!.resolve({}) as RoundedRectangleBorder;
      expect(shape.side.width, greaterThanOrEqualTo(3));
      // 키오스크와 같은 짙은 빨강에 흰 글자 -- 연한 색은 비상으로 읽히지 않았다.
      expect(button.style!.backgroundColor!.resolve({}), AppColors.stop);
      expect(button.style!.foregroundColor!.resolve({}), Colors.white);
    });
  });
}
