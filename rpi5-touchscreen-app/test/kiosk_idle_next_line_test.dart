// 처음 화면 시계 아래 줄(사용자 결정 2026-10-18) — 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 공기 줄은 공기가 나쁠 때(나쁨·매우 나쁨)만. 평소(좋음·보통)·공기청정기 없는 집은 줄이 없다. 공기청정기 전원은 가전
//    타일이 말하므로 공기 줄에서 뺀다.
// 2. 다음 루틴은 시계 아래 담담한 줄(작은 머리말 '자동 루틴' + '오후 10:00 · 저녁 공기청정기 켜기' — 10/18 갱신). 오른쪽 큰 카드는 없다.
//    오른쪽은 날씨 안내 + 예보가 넉넉히 쓴다 — 실패널 넓은 글꼴(글자마다 넓힌 조건)에서도 예보가 보인다.
// 3. 큰 글씨·넓은 글꼴에서도 다음 루틴 줄이 잘리지 않는다(가전 줄 위에서 끝난다).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/thinq.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

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

const _hourly = [
  AmbientHour(label: '9시', hour: 9, icon: 'partly', temp: 16),
  AmbientHour(label: '12시', hour: 12, icon: 'cloudy', temp: 18),
  AmbientHour(label: '15시', hour: 15, icon: 'rain', temp: 17, pop: 70, precip: true),
  AmbientHour(label: '18시', hour: 18, icon: 'rain', temp: 15, pop: 60, precip: true),
];

const _rainTip = AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain');
const _next = KioskNextRun(name: '저녁 공기청정기 켜기', dayLabel: '오늘', hhmm: '22:00', modeLabel: '자동 실행');

KioskAirReading _air(String grade, {String? power = 'off'}) =>
    KioskAirReading(applianceId: 'air_purifier', grade: grade, pm25: 20, power: power);

KioskIdleView _idle({AmbientTip? tip, KioskNextRun? next, KioskAirReading? air, bool env = true}) => KioskIdleView(
      now: DateTime(2026, 9, 30, 7, 38),
      connected: true,
      ambient: AmbientInfo(greeting: '좋은 아침이에요.', tip: tip, hourly: _hourly, weatherSource: 'mock'),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
      ],
      appliances: [_purifier, kMicrowaveAppliance, kInductionAppliance],
      temperature: env ? 23 : null,
      humidity: env ? 58 : null,
      air: air,
      nextRun: next,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0, double letterSpacing = 0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(
          backgroundColor: KioskColors.bg,
          body: DefaultTextStyle.merge(style: TextStyle(letterSpacing: letterSpacing), child: child)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 화면에 보이는 글 전부. 낱말 묶음 문자(U+2060·U+00A0)는 뗀다. 다음 루틴 줄은 한 줄에 안 들어가면 시각 뒤에서만
/// 줄을 바꾸므로(줄바꿈 문자) 그 자리를 ' · '로 읽는다.
List<String> _texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText().replaceAll('⁠', '').replaceAll(' ', ' ').replaceAll('\n', ' · '),
    ];

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

void main() {
  group('1. 공기 줄은 나쁠 때만', () {
    for (final grade in ['GOOD', 'NORMAL']) {
      testWidgets('$grade — 공기 줄이 없다(전원 말도 없다)', (tester) async {
        await _pump(tester, _idle(air: _air(grade), next: _next));
        expect(find.byKey(const ValueKey('idle-air')), findsNothing);
        expect(_texts(tester).where((t) => t.contains('공기청정기가 꺼져 있어요')), isEmpty);
        expect(_texts(tester).where((t) => t.startsWith('공기 ')), isEmpty);
      });
    }

    for (final grade in ['BAD', 'VERY_BAD']) {
      testWidgets('$grade — 공기 줄이 보이고 공기청정기 전원 말은 빠진다', (tester) async {
        for (final power in ['on', 'off']) {
          await _pump(tester, _idle(air: _air(grade, power: power), next: _next));
          expect(find.byKey(const ValueKey('idle-air')), findsOneWidget);
          final texts = _texts(tester).join('\n');
          expect(texts, isNot(contains('공기청정기가 꺼져 있어요')));
          expect(texts, isNot(contains('공기청정기가 켜져 있어요')));
        }
      });
    }

    testWidgets('공기청정기가 없는 집(공기 값 없음) — 줄이 없다', (tester) async {
      await _pump(tester, _idle(next: _next));
      expect(find.byKey(const ValueKey('idle-air')), findsNothing);
    });
  });

  group('2. 다음 루틴은 시계 아래 담담한 줄', () {
    testWidgets("시계 아래 왼쪽에 머리말 '자동 루틴' + '오후 10:00 · 저녁 공기청정기 켜기', 오른쪽 큰 카드는 없다", (tester) async {
      await _pump(tester, _idle(next: _next, air: _air('NORMAL')));
      final texts = _texts(tester);
      expect(texts, contains('오후 10:00 · 저녁 공기청정기 켜기'));
      expect(texts, contains('자동 루틴'));
      expect(texts, isNot(contains('자동으로 해요')));
      expect(texts.where((t) => t.contains('다음 루틴 · ')), isEmpty, reason: '옛 큰 카드 머리 글');
      final next = _rect(tester, 'idle-next-run');
      final clock = _rect(tester, 'idle-clock');
      expect(next.top, greaterThanOrEqualTo(clock.bottom), reason: '시계 아래');
      expect(next.left, closeTo(clock.left, 1), reason: '시계와 같은 왼쪽 선');
      expect(next.right, lessThan(400), reason: '왼쪽 칸 안');
      // 다음 루틴 글은 시계 숫자보다 훨씬 작다(강조하지 않는다).
      expect(next.height, lessThan(clock.height * 1.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('내일 회차는 날 말을 붙인다(오전/오후 표기)', (tester) async {
      await _pump(
          tester,
          _idle(
              next: const KioskNextRun(
                  name: '아침 공기청정기 끄기', dayLabel: '내일', hhmm: '07:00', modeLabel: '승인 후 실행')));
      final texts = _texts(tester);
      expect(texts, contains('내일 오전 7:00 · 아침 공기청정기 끄기'));
      expect(texts, contains('물어볼 루틴'));
      expect(texts, isNot(contains('자동 루틴')));
    });

    testWidgets('다음 루틴이 없으면 줄도 없다', (tester) async {
      await _pump(tester, _idle());
      expect(find.byKey(const ValueKey('idle-next-run')), findsNothing);
    });
  });

  group('3. 넓은 글꼴·큰 글씨에서도 잘리지 않는다', () {
    // 실패널 글꼴은 시험 글꼴보다 넓다 — 글자마다 넓힌 조건(본문 21의 약 10%·약 15%).
    for (final spacing in [0.0, 2.1, 3.0]) {
      for (final tip in [null, _rainTip]) {
        for (final air in [null, _air('VERY_BAD')]) {
          testWidgets('보통 글씨 글자마다 +$spacing, 안내 ${tip != null}, 나쁜 공기 ${air != null} — 예보와 다음 루틴이 다 보인다',
              (tester) async {
            await _pump(tester, _idle(tip: tip, next: _next, air: air), letterSpacing: spacing);
            expect(tester.takeException(), isNull);
            final hours = find.byKey(const ValueKey('ambient-hours'));
            expect(hours, findsOneWidget, reason: '오른쪽은 예보가 넉넉히 쓴다');
            expect(find.descendant(of: hours, matching: find.text('비 70%')), findsOneWidget);
            final tile = _rect(tester, 'strip-air_purifier');
            expect(tester.getRect(hours).bottom, lessThanOrEqualTo(tile.top));
            final next = _rect(tester, 'idle-next-run');
            expect(next.bottom, lessThanOrEqualTo(tile.top), reason: '다음 루틴이 가전 줄에 걸리지 않는다');
            if (air != null) {
              expect(_rect(tester, 'idle-air').bottom, lessThanOrEqualTo(next.top));
            }
          });
        }
      }
    }

    for (final spacing in [0.0, 2.1]) {
      for (final air in [null, _air('BAD')]) {
        testWidgets('큰 글씨(1.22) 글자마다 +$spacing, 날씨 안내, 나쁜 공기 ${air != null} — 다음 루틴 줄이 가전 줄 위에서 끝난다',
            (tester) async {
          await _pump(tester, _idle(tip: _rainTip, next: _next, air: air), scale: 1.22, letterSpacing: spacing);
          expect(tester.takeException(), isNull);
          final next = _rect(tester, 'idle-next-run');
          final tile = _rect(tester, 'strip-air_purifier');
          expect(next.bottom, lessThanOrEqualTo(tile.top));
          expect(next.top, greaterThanOrEqualTo(_rect(tester, 'idle-clock').bottom));
          if (air != null) expect(find.byKey(const ValueKey('idle-air')), findsOneWidget);
          expect(find.byKey(const ValueKey('ambient-tip')), findsOneWidget, reason: '날씨 안내는 그대로');
        });
      }
    }
  });
}
