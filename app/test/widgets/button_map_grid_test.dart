import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/widgets/button_map_grid.dart';

import '../helpers/test_helpers.dart';

void main() {
  // 전자레인지 템플릿: BT-08 즉석밥, BT-03 1분, BT-05 시작.
  const steps = ['BT-08', 'BT-03', 'BT-05'];

  group('ButtonMapGrid — 버튼별 진행 상태', () {
    test('제안 확인(진행 없음)은 순서에 든 버튼을 모두 같은 모양으로', () {
      final grid = ButtonMapGrid(appliance: kTestAppliance, steps: steps);
      expect(grid.stateOf('BT-08'), ButtonMapStepState.planned);
      expect(grid.stateOf('BT-05'), ButtonMapStepState.planned);
    });

    test('실행 중에는 끝난·지금·남은 버튼이 나뉜다', () {
      final grid = ButtonMapGrid(
        appliance: kTestAppliance,
        steps: steps,
        completed: 1,
        active: true,
      );
      expect(grid.stateOf('BT-08'), ButtonMapStepState.done);
      expect(grid.stateOf('BT-03'), ButtonMapStepState.current);
      expect(grid.stateOf('BT-05'), ButtonMapStepState.pending);
    });

    test('멈췄거나 실패한 실행에는 지금 버튼을 지어내지 않는다', () {
      final grid = ButtonMapGrid(
        appliance: kTestAppliance,
        steps: steps,
        completed: 1,
      );
      expect(grid.stateOf('BT-03'), ButtonMapStepState.pending);
      expect(
        steps.map(grid.stateOf),
        isNot(contains(ButtonMapStepState.current)),
      );
    });

    test('두 번 누르는 버튼은 남은 차례가 있으면 끝난 것이 아니다', () {
      // 즉석밥 → 1분 → 즉석밥
      const repeat = ['BT-08', 'BT-03', 'BT-08'];
      final second = ButtonMapGrid(
        appliance: kTestAppliance,
        steps: repeat,
        completed: 1,
        active: true,
      );
      expect(second.stateOf('BT-08'), ButtonMapStepState.pending);
      final third = ButtonMapGrid(
        appliance: kTestAppliance,
        steps: repeat,
        completed: 2,
        active: true,
      );
      expect(third.stateOf('BT-08'), ButtonMapStepState.current);
      expect(third.stateOf('BT-03'), ButtonMapStepState.done);
    });

    testWidgets('두 번 누르는 버튼은 순서 번호를 둘 다 적는다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ButtonMapGrid(
            appliance: kTestAppliance,
            steps: const ['BT-08', 'BT-03', 'BT-08'],
          ),
        ),
      ));
      expect(find.text('1·3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('큰 글씨(200%)에서 긴 버튼 이름이 칸에 잘리지 않는다', (tester) async {
      // 칸 높이를 52로 고정하면 두 줄이 된 '냉동식품'이 칸 밖으로 잘렸다 --
      // Stack은 넘쳐도 오류를 내지 않아서 레이아웃 테스트가 잡지 못한다.
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 1600),
            textScaler: TextScaler.linear(2.0),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: ButtonMapGrid(appliance: kTestAppliance, steps: steps),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      for (final label in ['냉동식품', '즉석밥', '1분']) {
        // 글자 상자는 칸의 제약에 맞춰 잘린 크기로 보고된다. 실제로 그려야
        // 하는 글자 높이가 상자에 들어가는지를 본다.
        final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
        expect(paragraph.textSize.height,
            lessThanOrEqualTo(paragraph.size.height + 0.5),
            reason: label);
      }
    });
  });
}
