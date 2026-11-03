// 처음 화면 문구 세 곳(실패널 1920x1080 캡처, 2026-11-03).
//
// 1. 위 경고 띠 — 연결 문제가 한 곳이면 서버가 준 그 항목 제목('누름 장치가 연습 모드예요')을 그대로. 예전에는
//    '누름 장치를 봐 주세요'처럼 무엇을 볼지 없는 말이었다(UX 문구 기준 R7). 여러 곳이면 '연결 N곳에 문제가 있어요'.
// 2. 다음 루틴 꼬리표 — '공기청정기 강풍 물어보고'가 끊긴 문장처럼 읽혔다. 묻는 회차는 '먼저 물어봐요', 알림 회차는
//    '알림만'으로, 할 일 아래 작은 회색 줄로 떼어 둔다. 자동 실행은 꼬리표 없음.
// 3. 공기질 할 일 — '공기청정기를 켜 / 보세요'로 '켜'와 '보세요' 사이가 갈렸다. '켜 보세요'는 붙여 넘긴다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_top.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

const _practice = ConnectionItem(
    id: 'press',
    state: 'warn',
    title: '누름 장치가 연습 모드예요',
    message: '실제 버튼은 누르지 않아요.');
const _wifiDown = ConnectionItem(
    id: 'network', state: 'error', title: '와이파이 연결이 끊겼어요', message: '');

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

KioskNextRun _next({String mode = 'approve', bool auto = false}) =>
    KioskNextRun.fromJson({
      'routine_id': 'rt-home',
      'name': '귀가 준비 — 공기청정기 강풍',
      'at': '2026-11-03T18:30:00+09:00',
      'day_label': '오늘',
      'auto': auto,
      'mode': mode,
      'mode_label':
          auto ? '자동 실행' : (mode == 'notify' ? '알림만' : '승인 후 실행'),
      'skipped': false,
      'skip_action_label': '오늘은 건너뛰기',
    })!;

KioskIdleView _idle({
  List<ConnectionItem> connections = const [],
  KioskNextRun? next,
  KioskAirReading? air,
}) =>
    KioskIdleView(
      now: DateTime(2026, 11, 3, 17, 39),
      connected: true,
      ambient: const AmbientInfo(greeting: '좋은 저녁이에요.', weatherSource: 'mock'),
      appliances: [kMicrowaveAppliance, _purifier],
      off: const {'air_purifier'},
      air: air,
      connections: connections,
      temperature: 23,
      humidity: 40,
      nextRun: next,
      onToggleNextRunSkip: (_) {},
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(backgroundColor: KioskColors.bg, body: child)));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 그려지는 글(낱말 묶음 문자 포함) — 줄을 바꿀 수 있는 자리를 본다.
String _drawn(WidgetTester tester, Finder f) =>
    tester.widget<RichText>(find.descendant(of: f, matching: find.byType(RichText)).first)
        .text
        .toPlainText(includeSemanticsLabels: false);

void main() {
  group('1. 위 경고 띠 — 한 곳이면 그 연결 항목 제목', () {
    testWidgets("연습 모드 한 곳 — '누름 장치가 연습 모드예요', '봐 주세요'만은 없다", (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _idle(connections: const [_practice]));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('누름 장치가 연습 모드예요')), findsOneWidget);
      expect(find.text('누름 장치를 봐 주세요'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('^누름 장치가 연습 모드예요')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('봐 주세요')), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets("끊김 한 곳 — 서버 제목 '와이파이 연결이 끊겼어요' 그대로", (tester) async {
      await _pump(tester, _idle(connections: const [_wifiDown]));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('와이파이 연결이 끊겼어요')), findsOneWidget);
    });

    testWidgets("여러 곳이면 그대로 '연결 2곳에 문제가 있어요'", (tester) async {
      await _pump(tester, _idle(connections: const [_wifiDown, _practice]));
      final chip = find.byKey(const ValueKey('idle-status-chip'));
      expect(find.descendant(of: chip, matching: find.text('연결 2곳에 문제가 있어요')), findsOneWidget);
    });

    test("서버 제목이 비면 무엇에 문제가 있는지 — '봐 주세요'만으로 끝내지 않는다", () {
      expect(connectionProblemText(const ConnectionItem(id: 'plug', state: 'warn', title: '', message: '')),
          '콘센트에 문제가 있어요');
      expect(connectionProblemText(const ConnectionItem(id: 'press', state: 'error', title: ' ', message: '')),
          '누름 장치 연결이 끊겼어요');
    });
  });

  group('2. 다음 루틴 꼬리표 — 할 일 아래 작은 회색 줄', () {
    testWidgets("묻는 회차 — '공기청정기 강풍' 아래 '먼저 물어봐요'", (tester) async {
      await _pump(tester, _idle(next: _next()));
      final task = find.byKey(const ValueKey('idle-next-run-text'));
      final tag = find.byKey(const ValueKey('idle-next-run-tag'));
      expect(tag, findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('idle-next-run')), matching: find.text('먼저 물어봐요')),
          findsOneWidget);
      expect(_drawn(tester, find.byKey(const ValueKey('idle-next-run'))).contains('물어보고'), isFalse);
      // 할 일 글에는 꼬리표가 붙지 않는다.
      expect(tester.widget<Text>(task).textSpan!.toPlainText().replaceAll('⁠', ''), '공기청정기 강풍');
      expect(tester.getRect(tag).top, greaterThanOrEqualTo(tester.getRect(task).bottom - 1));
      final style = tester.widget<Text>(tag).style!;
      expect(style.color, KioskColors.muted);
      expect(style.fontSize, lessThan(KioskType.body));
      expect(tester.takeException(), isNull);
    });

    testWidgets("알림 회차 — '알림만'", (tester) async {
      await _pump(tester, _idle(next: _next(mode: 'notify')));
      final tag = find.byKey(const ValueKey('idle-next-run-tag'));
      expect(tag, findsOneWidget);
      expect(find.text('알림만'), findsOneWidget);
      expect(tester.widget<Text>(tag).textSpan!.toPlainText(), '알림만');
    });

    testWidgets('자동 실행 — 꼬리표 없음', (tester) async {
      await _pump(tester, _idle(next: _next(auto: true)));
      expect(find.byKey(const ValueKey('idle-next-run-tag')), findsNothing);
    });

    test('꼬리표 말', () {
      expect(_next().modeTag, '먼저 물어봐요');
      expect(_next(mode: 'notify').modeTag, '알림만');
      expect(_next(auto: true).modeTag, isNull);
    });
  });

  group("3. 공기질 할 일 — '켜 보세요'를 갈라 놓지 않는다", () {
    const offAir = KioskAirReading(applianceId: 'air_purifier', grade: 'BAD', pm25: 42, power: 'off');

    testWidgets("'공기청정기를' 뒤에서만 줄이 바뀔 수 있다, 글자 크기는 그대로", (tester) async {
      await _pump(tester, _idle(air: offAir));
      final action = find.byKey(const ValueKey('idle-air-action'));
      expect(find.descendant(of: action, matching: find.text('공기청정기를 켜 보세요')), findsOneWidget);
      // 그리는 글에서 낱말 잇기 문자(U+2060)를 떼고 본다 — '켜'와 '보세요' 사이는 줄 바꾸지 않는 띄어쓰기(U+00A0)여야 한다.
      final drawn = _drawn(tester, action).replaceAll('⁠', '');
      expect(drawn, '공기청정기를 켜 보세요');
      expect(tester.widget<Text>(find.descendant(of: action, matching: find.byType(Text))).style?.fontSize,
          KioskType.caption);
      expect(tester.takeException(), isNull);
    });
  });
}
