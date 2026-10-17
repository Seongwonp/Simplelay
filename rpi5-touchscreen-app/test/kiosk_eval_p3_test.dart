// 평가 3차(2026-10-18) 지적 수리 — 키오스크 3단계.
//
// 1. 결과 띠 말은 두 가지뿐: '됐어요'(초록, 실제 확인) · '확인해 주세요'(그 밖 모름·주의 전부). 같은 말 두 번 금지는
//    제목을 바꿔 지킨다. 누름 보고만(done_reported)은 띠 '확인해 주세요' / 제목 '버튼은 다 눌렀어요'(중립색).
// 2. 작은 팔 연결이 끊기면 대기 화면의 작은 팔 가전 타일은 '지금 못 써요'(흐리게, 누르면 연결 창). LG 가전은 그대로.
// 3. 대기 화면 가전 타일 줄 왼쪽 = 시계 왼쪽 선, 다음 루틴은 가운데 아래 큰 카드, 큰 글씨에서 장 넘김 글자 안 잘림.
// 4. 쉬운 말: 경보 소리·연습용 숫자·눌러 드려요·작동하고 있어요·LG 가전 설정 N번.
// 5. 실행 화면 버튼판: 끝난 칸에 ✓, 지금 칸 채움 유지, '제대로 눌렸는지 보는 중' 아이콘은 눈 하나.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/danger_alert_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_top.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
          size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: child),
    ),
  ));
  await tester.pump();
}

/// 상태 띠의 첫 글(띠 말).
String _bandWord(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('status-band')),
          matching: find.byType(Text)))
      .toList();
  return texts.first.data ?? texts.first.textSpan!.toPlainText();
}

const _thinqAir = ApplianceMap(
  id: 'air',
  name: '공기청정기',
  category: 'air_purifier',
  rows: 0,
  cols: 0,
  buttons: [],
  controlPath: 'thinq',
);

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '작은 팔이 연결돼 있어요', message: ''),
];
const _pressDown = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(
      id: 'press',
      state: 'error',
      title: '작은 팔과 연결이 끊겼어요',
      message: '작은 팔이 버튼을 누를 수 없어요.'),
];

KioskIdleView _idle({
  List<ConnectionItem> connections = _ok,
  ValueChanged<ConnectionItem>? onOpen,
  ValueChanged<ApplianceMap>? onSelect,
  List<ApplianceMap> appliances = const [kMicrowaveAppliance, kInductionAppliance, _thinqAir],
  KioskNextRun? next,
  AmbientInfo? ambient,
}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 7, 8),
      connected: true,
      connections: connections,
      appliances: appliances,
      nextRun: next,
      ambient: ambient,
      onSelectAppliance: onSelect ?? (_) {},
      onOpenConnection: onOpen ?? (_) {},
      onDndGesture: () {},
      onSettingsGesture: () {},
    );

const _rain = AmbientInfo(
  greeting: '좋은 아침이에요.',
  weatherSource: 'kma',
  tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  hourly: [
    AmbientHour(label: '9시', icon: 'cloudy', temp: 16),
    AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
    AmbientHour(label: '15시', icon: 'rain', pop: 70, precip: true),
    AmbientHour(label: '18시', icon: 'rain', pop: 60, precip: true),
  ],
);

const _next = KioskNextRun(
    name: '아침 공기청정기 끄기', dayLabel: '오늘', hhmm: '07:00', modeLabel: '자동 실행');

void main() {
  group('1. 결과 띠 말은 됐어요 · 확인해 주세요 두 가지', () {
    final cases = <String, (KioskDoneView, String)>{
      '실제 확인한 물리 성공': (
        KioskDoneView(
            executionMode: 'real',
            success: true,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            resultConfirmation: 'reported',
            operationConfirmed: true,
            operationSource: 'real',
            onDismiss: () {}),
        '됐어요'
      ),
      'LG 가전 상태로 확인': (
        KioskDoneView(
            executionMode: 'real',
            success: true,
            label: '공기청정기 강',
            route: 'thinq',
            resultConfirmation: 'state_confirmed',
            onDismiss: () {}),
        '됐어요'
      ),
      '누름 보고만': (
        KioskDoneView(
            executionMode: 'real',
            success: true,
            label: '즉석밥 데워줘',
            target: kMicrowaveAppliance,
            resultConfirmation: 'reported',
            onDismiss: () {}),
        '확인해 주세요'
      ),
      '실행 환경 모름': (
        KioskDoneView(success: true, label: '즉석밥 데워줘', onDismiss: () {}),
        '확인해 주세요'
      ),
      '눌렸는지 모름': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '즉석밥 데워줘',
            reason: KioskFailureReason.execution,
            onDismiss: () {}),
        '확인해 주세요'
      ),
      '본체 연결 끊김': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '즉석밥 데워줘',
            reason: KioskFailureReason.serverLost,
            onDismiss: () {}),
        '확인해 주세요'
      ),
      'LG 가전 못 바꿈': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '공기청정기 강',
            route: 'thinq',
            reason: KioskFailureReason.notExecuted,
            onDismiss: () {}),
        '확인해 주세요'
      ),
      'LG 가전 받았는지 모름': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '공기청정기 강',
            route: 'thinq',
            reason: KioskFailureReason.unconfirmed,
            onDismiss: () {}),
        '확인해 주세요'
      ),
      '멈춘 것 확인': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '즉석밥 데워줘',
            reason: KioskFailureReason.stopped,
            stopLevel: 'verified',
            onDismiss: () {}),
        '확인해 주세요'
      ),
      '멈추라고 보냄': (
        KioskDoneView(
            executionMode: 'real',
            success: false,
            label: '즉석밥 데워줘',
            reason: KioskFailureReason.stopped,
            stopLevel: 'sent',
            onDismiss: () {}),
        '확인해 주세요'
      ),
    };
    for (final MapEntry(key: name, value: (view, word)) in cases.entries) {
      testWidgets('$name → 띠 "$word", 같은 말은 화면에 한 번', (tester) async {
        await _pump(tester, view);
        expect(tester.takeException(), isNull);
        expect(_bandWord(tester), word);
        // 띠 말이 제목·할 일에 또 나오지 않는다(같은 말 두 번 금지).
        expect(find.textContaining(word), findsOneWidget);
      });
    }

    testWidgets("누름 보고만 — 제목 '버튼은 다 눌렀어요'(중립색, 파랑 아님), 할 일 '가전이 켜졌는지 봐 주세요'",
        (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              executionMode: 'real',
              success: true,
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              resultConfirmation: 'reported',
              onDismiss: () {}));
      final title = tester.widget<Text>(find.text('버튼은 다 눌렀어요'));
      expect(title.style?.color, isNot(KioskColors.running));
      expect(title.style?.color, isNot(KioskColors.confirmed));
      expect(find.text('가전이 켜졌는지 봐 주세요'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing, reason: '확인 수준을 높여 보이지 않는다');
    });
  });

  group('2. 작은 팔 연결이 끊기면 대기 화면', () {
    testWidgets("작은 팔 가전 타일은 '지금 못 써요' — 누르면 연결 창, LG 가전은 그대로", (tester) async {
      ConnectionItem? opened;
      ApplianceMap? selected;
      await _pump(
          tester,
          _idle(
              connections: _pressDown,
              onOpen: (i) => opened = i,
              onSelect: (a) => selected = a));
      expect(tester.takeException(), isNull);
      final mw = find.byKey(const ValueKey('tile-status-microwave'));
      expect(tester.widget<Text>(mw).data, '지금 못 써요');
      expect(find.byKey(const ValueKey('tile-unavailable-microwave')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('tile-status-air'))).data,
          isNot('지금 못 써요'));
      await tester.tap(find.byKey(const ValueKey('strip-microwave')));
      await tester.pump();
      expect(opened?.id, 'press');
      expect(selected, isNull);
      // LG 가전은 그대로 연다.
      await tester.tap(find.byKey(const ValueKey('strip-air')));
      await tester.pump();
      expect(selected?.id, 'air');
    });

    testWidgets("칩은 쉬운 말 '작은 팔 연결이 끊겼어요' — 누르면 바로 그 연결 창", (tester) async {
      ConnectionItem? opened;
      await _pump(tester, _idle(connections: _pressDown, onOpen: (i) => opened = i));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('작은 팔 연결이 끊겼어요')), findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(opened?.id, 'press');
      expect(connectionSummary(_pressDown).$1, '작은 팔 연결이 끊겼어요');
    });
  });

  group('3. 대기 화면 정렬·다음 루틴 카드', () {
    testWidgets('가전 타일 줄 왼쪽 = 시계 왼쪽 선', (tester) async {
      await _pump(tester, _idle());
      // 시계는 '오전' + '7:08'(평가 4차 10/18) — 시계 줄의 왼쪽 선.
      final clock = tester.getTopLeft(find.byKey(const ValueKey('idle-clock'))).dx;
      final tile = tester.getTopLeft(find.byKey(const ValueKey('strip-microwave'))).dx;
      expect((tile - clock).abs(), lessThanOrEqualTo(2));
    });

    testWidgets('다음 루틴은 가전 줄 바로 위 큰 카드(시각은 상태 글자 크기)', (tester) async {
      await _pump(tester, _idle(next: _next, ambient: _rain));
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('idle-next-run'));
      expect(card, findsOneWidget);
      final time = tester.widget<Text>(find.byKey(const ValueKey('idle-next-run-time')));
      // 시각은 시계와 같은 오전/오후(평가 4차 10/18).
      expect(time.data, '오늘 오전 7시');
      expect(time.style?.fontSize, greaterThanOrEqualTo(30));
      expect(find.text('아침 공기청정기 끄기'), findsOneWidget);
      // 자동 계열 이름은 '자동으로 해요' 하나로(평가 4차 10/18).
      expect(find.text('다음 루틴 · 자동으로 해요'), findsOneWidget);
      final strip = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      final rect = tester.getRect(card);
      expect(strip.top - rect.bottom, inInclusiveRange(0, 24), reason: '가전 줄 바로 위');
      expect(rect.height, greaterThanOrEqualTo(64));
    });

    testWidgets("큰 글씨(1.22) — 장 넘김 '다음'·쪽 번호가 잘리지 않는다", (tester) async {
      await _pump(tester, _idle(), scale: 1.22);
      expect(tester.takeException(), isNull);
      final next = find.byKey(const ValueKey('strip-next'));
      expect(next, findsOneWidget);
      expect(find.descendant(of: next, matching: find.text('다음')), findsOneWidget);
      final box = tester.getRect(next);
      for (final t in [find.text('다음'), find.text('1/2')]) {
        final r = tester.getRect(t);
        expect(r.right, lessThanOrEqualTo(800 - 36 + 0.5));
        expect(r.left, greaterThanOrEqualTo(box.left - 60));
      }
      // 글자 칸이 글 폭보다 넓다(자르지 않는다).
      final word = tester.renderObject<RenderParagraph>(find.text('다음'));
      expect(word.didExceedMaxLines, isFalse);
      expect(word.size.width, greaterThanOrEqualTo(word.getMaxIntrinsicWidth(100) - 0.5));
    });
  });

  group('4. 쉬운 말', () {
    testWidgets("경보 — '경보 소리가 들려요' + 불이 났는지 살펴 주세요", (tester) async {
      await _pump(tester, DangerAlertOverlay(onAcknowledge: () {}));
      expect(find.text('경보 소리가 들려요'), findsOneWidget);
      expect(find.textContaining('불이 났는지'), findsOneWidget);
      expect(find.textContaining('위험 신호음'), findsNothing);
      expect(find.textContaining('감지'), findsNothing);
    });

    // 평가 4차(10/18): '연습용 숫자예요 (9시 7분)'도 뜻을 몰랐다 — 연습 화면이라는 말 한 줄, 실제 값은 오전/오후 시각.
    test("연습 값 시각 — '연습 화면이에요. 진짜 값이 아니에요'", () {
      expect(thinqReadTimeLine(DateTime(2026, 10, 18, 9, 7), mock: true), '연습 화면이에요. 진짜 값이 아니에요');
      expect(thinqReadTimeLine(DateTime(2026, 10, 18, 9, 7)), '오전 9시 7분 기준');
      expect(thinqReadTimeLine(DateTime(2026, 10, 18, 21, 0)), '오후 9시 기준');
    });

    testWidgets("타일 부제 — 작은 팔 가전은 '눌러 드려요', 작동 중은 '작동하고 있어요'", (tester) async {
      await _pump(
          tester,
          KioskApplianceStrip(
              appliances: const [kMicrowaveAppliance, kInductionAppliance, _thinqAir],
              running: const {'induction', 'air'},
              attention: const {},
              onSelect: (_) {},
              perPage: 3,
              itemWidth: 180));
      expect(tester.widget<Text>(find.byKey(const ValueKey('tile-status-microwave'))).data, '눌러 드려요');
      expect(tester.widget<Text>(find.byKey(const ValueKey('tile-status-induction'))).data,
          '작동하고 있어요');
      // 타일 4개 한 줄에서도 한 줄에 들어가게 짧게(평가 4차 10/18).
      expect(tester.widget<Text>(find.byKey(const ValueKey('tile-status-air'))).data,
          '바꾸고 있어요');
      expect(find.text('작은 팔 조작'), findsNothing);
      expect(find.text('동작 중'), findsNothing);
    });

    test("루틴 단위 — '버튼 N번' · 'LG 가전 설정 N번'(폰과 같게)", () {
      const r = KioskRoutine(id: 'r', name: '저녁', pressCount: 2, settingCount: 1);
      expect(r.sizeLabel, contains('버튼 2번'));
      expect(r.sizeLabel, contains('LG 가전 설정 1번'));
    });
  });

  group('5. 실행 화면 진행', () {
    Widget exec({List<String> done = const ['즉석밥'], double? confidence}) => KioskExecutingView(
          executionMode: 'real',
          title: '즉석밥 데워줘',
          target: kMicrowaveAppliance,
          lastButtons: null,
          currentButton: '시작',
          currentAttempt: 1,
          completedSteps: 1,
          totalSteps: 2,
          doneButtons: done,
          verificationConfidence: confidence,
          verificationDetail: null,
          onStop: () {},
        );

    testWidgets('끝난 칸에 ✓, 지금 칸은 채움 그대로', (tester) async {
      await _pump(tester, exec());
      expect(tester.takeException(), isNull);
      final done = find.byKey(const ValueKey('panel-pressed-BT-08'));
      expect(done, findsOneWidget);
      expect(find.descendant(of: done, matching: find.byIcon(Icons.check)), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-current')), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-pressed-BT-05')), findsNothing,
          reason: '지금 누르는 칸에는 ✓를 달지 않는다');
    });

    testWidgets("'제대로 눌렸는지 보는 중' 아이콘은 눈 하나", (tester) async {
      await _pump(tester, exec(confidence: 0.5));
      expect(find.text('제대로 눌렸는지 보는 중'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(find.byIcon(Icons.manage_search), findsNothing);
    });
  });
}
