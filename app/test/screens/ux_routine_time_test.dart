import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/services/routine_time_hint.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import '../helpers/test_helpers.dart';

void main() {
  final button = kTestAppliance.buttons.first;
  final draft = Routine(name: '아침 루틴', steps: [RoutineStep.press(kTestAppliance.id, [button.id])], trigger: const RoutineTrigger.manual());
  List<RpiHistoryEntry> records({String mode = 'real', String status = 'succeeded'}) => [
    for (var d = 1; d <= 4; d++) RpiHistoryEntry(
      jobId: '$d', finishedAt: DateTime.now().subtract(Duration(days: d)).copyWith(hour: 7, minute: 10),
      status: status, executionMode: mode, retryCount: 0, applianceId: kTestAppliance.id,
      buttons: [RpiHistoryButton(button: button.label, success: true, attempts: 1)],
    ),
  ];

  test('모의·실패·적은 기록은 시각 근거로 쓰지 않아요', () {
    for (final history in [records(mode: 'mock'), records(status: 'failed'), records().take(2).toList()]) {
      expect(routineTimeHint(draft, [kTestAppliance], history, DateTime.now()), isNull);
    }
    expect(routineTimeHint(draft, [kTestAppliance], records(), DateTime.now())!.time, '07:10');
  });

  testWidgets('기록 시각은 제안하고 직접 선택한 값을 유지해요', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildScreen(RoutineEditorScreen(initial: draft), overrides: [
      ...installedOverrides([kTestAppliance]),
      historyProvider.overrideWith((_) async => records()),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('오전 7:10로 정하기'), findsOneWidget);
    await tester.tap(find.text('필요할 때 하기로 정하기'));
    await tester.pump();
    expect(find.text('오전 7:10로 정하기'), findsNothing);
    expect(find.text('직접 실행할 때'), findsOneWidget);
  });

  testWidgets('근거가 없으면 실행 시각을 물어요', (tester) async {
    await tester.pumpWidget(buildScreen(RoutineEditorScreen(initial: draft), overrides: [
      ...installedOverrides([kTestAppliance]), historyProvider.overrideWith((_) async => []),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('언제 실행할지 골라 주세요.'), findsOneWidget);
  });
}
