// 키오스크 직접 써 보기 점검(2026-10-24 QA) — 버튼판이 아래 탭에 가리지 않고, 빈 '내 루틴' 머리를 두지 않으며,
// 계속 조작은 보던 판으로, 준비 안 된 판은 눌리지 않게 보인다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

import 'kiosk_phase_test.dart' show FakeEventStream, FakeKioskApi, FakeTts;

const _routine30 = KioskRoutine(id: 'rt-30s', name: '30초 데우기', applianceIds: ['microwave'], pressCount: 2);

Future<FakeKioskApi> _pumpKiosk(WidgetTester tester,
    {Size size = const Size(800, 480), List<ApplianceMap>? appliances}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = FakeKioskApi()
    ..applianceList = appliances ?? [kMicrowaveAppliance, kInductionAppliance]
    ..routinesResult = const [_routine30];
  await tester.pumpWidget(MaterialApp(home: KioskScreen(api: api, tts: FakeTts(), events: FakeEventStream())));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return api;
}

final _tabs = find.byKey(const ValueKey('kiosk-tab-bar'));

Future<void> _openBoard(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('strip-microwave')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(const ValueKey('manual-pick-buttons')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('버튼판이 아래 탭 위에 다 들어간다', () {
    for (final size in const [Size(800, 480), Size(1920, 1080)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 전자레인지 버튼판 맨 아래 줄(취소·시작)', (tester) async {
        await _pumpKiosk(tester, size: size);
        await _openBoard(tester);
        expect(tester.takeException(), isNull);
        expect(_tabs, findsOneWidget);
        final bar = tester.getRect(_tabs);
        for (final label in ['취소', '시작', '10초']) {
          final cell = find.byKey(ValueKey('manual-cell-$label'));
          expect(cell, findsOneWidget);
          final r = tester.getRect(cell);
          expect(r.bottom, lessThanOrEqualTo(bar.top + 0.5), reason: '$label 칸이 아래 탭에 걸린다 $r / $bar');
          expect(cell.hitTestable(), findsOneWidget, reason: '$label 칸이 눌리지 않는다(가려짐)');
        }
        // 판이 스크롤로 숨지 않는다 — 스크롤할 자리가 없다.
        final scrollable = find.descendant(of: find.byType(KioskManualView), matching: find.byType(Scrollable));
        for (final s in tester.stateList<ScrollableState>(scrollable)) {
          expect(s.position.maxScrollExtent, lessThanOrEqualTo(0.5), reason: '버튼판이 넘쳐 스크롤된다');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  });

  testWidgets("저장된 동작에서 연 버튼판에는 빈 '내 루틴' 머리가 없다", (tester) async {
    await _pumpKiosk(tester);
    await _openBoard(tester);
    expect(find.text('내 루틴'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets("루틴이 없는 가전은 '내 루틴' 머리와 '아직 없어요' 안내가 함께", (tester) async {
    await _pumpKiosk(tester);
    await tester.tap(find.byKey(const ValueKey('strip-induction')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('내 루틴'), findsOneWidget);
    expect(find.text('이 가전에는 아직 루틴이 없어요'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('버튼판에서 누른 결과의 계속 조작은 버튼판으로 돌아간다', (tester) async {
    final api = await _pumpKiosk(tester);
    await _openBoard(tester);
    await tester.tap(find.byKey(const ValueKey('manual-cell-해동')));
    await tester.pump();
    await tester.tap(find.text('누르기'));
    await tester.pump();
    api.statusResult = const KioskStatus(
        running: false,
        lastJobId: 'job-1',
        lastStatus: 'succeeded',
        lastExecutionMode: 'real',
        lastOperationConfirmed: true,
        lastOperationSource: 'real');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(KioskDoneView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('done-continue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KioskManualView), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-cell-해동')), findsOneWidget, reason: '보던 버튼판으로');
    expect(find.byKey(const ValueKey('manual-pick-buttons')), findsNothing);
    expect(api.executeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('준비 안 된 가전의 버튼은 흐리게·누를 수 없게 보인다', (tester) async {
    const notReady = ApplianceMap(
      id: 'induction',
      name: '인덕션',
      category: 'induction',
      rows: 3,
      cols: 4,
      buttons: [
        ApplianceButton(id: 'IN-01', label: '전원', x: 0, y: 0),
        ApplianceButton(id: 'IN-09', label: '시작', x: 2, y: 2),
      ],
      canExecute: false,
      readiness: 'needs_calibration',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskManualView(appliance: notReady, onExecute: (_) {}, onCancel: () {}, routines: const []),
      ),
    ));
    final cell = find.byKey(const ValueKey('manual-cell-전원'));
    expect(cell, findsOneWidget);
    // 칸 전체가 흐리다(글자만이 아니라 테두리·바탕까지) — 눌리는 칸처럼 보이지 않게.
    final opacity = find.ancestor(of: find.text('전원'), matching: find.byType(Opacity));
    expect(opacity, findsWidgets);
    expect(tester.widget<Opacity>(opacity.first).opacity, lessThan(1.0));
    expect(find.descendant(of: cell, matching: find.byType(InkWell)), findsNothing, reason: '눌림 잉크가 없다');
  });
}
