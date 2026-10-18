// 평소 화면 '다음 루틴' 한 줄(외부 평가 10/16 2차 k01 — 다음 루틴이 대기 화면에 없었다).
// 서버 GET /routines/next 의 첫 항목을 그대로 말한다. 모르면 줄이 없다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_text.dart';

Future<void> _pumpIdle(WidgetTester tester, KioskNextRun? next,
    {Size size = const Size(1920, 1080)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KioskIdleView(
        now: DateTime(2026, 10, 16, 22, 30),
        connected: true,
        appliances: [kMicrowaveAppliance],
        nextRun: next,
        onSelectAppliance: (_) {},
        onOpenConnection: (_) {},
        onDndGesture: () {},
      ),
    ),
  ));
}

void main() {
  test('서버 항목 → 한 줄(오늘·내일·요일, 시각, 이름, 자동 여부)', () {
    final auto = KioskNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '아침 공기청정기 끄기',
      'at': '2026-10-17T07:00:00+09:00',
      'day_label': '내일',
      'auto': true,
      'mode_label': '자동 실행',
    })!;
    // 시각과 루틴 이름을 다른 줄로 — '22:00 저녁'이 시간대처럼 읽혔다(UI 평가 10/17).
    // 시각은 오전/오후, 자동 계열 이름은 '자동으로 해요' 하나로(평가 4차 10/18).
    expect(auto.line, '다음 루틴 · 내일 오전 7시\n아침 공기청정기 끄기 · 자동으로 해요');
    final ask = KioskNextRun.fromJson({
      'routine_id': 'rt-2',
      'name': '저녁 데우기',
      'at': '2026-10-16T19:00:00+09:00',
      'day_label': '오늘',
      'auto': false,
      'mode_label': '승인 후 실행',
    })!;
    expect(ask.line, '다음 루틴 · 오늘 오후 7시\n저녁 데우기 · 물어보고 해요');
    expect(KioskNextRun.fromJson({'name': ''}), isNull);
  });

  // UI 평가 8차 10/17: 조용한 시간이 켜져 그 회차를 건너뛰는데 '다음 루틴 · 오늘 22:00 … 자동 실행'이라고 했다.
  test('조용한 시간이라 건너뛰는 회차는 첫 줄에 조용한 시간, 둘째 줄에 건너뜀(줄 길이는 그대로)', () {
    final quiet = KioskNextRun.fromJson({
      'name': '저녁 공기청정기 켜기',
      'at': '2026-10-17T22:00:00+09:00',
      'day_label': '오늘',
      'mode_label': '조용한 시간이라 건너뜀',
      'quiet_skip': true,
    })!;
    expect(quiet.line, '다음 루틴 · 오늘 오후 10시 · 조용한 시간\n저녁 공기청정기 켜기 · 건너뜀');
    expect(quiet.shortLine, '다음 오후 10시 저녁 공기청정기 켜기 · 건너뜀');
  });

  test('GET /routines/next 첫 항목 — 실패·빈 목록은 null', () async {
    Future<KioskNextRun?> read(int status, Object body) => http.runWithClient(
        () => KioskApiService(baseUrl: 'http://hub.test').nextRoutine(),
        () => MockClient((req) async {
              expect(req.url.path, '/routines/next');
              return http.Response.bytes(utf8.encode(jsonEncode(body)), status,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    final next = await read(200, [
      {'routine_id': 'r', 'name': '아침 공기청정기 끄기', 'at': '2026-10-17T07:00:00+09:00',
        'day_label': '내일', 'auto': true, 'mode_label': '자동 실행'},
    ]);
    expect(next?.name, '아침 공기청정기 끄기');
    expect(await read(200, []), isNull);
    expect(await read(500, {'detail': 'x'}), isNull);
  });

  testWidgets('평소 화면 시계 아래에 다음 루틴 줄(언제 · 무엇을 + 실행 방식)이 보이고, 모르면 없다', (tester) async {
    await _pumpIdle(
        tester,
        const KioskNextRun(
            name: '아침 공기청정기 끄기', dayLabel: '내일', hhmm: '07:00', modeLabel: '자동 실행'));
    // 담담한 줄(사용자 결정 10/18): '내일 오전 7시 · 아침 공기청정기 끄기' + 작은 '자동으로 해요'.
    final line = tester.widget<Text>(find.byKey(const ValueKey('idle-next-run-text')));
    // 어절 단위로 줄을 바꾼다 — 실패널에서 '공기청/정기'처럼 낱말 가운데서 끊겼다(10/16 밤).
    expect(line.textSpan!.toPlainText(includeSemanticsLabels: false),
        '내일 오전 7시 · ${keepWords('아침 공기청정기 끄기')}');
    expect(find.text('자동으로 해요'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpIdle(tester, null);
    expect(find.byKey(const ValueKey('idle-next-run')), findsNothing);
  });

  // 사용자 질문(10/17): 날씨 안내('우산 챙기세요')가 뜨면 오른쪽 칸이 밀려 다음 루틴 줄이 잘리지 않나?
  // → 다음 루틴 줄은 늘 화면 안에 다 보이고, 자리가 모자라면 예보(가장 덜 중요)를 접는다.
  for (final (size, scale) in [(const Size(1920, 1080), 1.0), (const Size(800, 480), 1.0), (const Size(800, 480), 1.22)]) {
    testWidgets('날씨 안내 + 예보 + 다음 루틴 — 다음 루틴 줄이 잘리지 않는다(${size.width.toInt()}, 배율 $scale)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: KioskIdleView(
              now: DateTime(2026, 10, 17, 7, 30),
              connected: true,
              appliances: [kMicrowaveAppliance],
              ambient: const AmbientInfo(
                greeting: '좋은 아침이에요.',
                weatherSource: 'kma',
                tip: AmbientTip(kind: 'rain', text: '오후 3시부터 비 예보가 있어요. 우산 챙기세요.', icon: 'rain'),
                hourly: [
                  AmbientHour(label: '9시', icon: 'cloudy', temp: 16),
                  AmbientHour(label: '12시', icon: 'cloudy', temp: 18),
                  AmbientHour(label: '15시', icon: 'rain', pop: 70, precip: true),
                  AmbientHour(label: '18시', icon: 'rain', pop: 60, precip: true),
                ],
              ),
              nextRun: const KioskNextRun(
                  name: '저녁 공기청정기 켜기', dayLabel: '오늘', hhmm: '22:00', modeLabel: '자동 실행'),
              onSelectAppliance: (_) {},
              onOpenConnection: (_) {},
              onDndGesture: () {},
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      final next = find.byKey(const ValueKey('idle-next-run'));
      if (scale > 1) {
        // 큰 글씨: 자리가 있으면 짧은 문장으로 다 보이고, 없으면 숨는다 — 잘린 채로는 두지 않는다.
        if (next.evaluate().isEmpty) {
          expect(find.byKey(const ValueKey('ambient-tip')), findsOneWidget, reason: '날씨 안내는 남는다');
          return;
        }
      }
      expect(next, findsOneWidget);
      final rect = tester.getRect(next);
      final strip = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(rect.bottom, lessThanOrEqualTo(strip.top), reason: '가전 줄 위에서 끝난다');
      // 스크롤 안 보이는 곳이 아니라 실제 화면 안에 있다.
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(tester.getRect(find.byKey(const ValueKey('ambient-tip'))).top, greaterThanOrEqualTo(0));
    });
  }
}
