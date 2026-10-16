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
    expect(auto.line, '다음 루틴 · 내일 07:00 아침 공기청정기 끄기 · 자동 실행');
    final ask = KioskNextRun.fromJson({
      'routine_id': 'rt-2',
      'name': '저녁 데우기',
      'at': '2026-10-16T19:00:00+09:00',
      'day_label': '오늘',
      'auto': false,
      'mode_label': '승인 후 실행',
    })!;
    expect(ask.line, '다음 루틴 · 오늘 19:00 저녁 데우기 · 승인 후 실행');
    expect(KioskNextRun.fromJson({'name': ''}), isNull);
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

  testWidgets('평소 화면에 다음 루틴 한 줄이 보이고, 모르면 없다', (tester) async {
    await _pumpIdle(
        tester,
        const KioskNextRun(
            name: '아침 공기청정기 끄기', dayLabel: '내일', hhmm: '07:00', modeLabel: '자동 실행'));
    const line = '다음 루틴 · 내일 07:00 아침 공기청정기 끄기 · 자동 실행';
    // 어절 단위로 줄을 바꾼다 — 실패널에서 '공기청/정기'처럼 낱말 가운데서 끊겼다(10/16 밤).
    expect(find.text(keepWords(line)), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pumpIdle(tester, null);
    expect(find.textContaining('다음 루틴'), findsNothing);
  });
}
