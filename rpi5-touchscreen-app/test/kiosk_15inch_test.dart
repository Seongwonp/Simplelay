// 15.8형 패널(제품 사양표 1920x1080 @60Hz) — 모든 상태·오버레이가 캔버스 확대 뒤에도
// 넘치지 않고, 확대된 좌표에서 조작이 닿는다. 800x480 회귀 테스트는 각 화면 테스트에
// 그대로 있고, 여기서는 15인치만 본다(docs/하드웨어-연결-설계.md §0-1).
//
// 실기기에서만 알 수 있는 것(터치 패널의 실제 좌표 보정, 가장자리 인식)은 여기서
// 증명하지 않는다 — 소프트웨어 확대 변환이 히트테스트를 어긋나게 하지 않는다는 것까지다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

const _panel = Size(1920, 1080);
const _scale = 1080 / 480; // 2.25 — 세로가 먼저 닿는다

Future<void> _pump15(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = _panel;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: KioskCanvas(
            child: Scaffold(backgroundColor: KioskColors.bg, body: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// 화면 위 실제 좌표로 그 위젯의 중심을 누른다 — 확대 변환을 통과한 탭.
Future<void> _tapAt(WidgetTester tester, Finder finder) async {
  final center = tester.getCenter(finder);
  expect((Offset.zero & _panel).contains(center), isTrue,
      reason: '화면 밖 좌표 $center');
  await tester.tapAt(center);
  await tester.pump();
}

const _fan = ApplianceMap(
  id: 'custom_fan',
  name: '거실 선풍기',
  category: 'other',
  rows: 1,
  cols: 2,
  buttons: [
    ApplianceButton(id: 'F-01', label: '전원', x: 0, y: 0),
    ApplianceButton(id: 'F-02', label: '약풍', x: 1, y: 0),
  ],
);

Map<String, Widget Function()> _screens() => {
      '가전 선택': () => KioskApplianceSelectView(
            appliances: const [kMicrowaveAppliance, kInductionAppliance, _fan],
            lastUsedId: 'microwave',
            onSelect: (_) {},
            onCancel: () {},
          ),
      '실행': () => KioskExecutingView(
            title: '냉동 만두 데워서 라면이랑 같이 먹을 준비',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '냉동식품',
            currentAttempt: 2,
            completedSteps: 2,
            totalSteps: 6,
            verificationConfidence: null,
            verificationDetail: null,
            onStop: () {},
          ),
      '완료': () => KioskDoneView(
            success: true,
            label: '우유 데워줘',
            target: kMicrowaveAppliance,
            onDismiss: () {},
          ),
      '완료 — 확인 못 함': () => KioskDoneView(
            success: false,
            label: '우유 데워줘',
            target: kMicrowaveAppliance,
            onRetry: () {},
            onManual: () {},
            onDismiss: () {},
          ),
      '수동 조작': () => KioskManualView(
            appliance: kInductionAppliance,
            onExecute: (_) {},
            onCancel: () {},
          ),
      '방해 금지': () => DndOverlay(
            dndUntil: null,
            onSet: (_) {},
            onClear: () {},
            onDismiss: () {},
          ),
      '위험 신호음 경보': () => DangerAlertOverlay(onAcknowledge: () {}),
    };

void main() {
  group('모든 상태·오버레이가 15인치에서 넘치지 않는다', () {
    for (final entry in _screens().entries) {
      for (final textScale in const [1.0, 1.22]) {
        testWidgets('${entry.key} · 글씨 $textScale배', (tester) async {
          await _pump15(tester, entry.value(), textScale: textScale);

          expect(tester.takeException(), isNull);
          // 캔버스가 화면을 채우고, 안쪽은 2.25배로 그려진다
          expect(tester.getSize(find.byType(KioskCanvas)), _panel);
          final body = tester.getRect(find.byType(Scaffold));
          expect(body.width, closeTo(KioskCanvas.design.width * _scale, 1));
          expect(body.height, closeTo(_panel.height, 1));
          expect(body.left, closeTo((_panel.width - body.width) / 2, 1));
        });
      }
    }
  });

  group('확대된 좌표에서 조작이 닿는다', () {
    testWidgets('실행 — 긴급 정지', (tester) async {
      var stops = 0;
      await _pump15(
        tester,
        KioskExecutingView(
          title: '우유 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '시간 90초',
          currentAttempt: 1,
          completedSteps: 1,
          totalSteps: 3,
          verificationConfidence: 0.93,
          verificationDetail: null,
          onStop: () => stops++,
        ),
      );

      await _tapAt(tester, find.text('긴급 정지'));

      expect(stops, 1);
    });

    testWidgets('가전 선택 — 카드', (tester) async {
      final selected = <String>[];
      await _pump15(
        tester,
        KioskApplianceSelectView(
          appliances: const [kMicrowaveAppliance, _fan],
          lastUsedId: 'microwave',
          onSelect: (a) => selected.add(a.id),
          onCancel: () {},
        ),
      );

      await _tapAt(tester, find.text('거실 선풍기'));
      expect(selected, ['custom_fan']);
    });

    testWidgets('수동 조작 — 버튼 칸과 왼쪽 위 돌아가기', (tester) async {
      final handle = tester.ensureSemantics();
      final pressed = <String>[];
      var cancels = 0;
      await _pump15(
        tester,
        KioskManualView(
          appliance: kMicrowaveAppliance,
          onExecute: (b) => pressed.add(b.label),
          onCancel: () => cancels++,
        ),
      );

      final start = find.bySemanticsLabel('시작 버튼 누르기');
      await _tapAt(tester, start);
      expect(pressed, ['시작']);

      // 화면 가장자리 가까운 조작도 확대 뒤 같은 자리에서 닿는다
      final back = find.bySemanticsLabel('대기 화면으로 돌아가기');
      final corner = tester.getCenter(back);
      expect(corner.dx, lessThan(_panel.width / 4));
      expect(corner.dy, lessThan(_panel.height / 4));
      await _tapAt(tester, back);
      expect(cancels, 1);
      handle.dispose();
    });

    testWidgets('완료 — 처음으로', (tester) async {
      var dismissed = 0;
      await _pump15(
        tester,
        KioskDoneView(
          success: true,
          label: '우유 데워줘',
          target: kMicrowaveAppliance,
          onDismiss: () => dismissed++,
        ),
      );

      await _tapAt(tester, find.text('처음으로'));

      expect(dismissed, 1);
    });

    testWidgets('방해 금지 — 선택지와 취소', (tester) async {
      final minutes = <int>[];
      var dismissed = 0;
      await _pump15(
        tester,
        DndOverlay(
          dndUntil: null,
          onSet: minutes.add,
          onClear: () {},
          onDismiss: () => dismissed++,
        ),
      );

      await _tapAt(tester, find.text('1시간'));
      await _tapAt(tester, find.text('취소'));

      expect(minutes, [60]);
      expect(dismissed, 1);
    });

    testWidgets('위험 신호음 경보 — 안내 확인', (tester) async {
      var acknowledged = 0;
      await _pump15(
        tester,
        DangerAlertOverlay(onAcknowledge: () => acknowledged++),
      );

      await _tapAt(tester, find.text('안내를 확인했습니다'));

      expect(acknowledged, 1);
    });
  });
}
