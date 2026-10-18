// 대기 화면 날짜 옆 바깥 날씨·기온(사용자 요청 10/18) — '10월 18일 일요일  ☁ 14°'.
//
// - 값은 서버 `GET /ambient`의 시간대 예보(`hourly`, 3시간 간격 칸)에서 **지금 시각에 해당하는 칸**만 쓴다:
//   칸 시각이 지금 ±90분 안(3시간 칸이 대표하는 범위)일 때만. 아니면 붙이지 않는다(먼 칸 값을 지금처럼 보이지 않는다).
// - 기온이 없거나 예보가 없으면 아무것도 붙이지 않는다(추측 값 금지).
// - 상태 칩·메뉴와 겹치지 않고, 큰 글씨에서도 잘리지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '와이파이에 연결돼 있어요', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '작은 팔이 연결돼 있어요', message: ''),
];

AmbientInfo _amb(List<AmbientHour> hourly, {AmbientTip? tip}) =>
    AmbientInfo(greeting: '좋은 아침이에요.', tip: tip, hourly: hourly, weatherSource: 'kma');

const _hours = [
  AmbientHour(label: '9시', hour: 9, icon: 'cloudy', temp: 14),
  AmbientHour(label: '12시', hour: 12, icon: 'clear', temp: 18),
  AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 60, precip: true),
];

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
          data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: child))));
  await tester.pump();
}

KioskIdleView _idle(DateTime now, AmbientInfo? ambient,
        {Duration? dnd, KioskNextRun? next}) =>
    KioskIdleView(
      now: now,
      connected: true,
      ambient: ambient,
      connections: _ok,
      dndUntil: dnd == null ? null : now.add(dnd),
      nextRun: next,
      appliances: const [kMicrowaveAppliance, kInductionAppliance],
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

final _outside = find.byKey(const ValueKey('idle-outside'));

void main() {
  group('지금 칸 고르기', () {
    test('서버 hourly의 hour를 읽는다(없으면 칸 이름 "15시"에서)', () {
      final a = AmbientInfo.fromJson({
        'greeting': '',
        'hourly': [
          {'label': '9시', 'hour': 9, 'icon': 'cloudy', 'temp': 14},
          {'label': '12시', 'icon': 'clear', 'temp': 18},
        ],
      });
      expect(a.hourly[0].hour, 9);
      expect(a.hourly[1].hour, 12);
    });

    test('지금 ±90분 안의 칸만 — 8:20이면 9시 칸, 7:08이면 없음(9시는 112분 뒤)', () {
      expect(outsideNowSlot(_amb(_hours), DateTime(2026, 10, 18, 8, 20))?.temp, 14);
      expect(outsideNowSlot(_amb(_hours), DateTime(2026, 10, 18, 7, 8)), isNull);
      // 정시(서버는 지금이 3시간 경계면 그 칸부터 준다).
      expect(outsideNowSlot(_amb(_hours), DateTime(2026, 10, 18, 9, 0))?.temp, 14);
      // 자정 넘김: 23:00의 다음 칸 0시.
      expect(
          outsideNowSlot(
              _amb(const [AmbientHour(label: '0시', hour: 0, icon: 'clear', temp: 9)]),
              DateTime(2026, 10, 18, 23, 0))
              ?.temp,
          9);
    });

    test('기온이 없거나 예보가 없으면 없음', () {
      expect(
          outsideNowSlot(
              _amb(const [AmbientHour(label: '9시', hour: 9, icon: 'rain', pop: 70, precip: true)]),
              DateTime(2026, 10, 18, 8, 20)),
          isNull);
      expect(outsideNowSlot(_amb(const []), DateTime(2026, 10, 18, 8, 20)), isNull);
      expect(outsideNowSlot(null, DateTime(2026, 10, 18, 8, 20)), isNull);
    });

    test('서버 지금 칸(now)이 있으면 그것 — 7:08처럼 3시간 칸이 먼 시각에도 보인다(10/18)', () {
      final a = AmbientInfo.fromJson({
        'greeting': '',
        'hourly': [
          {'label': '9시', 'hour': 9, 'icon': 'cloudy', 'temp': 14},
        ],
        'now': {'hour': 7, 'icon': 'clear', 'temp': 11},
      });
      expect(a.now?.temp, 11);
      expect(outsideNowSlot(a, DateTime(2026, 10, 18, 7, 8))?.temp, 11);
      // 기온 없는 지금 칸은 쓰지 않고 3시간 칸 규칙으로.
      final noTemp = AmbientInfo.fromJson({
        'greeting': '',
        'hourly': [
          {'label': '9시', 'hour': 9, 'icon': 'cloudy', 'temp': 14},
        ],
        'now': {'hour': 7, 'icon': 'clear'},
      });
      expect(outsideNowSlot(noTemp, DateTime(2026, 10, 18, 7, 8)), isNull);
    });
  });

  group('날짜 줄', () {
    testWidgets('날짜 옆에 날씨 아이콘 + 기온 — 흐림 14°', (tester) async {
      await _pump(tester, _idle(DateTime(2026, 10, 18, 8, 20), _amb(_hours)));
      expect(tester.takeException(), isNull);
      expect(find.text('10월 18일 일요일'), findsOneWidget);
      expect(_outside, findsOneWidget);
      expect(find.descendant(of: _outside, matching: find.text('14°')), findsOneWidget);
      final icon = tester.widget<Icon>(find.descendant(of: _outside, matching: find.byType(Icon)));
      expect(icon.icon, Icons.cloud_outlined);
      // 날짜와 같은 줄, 날짜 오른쪽.
      final date = tester.getRect(find.text('10월 18일 일요일'));
      final out = tester.getRect(_outside);
      expect(out.left, greaterThan(date.right));
      expect((out.center.dy - date.center.dy).abs(), lessThan(8));
      // 화면 읽기: 무엇의 값인지 말로.
      expect(find.bySemanticsLabel(RegExp('바깥 흐림, 14도')), findsOneWidget);
    });

    testWidgets('지금 칸이 없으면 아무것도 붙이지 않는다', (tester) async {
      await _pump(tester, _idle(DateTime(2026, 10, 18, 7, 8), _amb(_hours)));
      expect(find.text('10월 18일 일요일'), findsOneWidget);
      expect(_outside, findsNothing);
      await _pump(tester, _idle(DateTime(2026, 10, 18, 8, 20), null));
      expect(_outside, findsNothing);
    });

    for (final scale in [1.0, 1.22]) {
      testWidgets('상태 칩·메뉴·쉬는 중 칩과 겹치지 않고 잘리지 않는다(글씨 x$scale)', (tester) async {
        await _pump(
            tester,
            _idle(DateTime(2026, 10, 18, 8, 20),
                _amb(_hours,
                    tip: const AmbientTip(
                        kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain')),
                dnd: const Duration(minutes: 90),
                next: const KioskNextRun(
                    name: '저녁 공기청정기 켜기', dayLabel: '오늘', hhmm: '22:00', modeLabel: '자동 실행')),
            scale: scale);
        expect(tester.takeException(), isNull);
        expect(_outside, findsOneWidget);
        final out = tester.getRect(_outside);
        final chip = tester.getRect(find.byKey(const ValueKey('idle-status-chip')));
        final menu = tester.getRect(find.byKey(const ValueKey('idle-menu')));
        final dndChip = tester.getRect(find.byKey(const ValueKey('dnd-chip')));
        for (final r in [chip, menu, dndChip]) {
          expect(out.overlaps(r), isFalse);
        }
        expect(out.right, lessThanOrEqualTo(dndChip.left));
        expect(out.left, greaterThanOrEqualTo(0));
        // 1~2 m에서 읽히는 크기 — 기온 글자는 날짜와 같은 크기 이상(줄어들어도 날짜와 같은 비율).
        final temp = tester.getRect(find.descendant(of: _outside, matching: find.text('14°')));
        final date = tester.getRect(find.text('10월 18일 일요일'));
        expect(temp.height, greaterThanOrEqualTo(date.height - 0.5));
      });
    }
  });
}
