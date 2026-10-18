// 평가 7차(2026-10-18) 지적 수리 — 키오스크. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 실행·결과·비상 정지 대기 화면 왼쪽 아래가 비어 있었다 — 누를 순서(✓ 즉석밥 — ● 시작)를 왼쪽 아래에 크게,
//    비상 정지 대기에는 사람이 직접 누를 칸을 버튼판에 표시. 버튼 이름을 작은따옴표로 감싸지 않는다("시작 버튼").
// 2. 작은 팔 연결 끊김 칩 아래 '눌러서 해결 방법 보기'. 본체에 닿지 않는데 칩이 '모두 정상'이면 안 된다.
// 3. 아이콘 규칙: 조용한 시간 = 달(bedtime), 잠시 쉬기 = 일시정지(pause_circle).
// 4. 눌렸는지 모르는 결과: '한 번 더 하기' 바로 위 '가전을 보고 안 됐을 때만 다시 하세요', 한 번 더 하기는 글자 단추(약한 위계).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(800, 480)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

const _estopDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
];

KioskIdleView _idle({
  bool connected = true,
  List<ConnectionItem> connections = _ok,
  ValueChanged<ConnectionItem>? onOpen,
  DateTime? dndUntil,
  String? quietUntil,
}) =>
    KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 8),
      connected: connected,
      connections: connections,
      appliances: const [kMicrowaveAppliance],
      dndUntil: dndUntil,
      quietUntil: quietUntil,
      onSelectAppliance: (_) {},
      onOpenConnection: onOpen ?? (_) {},
      onDndGesture: () {},
    );

void main() {
  group('1. 왼쪽 아래 빈자리 — 누를 순서, 따옴표 없는 버튼 이름', () {
    testWidgets('실행: 큰 버튼 이름은 "시작 버튼", 왼쪽 아래에 누를 순서(✓ 즉석밥 → 지금 시작)', (tester) async {
      await _pump(
          tester,
          KioskExecutingView(
            title: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            lastButtons: null,
            currentButton: '시작',
            currentAttempt: 1,
            completedSteps: 1,
            doneButtons: const ['즉석밥'],
            totalSteps: 2,
            verificationConfidence: 0.9,
            verificationDetail: null,
            onStop: () {},
          ));
      expect(find.text("'시작'"), findsNothing);
      expect(find.text('시작 버튼'), findsOneWidget);
      final trail = find.byKey(const ValueKey('exec-step-trail'));
      expect(trail, findsOneWidget);
      expect(find.byKey(const ValueKey('step-0-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('step-1-current')), findsOneWidget);
      // 왼쪽 아래를 채운다 — 화면 아래쪽 1/3 안, 정지 단추 왼쪽.
      final r = tester.getRect(trail);
      expect(r.bottom, greaterThan(480 * 2 / 3));
      expect(r.right, lessThan(tester.getRect(find.byKey(const ValueKey('kiosk-stop-area'))).left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('결과(버튼판 표시): 왼쪽 아래에 누른 순서 두 칸', (tester) async {
      await _pump(
          tester,
          const KioskDoneView(
            success: true,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: 'real',
            resultConfirmation: 'reported',
            pressed: [
              KioskButtonResult(button: '즉석밥', success: true),
              KioskButtonResult(button: '시작', success: true),
            ],
          ));
      final trail = find.byKey(const ValueKey('done-step-trail'));
      expect(trail, findsOneWidget);
      expect(find.byKey(const ValueKey('step-0-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('step-1-done')), findsOneWidget);
      expect(tester.getRect(trail).bottom, greaterThan(480 / 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('비상 버튼 정지 대기: 직접 누를 칸을 버튼판에, 따옴표 없는 할 일', (tester) async {
      await _pump(
          tester,
          KioskEstopLayout(
            banner: KioskEstopBanner(detail: _estopDetail, onRequest: () {}),
            child: const KioskHoldView(
              appliance: kMicrowaveAppliance,
              holdState: 'hovering_stop',
              stopButton: '취소',
              executionMode: 'real',
              elapsed: Duration(minutes: 1),
              onStop: _noop,
              estopTitle: '비상 버튼이 눌려 있어요',
            ),
          ));
      expect(find.byKey(const ValueKey('panel-picture')), findsOneWidget);
      expect(find.text('전자레인지의 취소 버튼을 직접 눌러 주세요'), findsOneWidget);
      expect(find.textContaining("'취소'"), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('2. 연결 문제 — 다음 행동, 끊겼는데 모두 정상 금지', () {
    testWidgets('작은 팔 연결 끊김: 칩 근처 "눌러서 해결 방법 보기" — 누르면 그 연결 창', (tester) async {
      ConnectionItem? opened;
      await _pump(
          tester,
          _idle(
              connections: const [
                ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
                ConnectionItem(id: 'press', state: 'error', title: '작은 팔과 연결이 끊겼어요', message: ''),
              ],
              onOpen: (i) => opened = i));
      final help = find.byKey(const ValueKey('idle-problem-help'));
      expect(help, findsOneWidget);
      expect(find.text('눌러서 해결 방법 보기'), findsOneWidget);
      final chip = tester.getRect(find.byKey(const ValueKey('idle-status-chip')));
      final h = tester.getRect(help);
      expect((h.center.dx - chip.center.dx).abs(), lessThan(chip.width));
      expect(h.top - chip.bottom, lessThan(40));
      await tester.tap(help);
      await tester.pump();
      expect(opened?.id, 'press');
      expect(tester.takeException(), isNull);
    });

    testWidgets('모두 괜찮으면 해결 방법 줄이 없다', (tester) async {
      await _pump(tester, _idle());
      expect(find.text('모두 정상'), findsOneWidget);
      expect(find.byKey(const ValueKey('idle-problem-help')), findsNothing);
    });

    testWidgets('본체에 닿지 않으면(connected=false) 지난 목록이 다 괜찮아도 "모두 정상"이 아니다', (tester) async {
      await _pump(tester, _idle(connected: false));
      expect(find.text('모두 정상'), findsNothing);
      expect(find.text('본체와 연결이 끊겼어요'), findsOneWidget);
    });
  });

  group('3. 아이콘 — 조용한 시간 = 달, 잠시 쉬기 = 일시정지', () {
    testWidgets('메뉴의 잠시 쉬기는 일시정지 아이콘, 달 아이콘 없음', (tester) async {
      await _pump(tester, _idle());
      await tester.tap(find.byKey(const ValueKey('idle-menu')));
      await tester.pump();
      final entry = find.byKey(const ValueKey('dnd-entry'));
      expect(find.descendant(of: entry, matching: find.byIcon(Icons.pause_circle_outline)), findsOneWidget);
      expect(find.byIcon(Icons.bedtime_outlined), findsNothing);
      expect(find.byIcon(Icons.bedtime), findsNothing);
    });

    testWidgets('쉬는 중 칩은 일시정지, 조용한 시간 칩은 달', (tester) async {
      await _pump(tester, _idle(dndUntil: DateTime(2026, 9, 30, 8, 0)));
      final chip = find.byKey(const ValueKey('dnd-chip'));
      expect(find.descendant(of: chip, matching: find.byIcon(Icons.pause_circle)), findsOneWidget);
      expect(find.descendant(of: chip, matching: find.byIcon(Icons.bedtime)), findsNothing);

      await _pump(tester, _idle(quietUntil: '07:00'));
      final quiet = find.byKey(const ValueKey('dnd-chip'));
      expect(find.descendant(of: quiet, matching: find.byIcon(Icons.bedtime)), findsOneWidget);
    });

    testWidgets('잠시 쉬기 창 제목에 일시정지 아이콘, 조용한 시간 줄에 달', (tester) async {
      await _pump(
          tester,
          DndOverlay(
              dndUntil: null,
              quietSchedule: ('22:00', '07:00'),
              onSet: (_) {},
              onClear: () {},
              onDismiss: () {}));
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.bedtime_outlined), findsOneWidget);
    });
  });

  group('4. 눌렸는지 모르는 결과 — 한 번 더 하기는 약하게, 바로 위 한 줄', () {
    testWidgets('한 번 더 하기 옆 안내 한 줄(평가 12차), 작은 테두리 단추로 처음 화면으로보다 약하다', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: 'real',
            onRetry: () {},
            onManual: () {},
            onDismiss: () {},
          ));
      final hint = find.byKey(const ValueKey('done-retry-hint'));
      expect(hint, findsOneWidget);
      expect(find.text('가전을 보고 안 됐을 때만 다시 하세요'), findsOneWidget);
      final retry = find.byKey(const ValueKey('done-retry'));
      final hr = tester.getRect(hint);
      final rr = tester.getRect(retry);
      // 평가 12차(10/18): 안내 문장 바로 옆 같은 줄(주 출구 하나 + 보조 묶음) — 따로 떨어진 세 번째 출구로 보이지 않게.
      expect((hr.center.dy - rr.center.dy).abs(), lessThan(4));
      expect(rr.left, greaterThanOrEqualTo(hr.right - 0.5));
      expect(rr.left - hr.right, lessThan(60));
      // 평가 13차(10/18): 글자 단추는 꺼진 단추로 보였다 — 작은 테두리 보조 단추. 처음 화면으로(채움)보다 낮다.
      expect(tester.widget(retry), isA<OutlinedButton>());
      expect(rr.height, lessThan(tester.getRect(find.byKey(const ValueKey('done-home'))).height));
      expect(tester.takeException(), isNull);
    });

    testWidgets('다시 보낼 요청이 없으면 안내 줄도 없다', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
            success: false,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            executionMode: 'real',
            onManual: () {},
            onDismiss: () {},
          ));
      expect(find.byKey(const ValueKey('done-retry-hint')), findsNothing);
    });
  });
}

void _noop() {}
