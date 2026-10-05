// 실행 기록·실행 상태 화면의 결과/경로/확인 수준 표시(2026-09-29).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

RpiApiService _apiWithHistory(List<Map<String, dynamic>> entries) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode(entries)),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

Map<String, dynamic> _entry(String id, Map<String, dynamic> extra) => {
      'job_id': id,
      'finished_at': '2026-09-29T19:30:00+09:00',
      'purpose': '목적 $id',
      'retry_count': 0,
      'buttons': <Map<String, dynamic>>[],
      'execution_mode': 'mock',
      ...extra,
    };

void main() {
  testWidgets('이력: 결과·경로·확인 수준 열을 outcome으로 말한다', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _apiWithHistory([
      _entry('t1', {
        'status': 'failed',
        'outcome': 'unconfirmed',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'none',
        'detail': '상태를 확인하지 못했어요',
      }),
      _entry('t2', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'state_confirmed',
      }),
      _entry('t3', {
        'status': 'failed',
        'outcome': 'unconfirmed',
        'route': 'thinq',
        'receipt': 'unknown',
        'confirmation': 'none',
      }),
      _entry('p1', {
        'status': 'safety_stopped',
        'outcome': 'safety_stop',
        'termination': 'retries_exhausted',
        'route': 'physical',
        'receipt': 'accepted',
        'confirmation': 'reported',
      }),
      _entry('p2', {
        'status': 'safety_stopped',
        'outcome': 'stopped',
        'termination': 'stopped_by_user',
        'route': 'physical',
      }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();

    // ThinQ 확인 못 함은 실패로 말하지 않는다.
    expect(find.textContaining('보냈지만 확인하지 못했어요'), findsNWidgets(2));
    expect(find.text('경로 ThinQ · 확인 접수됨'), findsOneWidget);
    expect(find.text('경로 ThinQ · 확인 상태 확인됨'), findsOneWidget);
    // 접수 불명은 받았는지 모른다고만 말한다(접수됨·확인됨으로 올리지 않는다).
    expect(find.text('경로 ThinQ · 확인 받았는지 확인이 필요해요'), findsOneWidget);
    expect(find.textContaining('가전 상태를 확인했어요'), findsOneWidget);
    expect(find.textContaining('안전 정지'), findsOneWidget);
    expect(find.textContaining('정지됨'), findsOneWidget);
    // ThinQ 기록에는 '버튼으로 직접 조작'을 내걸지 않는다(물리 실패 2건만).
    expect(find.text('버튼으로 직접 조작'), findsNWidgets(2));
  });

  testWidgets('실행 상태: ThinQ 확인 못 함은 주의로, 정지 버튼 없이 경로·확인 수준을 말한다',
      (tester) async {
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: const ExecutionStatus(
        label: '공기청정기 켜기',
        phase: ExecutionPhase.unconfirmed,
        message: '명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.',
        executionMode: 'mock',
        outcome: 'unconfirmed',
        route: 'thinq',
        receipt: 'accepted',
        confirmation: 'none',
      ),
    ));
    await tester.pump();

    expect(find.textContaining('보냈지만 확인하지 못했어요'), findsOneWidget);
    expect(find.text('확인 못 함'), findsOneWidget);
    expect(find.text('ThinQ'), findsOneWidget);
    expect(find.text('접수됨'), findsOneWidget);
    expect(find.textContaining('모의 실행'), findsOneWidget);
    expect(find.textContaining('실패'), findsNothing);
    expect(find.textContaining('정지'), findsNothing);
  });
}
