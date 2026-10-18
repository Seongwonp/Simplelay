// 평가 17차(2026-10-18) — 16차에서 시간 안에 못 한 키오스크 항목 단정 시험. 옛 코드에서 실패하는 것을 확인했다.
//
// 1. 결과 화면 한 틀: 모든 결과(누름 보고·연습 실패·확인 못 함·LG 가전)는 왼쪽 정렬, 큰 원 아이콘 없음, 제목 왼쪽 선이 같다.
//    LG 가전 결과도 가전 줄(아이콘 + 이름)이 늘 있다.
// 2. '뒤로' 단추 왼쪽 끝 = 버튼판 첫 칸 왼쪽 끝(같은 왼쪽 선).
// 3. 예보 칸 머리('지금'·'오후 12시'·'오후 3시')는 모두 같은 글자 크기.
// 4. 예보 칸 높이는 비 확률 줄이 있든 없든 같다(빈 둘째 줄 자리 유지).
// 5. 위쪽 문제 칩은 연결 문제만 센다 — 가전 문제(인덕션 멈춤 등)가 같이 보여도 숫자가 어긋나 보이지 않게 '연결 확인 필요 N'.
// 7. 날씨 아이콘은 가전 아이콘과 같은 채움 양식 — 가는 선(outlined) 날씨 아이콘을 쓰지 않는다.
// (6. 인덕션 '시작·취소' / 전자레인지 '취소·시작'은 서버 가전 등록표의 버튼 자리(x, y)를 그대로 따른다 — 시험 없음.)
// 17차 평가 추가: A. 결과 띠에 늘 가전·할 일 이름(본문 이름 줄 없음) B. 두 줄 단추는 같은 폭 격자 C. 지난 일은 쉼표·날짜 말
// D. 정지 확인 기다림은 띠 '멈추는 중'(돌아가는 원 없음) E. 창 닫는 단추 '닫기'·수동 화면 제목에서 '내' 뺌.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/past_result_line.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

Future<void> _pump(WidgetTester tester, Widget child, {bool panel = true}) async {
  final size = panel ? const Size(1920, 1080) : const Size(800, 480);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  Widget body = Scaffold(backgroundColor: KioskColors.bg, body: child);
  if (panel) body = KioskCanvas(child: body);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: body,
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

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

KioskDoneView _thinq({String? detail}) => KioskDoneView(
      success: true,
      executionMode: 'real',
      label: '공기청정기를 켤까요?',
      target: _purifier,
      thinqOnly: true,
      route: 'thinq',
      resultConfirmation: 'state_confirmed',
      detail: detail ?? '전원 켜기로 바꿨어요.',
      onDismiss: () {},
    );

const _okConnections = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

KioskIdleView _idle(AmbientInfo ambient) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: ambient,
      connections: _okConnections,
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

const _rainTip = AmbientInfo(
  greeting: '좋은 아침이에요.',
  tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
  hourly: [
    AmbientHour(label: '9시', icon: 'partly', temp: 16),
    AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
    AmbientHour(label: '15시', icon: 'rain', temp: 17, pop: 70, precip: true),
    AmbientHour(label: '18시', icon: 'rain', temp: 15, pop: 60, precip: true),
  ],
  weatherSource: 'mock',
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
  now: AmbientHour(label: '지금', hour: 7, icon: 'rain', temp: 14, pop: 80, precip: true),
  hourly: [
    AmbientHour(label: '9시', hour: 9, icon: 'rain', temp: 14),
    AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 16),
    AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 15),
  ],
);

void main() {
  group('1. 결과 화면 한 틀', () {
    testWidgets('큰 원 없음 · 제목 왼쪽 선이 모든 결과에서 같다', (tester) async {
      final cases = <(Widget, String)>[
        (
          KioskDoneView(success: true, label: '즉석밥 데워줘', target: kMicrowaveAppliance, onDismiss: () {}),
          '버튼은 다 눌렀어요'
        ),
        (
          KioskDoneView(
              success: false,
              executionMode: 'mock',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              onRetry: () {},
              onManual: () {},
              onDismiss: () {}),
          '연습이 중간에 멈췄어요'
        ),
        (_thinq(), '공기청정기가 켜졌어요'),
        (_thinq(detail: '바람 세기 강으로 바꿨어요.'), '바람 세기 강으로 바꿨어요'),
      ];
      final lefts = <double>[];
      for (final (w, title) in cases) {
        await _pump(tester, w);
        expect(find.byKey(const ValueKey('done-ring')), findsNothing, reason: title);
        final t = find.textContaining(title);
        expect(t, findsWidgets, reason: title);
        lefts.add(tester.getTopLeft(t.first).dx);
      }
      for (final l in lefts) {
        expect((l - lefts.first).abs(), lessThan(1.0), reason: '$lefts');
      }
    });

    testWidgets('A. 결과 띠는 늘 가전·할 일 이름, 본문에는 이름 줄이 없다', (tester) async {
      final band = find.byKey(const ValueKey('status-band'));
      await _pump(tester, _thinq());
      expect(find.descendant(of: band, matching: find.text('공기청정기')), findsOneWidget);
      await _pump(tester,
          KioskDoneView(success: true, label: '즉석밥 데워줘', target: kMicrowaveAppliance, onDismiss: () {}));
      expect(find.descendant(of: band, matching: find.text('전자레인지 · 즉석밥 데우기')), findsOneWidget);
      expect(find.byKey(const ValueKey('done-target')), findsNothing);
    });

    // 휴리스틱 평가(10/18): 연습 실패는 다시 해도 안전해 '한 번 더 하기'가 주(왼쪽), 처음 화면으로는 그 옆 보조, 골라 누르기는 보조 줄.
    testWidgets('B. 연습 실패 — 한 번 더 하기가 윗줄 주 자리, 처음 화면으로·골라 누르기는 아랫줄 보조, 화면 안', (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'mock',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              onRetry: () {},
              onManual: () {},
              onDismiss: () {}),
          panel: false);
      final retry = tester.getRect(find.byKey(const ValueKey('done-retry')));
      final home = tester.getRect(find.byKey(const ValueKey('done-home')));
      final manual = tester.getRect(find.byKey(const ValueKey('done-manual')));
      expect(tester.widget(find.byKey(const ValueKey('done-retry'))), isA<ElevatedButton>());
      expect(tester.widget(find.byKey(const ValueKey('done-home'))), isA<OutlinedButton>());
      // 같은 폭 격자(결선 모의 평가 10/18) — 주 단추가 윗줄 첫 칸, 보조 둘은 아랫줄.
      expect(retry.left, closeTo(home.left, 1));
      expect(retry.bottom, lessThanOrEqualTo(home.top));
      for (final r in [retry, home, manual]) {
        expect(r.bottom, lessThanOrEqualTo(480));
        expect(r.height, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });

    // 휴리스틱 평가(10/18): 진행 표시가 없어 멈춘 화면처럼 보였다 — 큰 제목 왼쪽에 돌아가는 표시 하나(띠 안에는 없다).
    testWidgets("D. 정지 확인 기다림 — 띠 '멈추는 중', 돌아가는 표시는 제목 옆 하나", (tester) async {
      await _pump(
          tester,
          KioskDoneView(
              success: false,
              executionMode: 'real',
              label: '즉석밥 데워줘',
              target: kMicrowaveAppliance,
              reason: KioskFailureReason.stopped,
              stopPending: true,
              onDismiss: () {}));
      final band = find.byKey(const ValueKey('status-band'));
      expect(find.descendant(of: band, matching: find.text('멈추는 중')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.descendant(of: band, matching: find.byType(CircularProgressIndicator)), findsNothing);
    });
  });

  test('C. 지난 일 — 쉼표, 오늘이 아니면 날짜 말', () {
    final r = KioskPastResult(at: DateTime(2026, 10, 17, 15, 12), label: '즉석밥 데우기', headline: '눌렸는지 몰라요');
    expect(r.textAt(DateTime(2026, 10, 17, 18)), '오후 3:12 즉석밥 데우기, 눌렸는지 몰라요');
    expect(r.textAt(DateTime(2026, 10, 18, 8)), '어제 오후 3:12 즉석밥 데우기, 눌렸는지 몰라요');
    expect(r.textAt(DateTime(2026, 10, 20, 8)), '10월 17일 오후 3:12 즉석밥 데우기, 눌렸는지 몰라요');
  });

  testWidgets("E. 수동 화면 제목은 가전 이름만, 쉬기 창 닫는 단추는 '닫기'", (tester) async {
    await _pump(tester, KioskManualView(appliance: kMicrowaveAppliance, onExecute: (_) {}, onCancel: () {}));
    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('내 전자레인지'), findsNothing);
    await _pump(tester, DndOverlay(dndUntil: null, onSet: (_) {}, onClear: () {}, onDismiss: () {}));
    expect(find.text('닫기'), findsOneWidget);
    expect(find.text('취소'), findsNothing);
  });

  testWidgets('2. 뒤로 단추 왼쪽 끝 = 버튼판 첫 칸 왼쪽 끝', (tester) async {
    for (final panel in [true, false]) {
      await _pump(
          tester,
          KioskManualView(appliance: kMicrowaveAppliance, onExecute: (_) {}, onCancel: () {}),
          panel: panel);
      final back = tester.getTopLeft(find.byKey(const ValueKey('kiosk-back'))).dx;
      final cell = tester.getTopLeft(find.byKey(const ValueKey('manual-cell-10초'))).dx;
      expect((back - cell).abs(), lessThan(1.0), reason: 'panel=$panel back=$back cell=$cell');
    }
  });

  testWidgets('3. 예보 칸 머리는 모두 같은 글자 크기(오후 12시만 작지 않다)', (tester) async {
    if (!_hasFont) return;
    await _pump(tester, _idle(_rainTip));
    final heights = [
      for (final label in ['오후 12시', '오후 3시', '오후 6시'])
        tester.getRect(find.text(label)).height,
    ];
    for (final h in heights) {
      expect((h - heights.first).abs(), lessThan(0.5), reason: '$heights');
    }
  });

  // 출시 검토(10/18)에서 바꿈: 비 확률이 없는 날은 칸을 내용에 맞춰 줄인다(아래 절반이 비었다). 칸끼리는 늘 같다.
  testWidgets('4. 예보 칸은 비 확률 줄이 없으면 줄어든다(칸끼리는 같다)', (tester) async {
    await _pump(tester, _idle(_dry));
    final dry = tester.getSize(find.byKey(const ValueKey('ambient-hour-0'))).height;
    await _pump(tester, _idle(_wet));
    final wet = tester.getSize(find.byKey(const ValueKey('ambient-hour-0'))).height;
    expect(dry, lessThan(wet - 10));
  });

  testWidgets("5. 문제 칩은 '연결 확인 필요 N' — 가전 문제와 함께여도 무엇을 센 숫자인지 드러난다", (tester) async {
    await _pump(
        tester,
        KioskIdleView(
          now: DateTime(2026, 9, 30, 7, 38),
          connected: true,
          ambient: const AmbientInfo(
            greeting: '편안한 저녁 보내세요.',
            tip: AmbientTip(kind: 'appliance', text: '인덕션 버튼 누르기가 중간에 멈췄어요. 가전을 봐 주세요.', icon: 'attention'),
          ),
          connections: const [
            ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
            ConnectionItem(id: 'plug', state: 'warn', title: '', message: ''),
          ],
          appliances: const [kInductionAppliance],
          running: const {},
          on: const {},
          off: const {},
          attention: const {'induction'},
          temperature: 23,
          humidity: 58,
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
        panel: false);
    final chip = find.byKey(const ValueKey('idle-status-chip'));
    // 한 줄 제목은 어느 연결인지 말한다(결선 모의 평가 10/18 — 숫자 대신 원인).
    expect(find.descendant(of: chip, matching: find.text('전기 플러그를 봐 주세요')), findsOneWidget);
  });

  testWidgets('7. 날씨 아이콘은 채움 양식 — 가는 선 날씨 아이콘 없음', (tester) async {
    final outlined = {
      Icons.cloud_outlined,
      Icons.umbrella_outlined,
      Icons.wb_sunny_outlined,
      Icons.wb_cloudy_outlined,
      Icons.nightlight_outlined,
      Icons.nights_stay_outlined,
    };
    for (final a in [_rainTip, _dry, _wet]) {
      await _pump(tester, _idle(a));
      final used = [
        for (final i in tester.widgetList<Icon>(find.byType(Icon)))
          if (outlined.contains(i.icon)) i.icon,
      ];
      expect(used, isEmpty);
    }
  });
}
