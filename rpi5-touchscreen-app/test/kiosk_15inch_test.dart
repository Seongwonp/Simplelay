// 15.8형 패널(제품 사양표 1920x1080 @60Hz) — 모든 상태·오버레이가 캔버스 확대 뒤에도
// 넘치지 않고, 확대된 좌표에서 조작이 닿는다. 800x480 회귀 테스트는 각 화면 테스트에
// 그대로 있고, 여기서는 15인치만 본다(docs/하드웨어-연결-설계.md §0-1).
//
// 실기기에서만 알 수 있는 것(터치 패널의 실제 좌표 보정, 가장자리 인식)은 여기서
// 증명하지 않는다 — 소프트웨어 확대 변환이 히트테스트를 어긋나게 하지 않는다는 것까지다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

const _panel = Size(1920, 1080);
// 가장자리 48px을 비운 1824x984 안에서 세로가 먼저 닿는다 — 984/480 = 2.05.
const _inset = KioskCanvas.edgeInset;
const _scale = (1080 - 2 * _inset) / 480;

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
      '평소': () => KioskIdleView(
            now: DateTime(2026, 9, 30, 7, 8),
            connected: true,
            ambient: const AmbientInfo(
              greeting: '좋은 아침이에요.',
              tip: AmbientTip(
                  kind: 'rain',
                  text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.',
                  icon: 'rain'),
              hourly: [
                AmbientHour(label: '오전 9시', icon: 'partly', temp: 16),
                AmbientHour(label: '낮 12시', icon: 'cloudy', temp: 18),
                AmbientHour(
                    label: '오후 3시', icon: 'rain', pop: 70, precip: true),
                AmbientHour(
                    label: '오후 6시', icon: 'rain', pop: 60, precip: true),
              ],
            ),
            connections: const [
              ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
              ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
            ],
            appliances: const [
              kMicrowaveAppliance,
              kInductionAppliance,
              _fan,
              kMicrowaveAppliance,
              kInductionAppliance,
            ],
            running: const {'custom_fan'},
            dndUntil: DateTime(2026, 9, 30, 8, 8),
            temperature: 23,
            humidity: 58,
            onSelectAppliance: (_) {},
            onOpenConnection: (_) {},
            onDndGesture: () {},
          ),
      '동작 중': () => const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'hovering_stop',
            stopButton: '취소',
            executionMode: 'mock',
            elapsed: Duration(minutes: 1, seconds: 2),
            buttonsPressed: 3,
            stopRequested: true,
            onStop: _noop,
          ),
      '동작 중 — 구동부 이상': () => const KioskHoldView(
            appliance: kMicrowaveAppliance,
            holdState: 'fault',
            stopOutcome: 'drive_fault',
            detail: '구동부 이상으로 정지 버튼을 누르지 못했어요 — 가전 전원을 직접 꺼 주세요',
            executionMode: 'real',
            elapsed: Duration.zero,
            onStop: _noop,
            onClose: _noop,
          ),
      '내 가전(루틴)': () => KioskManualView(
            appliance: kInductionAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [
              KioskRoutine(id: 'a', name: '저녁 국 데우기', pressCount: 4),
              KioskRoutine(id: 'b', name: '알림만 받는 긴 이름의 루틴입니다', mode: 'notify'),
            ],
            onRoutine: (_) {},
          ),
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
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            onDismiss: () {},
          ),
      '완료 — 몰라요': () => KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
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

void _noop() {}

void main() {
  group('모든 상태·오버레이가 15인치에서 넘치지 않는다', () {
    for (final entry in _screens().entries) {
      for (final textScale in const [1.0, 1.22]) {
        testWidgets('${entry.key} · 글씨 $textScale배', (tester) async {
          await _pump15(tester, entry.value(), textScale: textScale);

          expect(tester.takeException(), isNull);
          // 캔버스가 화면을 채우고, 가장자리 여백 안쪽에 2.05배로 그려진다
          expect(tester.getSize(find.byType(KioskCanvas)), _panel);
          final body = tester.getRect(find.byType(Scaffold));
          expect(body.width, closeTo(KioskCanvas.design.width * _scale, 1));
          expect(body.height, closeTo(_panel.height - 2 * _inset, 1));
          expect(body.top, closeTo(_inset, 1));
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
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '시작',
          currentAttempt: 1,
          completedSteps: 1,
          totalSteps: 3,
          verificationConfidence: 0.93,
          verificationDetail: null,
          onStop: () => stops++,
        ),
      );

      await _tapAt(tester, find.text('정지'));

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
      expect(pressed, isEmpty); // 누르기 전에 한 번 묻는다
      await _tapAt(tester, find.text('누르기'));
      expect(pressed, ['시작']);

      // 왼쪽 위 돌아가기도 확대 뒤 같은 자리에서 닿고, 가장자리 여백 안쪽이다
      final back = find.bySemanticsLabel('대기 화면으로 돌아가기');
      final corner = tester.getRect(back);
      expect(corner.center.dx, lessThan(_panel.width / 4));
      expect(corner.center.dy, lessThan(_panel.height / 4));
      expect(corner.left, greaterThanOrEqualTo(_inset));
      expect(corner.top, greaterThanOrEqualTo(_inset));
      await _tapAt(tester, back);
      expect(cancels, 1);
      handle.dispose();
    });

    testWidgets('완료 — 처음 화면으로', (tester) async {
      var dismissed = 0;
      await _pump15(
        tester,
        KioskDoneView(
          success: true,
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onDismiss: () => dismissed++,
        ),
      );

      await _tapAt(tester, find.text('처음 화면으로'));

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
      await _tapAt(tester, find.text('닫기'));

      expect(minutes, [60]);
      expect(dismissed, 1);
    });

    testWidgets('위험 신호음 경보 — 안내 확인', (tester) async {
      var acknowledged = 0;
      await _pump15(
        tester,
        DangerAlertOverlay(onAcknowledge: () => acknowledged++),
      );

      await _tapAt(tester, find.text('안내를 확인했어요'));

      expect(acknowledged, 1);
    });
  });
}
