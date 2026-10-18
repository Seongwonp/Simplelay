// 가전 회사 제품 디자인 리드 출시 검토(10/18, 본체 72점)에서 나온 키오스크 문제 — 단정 시험.
//
// 1. 연습의 확인 필요(연습 실패)는 노란색이 아니라 연습 색(청록) — 제목 색과 위 띠 모두.
// 2. 날씨 예보 칸 — 비 %가 없는 날은 칸을 내용에 맞춰 줄이고, 칸끼리는 늘 같은 높이.
//    직접 누르기 판의 버튼 없는 자리는 점선 칸이 아니라 테두리 없는 흐린 '버튼 없음'.
// 3. 실행 중 — '누를 순서'를 상태 제목 바로 아래로 올리고 크게(동그라미 60px 이상), 버튼판 위 안내는 한 줄.
// 4. '지금 못 써요'는 비상 버튼이든 누름 장치 끊김이든 같은 모양(빨강·느낌표).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/practice_band.dart';

Finder _plain(String text, {bool contains = false}) => find.byWidgetPredicate((w) {
      if (w is! RichText) return false;
      final t = w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ');
      return contains ? t.contains(text) : t == text;
    });

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

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

KioskIdleView _idle(AmbientInfo ambient) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: ambient,
      connections: _ok,
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      running: const {},
      on: const {},
      off: const {},
      attention: const {},
      temperature: 23,
      humidity: 58,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

const _dry = AmbientInfo(
  greeting: '좋은 아침이에요.',
  weatherSource: 'kma',
  now: AmbientHour(label: '지금', hour: 7, icon: 'clear', temp: 14),
  hourly: [
    AmbientHour(label: '9시', hour: 9, icon: 'partly', temp: 14),
    AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 16),
    AmbientHour(label: '15시', hour: 15, icon: 'clear', temp: 15),
  ],
);

const _wet = AmbientInfo(
  greeting: '좋은 아침이에요.',
  weatherSource: 'kma',
  now: AmbientHour(label: '지금', hour: 7, icon: 'cloudy', temp: 14),
  hourly: [
    AmbientHour(label: '9시', hour: 9, icon: 'cloudy', temp: 14),
    AmbientHour(label: '12시', hour: 12, icon: 'rain', temp: 16, pop: 70, precip: true),
    AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 15, pop: 60, precip: true),
  ],
);

List<double> _cellHeights(WidgetTester tester) => [
      for (var i = 0; i < 4; i++)
        if (find.byKey(ValueKey('ambient-hour-$i')).evaluate().isNotEmpty)
          tester.getSize(find.byKey(ValueKey('ambient-hour-$i'))).height,
    ];

void main() {
  testWidgets('1. 연습 실패(확인 필요)는 연습 색 — 제목 청록, 위 띠는 연습 띠', (tester) async {
    await _pump(
        tester,
        KioskDoneView(
          success: false,
          executionMode: 'mock',
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onRetry: () {},
          onManual: () {},
          onDismiss: () {},
        ));
    final title = _plain(kPracticeStoppedHeadline);
    expect(title, findsOneWidget);
    final color = tester.widget<RichText>(title).text.style?.color ??
        (tester.widget<RichText>(title).text as TextSpan).children?.first.style?.color;
    expect(color, KioskColors.practice);
    expect(color, isNot(KioskColors.warning));
    final band = find.byKey(const ValueKey('status-band'));
    final box = tester.widget<Container>(band).decoration as BoxDecoration;
    expect((box.border as Border).left.color, KioskColors.practice, reason: '띠도 앰버가 아니라 청록');
    expect(_plain(kPracticeRealUnchanged), findsOneWidget);
  });

  testWidgets('1. 실제 실행의 확인 필요는 그대로 앰버(연습만 청록)', (tester) async {
    await _pump(
        tester,
        KioskDoneView(
          success: false,
          executionMode: 'real',
          label: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          onDismiss: () {},
        ));
    final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere(
        (r) => r.text.toPlainText().replaceAll('⁠', '').contains('몰라요'));
    final color = rich.text.style?.color ?? (rich.text as TextSpan).children?.first.style?.color;
    expect(color, KioskColors.warning);
  });

  testWidgets('1. 누름 장치 결과는 성공·확인 필요 모두 같은 자리에 누른 순서와 버튼판(지키는 시험)', (tester) async {
    const pressed = [KioskButtonResult(button: '즉석밥', success: true), KioskButtonResult(button: '시작', success: false)];
    Rect? trailOk, panelOk;
    for (final success in [true, false]) {
      await _pump(
          tester,
          KioskDoneView(
            success: success,
            executionMode: 'real',
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            pressed: success
                ? const [KioskButtonResult(button: '즉석밥', success: true), KioskButtonResult(button: '시작', success: true)]
                : pressed,
            onDismiss: () {},
          ));
      final panel = tester.getRect(find.byKey(const ValueKey('done-panel-caption')));
      if (success) {
        trailOk = tester.getRect(find.byKey(const ValueKey('done-step-trail')));
        panelOk = panel;
      } else {
        // 버튼판은 같은 자리. 번호 안내가 있는 확인 필요에서는 누른 순서 줄 대신 안내가 왼쪽을 다 쓴다(셋째 줄이 잘리지 않게).
        expect(panel.left, closeTo(panelOk!.left, 1));
        expect(panel.top, closeTo(panelOk.top, 1));
        expect(find.byKey(const ValueKey('done-step-trail')), findsNothing);
        final third = find.byKey(const ValueKey('done-recovery-step-2'));
        if (third.evaluate().isNotEmpty) {
          expect(tester.getRect(third).bottom, lessThan(480));
        }
        expect(trailOk, isNotNull);
      }
    }
  });

  testWidgets('2. 비 %가 없는 날 예보 칸은 줄어들고, 칸끼리는 늘 같은 높이', (tester) async {
    await _pump(tester, _idle(_wet));
    final wet = _cellHeights(tester);
    expect(wet.length, greaterThanOrEqualTo(3));
    for (final h in wet) {
      expect(h, closeTo(wet.first, 0.5));
    }
    await _pump(tester, _idle(_dry));
    final dry = _cellHeights(tester);
    for (final h in dry) {
      expect(h, closeTo(dry.first, 0.5));
    }
    expect(dry.first, lessThan(wet.first - 10), reason: '비 % 줄 자리를 비워 두지 않는다');
  });

  testWidgets("2. 직접 누르기 판의 버튼 없는 자리 — 점선 없이 흐린 '버튼 없음'", (tester) async {
    await _pump(
        tester,
        KioskManualView(appliance: kMicrowaveAppliance, onExecute: (_) {}, onCancel: () {}));
    final empty = find.byKey(const ValueKey('manual-empty-2-1'));
    expect(empty, findsOneWidget);
    expect(find.descendant(of: empty, matching: find.text(kManualNoButton)), findsOneWidget);
    expect(find.descendant(of: empty, matching: find.byType(CustomPaint)), findsNothing);
  });

  testWidgets('3. 실행 중 — 누를 순서는 상태 제목 바로 아래(진행 줄보다 위), 동그라미 크게, 안내 한 줄', (tester) async {
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
          verificationConfidence: null,
          verificationDetail: null,
          onStop: () {},
        ));
    final trail = find.byKey(const ValueKey('exec-step-trail'));
    expect(trail, findsOneWidget);
    final progress = find.byKey(const ValueKey('execution-step'));
    expect(tester.getRect(trail).top, lessThan(tester.getRect(progress).top));
    final dot = tester.getSize(find.descendant(
        of: find.byKey(const ValueKey('step-1-current')), matching: find.byType(Container)).first);
    expect(dot.width, greaterThanOrEqualTo(60));
    expect(find.text(kExecPanelCaption), findsOneWidget);
    expect(kExecPanelCaption, '화면은 누르지 않아도 돼요');
    expect(find.textContaining('누름 장치가 누르는 자리예요'), findsNothing);
  });

  testWidgets("4. 가전 고르기의 이름은 낱말 단위로 줄을 바꾼다('연습 전자레인/지' 금지)", (tester) async {
    final practice = applianceFromServerJson({
      'id': 'pmw',
      'name': '전자레인지(연습)',
      'category': 'microwave',
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
    });
    await _pump(
        tester,
        KioskApplianceSelectView(
            appliances: [practice, kMicrowaveAppliance], lastUsedId: null, onSelect: (_) {}, onCancel: () {}));
    final name = find.byKey(const ValueKey('appliance-select-name-pmw'));
    expect(name, findsOneWidget);
    final t = tester.widget<Text>(name);
    final raw = t.data ?? t.textSpan!.toPlainText(includeSemanticsLabels: false);
    // 낱말 안 글자 사이에 단어 잇기 문자 — 낱말 가운데서 줄이 바뀌지 않는다.
    expect(raw, contains('전⁠자'));
    expect(raw.replaceAll('⁠', '').replaceAll(' ', ' '), '연습 전자레인지');
  });

  // 사용자 결정(10/19): 띠 대신 같은 '!' 표시 — 이유는 표시 문장이 말한다.
  test("4. 쓸 수 없음 — 비상 버튼과 누름 장치 끊김이 같은 '!' 모양", () {
    final estop = kioskTileIssue(kMicrowaveAppliance, unavailable: true, unavailableByEstop: true)!;
    final link = kioskTileIssue(kMicrowaveAppliance, unavailable: true)!;
    expect(link.mark, estop.mark);
    expect(link.mark, KioskTileMark.unusable);
    expect(estop.text, kTileUnusableEstop);
    expect(link.text, kTileUnusablePress);
  });
}
